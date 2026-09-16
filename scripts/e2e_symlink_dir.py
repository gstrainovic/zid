#!/usr/bin/env python3
"""Headless-E2E: Symlink auf einen Ordner im Explorer und als Tab.

Fixture tmp/e2e_symlink/: real_dir/ mit Datei, dir_link -> real_dir (relativ, wie
~/projects/wartungsheft/business-plan), noperm.txt ohne Leserechte.
Prüft:
  1. der Explorer zeigt dir_link als Ordner (aufklappbar, kein Tab)
  2. open_file auf ein Verzeichnis liefert error.IsDir und legt keinen Tab an
  3. eine unlesbare Datei meldet den Fehler genau einmal und der Tab verschwindet
     (vorher: "Cannot open" in jedem Frame, Tab blieb hängen)
Aufruf: python3 scripts/e2e_symlink_dir.py
"""
import json, os, socket, stat, subprocess, sys, time

HOST, PORT = "127.0.0.1", 9999
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIX = os.path.join(ROOT, "tmp", "e2e_symlink")
LOG = os.path.join(ROOT, "tmp", "e2e_symlink_dir.log")
CAN_REVOKE_READ = os.name != "nt"
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e2e_open_folder import start_zid  # noqa: E402


def rpc(method, params=None):
    msg = json.dumps({"jsonrpc": "2.0", "method": method, "params": params or [], "id": 1}) + "\n"
    with socket.create_connection((HOST, PORT), timeout=10) as s:
        s.sendall(msg.encode())
        data = b""
        while not data.endswith(b"\n"):
            chunk = s.recv(65536)
            if not chunk:
                break
            data += chunk
    res = json.loads(data.decode())
    if "error" in res:
        raise RuntimeError(f"{method}: {res['error']}")
    return res["result"]


def result_json(method, params=None):
    return json.loads(rpc(method, params))


def wait_port(proc, timeout=60):
    t0 = time.time()
    while time.time() - t0 < timeout:
        if proc.poll() is not None:
            raise RuntimeError("zid beendet sich vor RPC-Start")
        try:
            with socket.create_connection((HOST, PORT), timeout=1):
                return
        except OSError:
            time.sleep(0.3)
    raise RuntimeError("RPC-Port nicht erreichbar")


def settle(frames=6):
    time.sleep(frames * 0.016 + 0.05)


def check(cond, msg):
    print(("PASS " if cond else "FAIL ") + msg)
    if not cond:
        raise AssertionError(msg)


def entry(name):
    for e in result_json("explorer_entries")["entries"]:
        if e["name"] == name:
            return e
    return None


def click_row(name):
    """Zeile in den Viewport scrollen und ihre Mitte anklicken."""
    ex = result_json("explorer_entries")
    e = next(x for x in ex["entries"] if x["name"] == name)
    vp, rh = ex["viewport"], ex["row_height"]
    y = vp["y"] + e["index"] * rh + rh / 2 - ex["scroll"]
    tries = 0
    while y > vp["y"] + vp["h"] - rh and tries < 40:
        rpc("scroll", [vp["x"] + vp["w"] / 2, vp["y"] + vp["h"] / 2, -10])
        settle()
        ex = result_json("explorer_entries")
        y = vp["y"] + e["index"] * rh + rh / 2 - ex["scroll"]
        tries += 1
    rpc("click", [vp["x"] + vp["w"] / 2, y])
    settle()
    after = entry(name)
    print(f"  click_row({name!r}): index={e['index']} y={y:.0f} vp={vp} scroll={ex['scroll']} expanded={after and after['expanded']}")


def make_fixture():
    os.makedirs(os.path.join(FIX, "real_dir"), exist_ok=True)
    with open(os.path.join(FIX, "real_dir", "inside.txt"), "w") as f:
        f.write("inside\n")
    link = os.path.join(FIX, "dir_link")
    if os.path.lexists(link):
        # Unter Windows ist ein Ordner-Symlink ein Verzeichniseintrag: rmdir, nicht remove.
        os.rmdir(link) if os.name == "nt" else os.remove(link)
    try:
        os.symlink("real_dir", link, target_is_directory=True)
    except OSError:
        if os.name != "nt":
            raise
        # Windows verlangt für Symlinks Entwicklermodus oder Adminrechte. Eine Junction geht
        # ohne und ist dort der übliche Ordner-Link (z. B. %USERPROFILE%\projects).
        subprocess.run(["cmd", "/c", "mklink", "/J", link, os.path.join(FIX, "real_dir")],
                       check=True, capture_output=True)
    noperm = os.path.join(FIX, "noperm.txt")
    if os.path.lexists(noperm):
        os.chmod(noperm, stat.S_IWRITE)
        os.remove(noperm)
    with open(noperm, "w") as f:
        f.write("secret\n")
    # chmod 0 nimmt nur unter POSIX die Leserechte; unter Windows setzt es bloss Nur-Lesen.
    if CAN_REVOKE_READ:
        os.chmod(noperm, 0)


def tab_count():
    return result_json("ui_state")["tab_count"]


def main():
    make_fixture()
    log = open(LOG, "w")
    proc = start_zid(["--headless", "--ai=off"], log)
    try:
        wait_port(proc)
        settle(20)
        check(result_json("get_state")["root"] == ROOT, "Explorer-Root ist das Projekt")

        click_row("tmp")
        click_row("e2e_symlink")
        link = entry("dir_link")
        check(link is not None, "Explorer listet dir_link")
        check(link["is_folder"], "dir_link (Symlink auf Ordner) gilt als Ordner")

        tabs_before = tab_count()
        click_row("dir_link")
        settle(10)
        check(tab_count() == tabs_before, "Klick auf dir_link öffnet keinen Tab")
        check(entry("inside.txt") is not None, "Klick auf dir_link klappt den Zielordner auf")

        res = rpc("open_file", [os.path.join(FIX, "dir_link")])
        settle(10)
        check("IsDir" in res, f"open_file auf Verzeichnis liefert IsDir: {res}")
        check(tab_count() == tabs_before, "open_file auf Verzeichnis legt keinen Tab an")

        if CAN_REVOKE_READ:
            res = rpc("open_file", [os.path.join(FIX, "noperm.txt")])
            settle(30)
            check(tab_count() == tabs_before, f"Tab der unlesbaren Datei ist wieder zu (open_file: {res})")
    finally:
        try:
            rpc("shutdown")
        except Exception:
            pass
        proc.wait(timeout=15)
        log.close()
    with open(LOG, encoding="utf-8", errors="replace") as f:
        text = f.read()
    if CAN_REVOKE_READ:
        n_cannot = text.count("Cannot open 'noperm.txt'")
        check(n_cannot == 1, f"'Cannot open' für noperm.txt genau einmal geloggt (war {n_cannot})")
    else:
        print("SKIP unlesbare Datei: unter Windows entzieht chmod keine Leserechte")
    check("Cannot open 'dir_link'" not in text, "kein 'Cannot open' für dir_link")
    check("result queue full" not in text, "keine volle Result-Queue")


if __name__ == "__main__":
    main()
