#!/usr/bin/env python3
"""Headless-E2E: File-Menü → "Open Folder…" → Pfad tippen → Explorer-Root wechselt.

Startet zid mit --headless --ai=off (kein Fenster), fährt den Dialog
über RPC und prüft, dass der Explorer danach den neuen Ordner zeigt.
Aufruf: python3 scripts/e2e_open_folder.py [zielordner]  (Default: ~/projects)
"""
import json, os, shutil, socket, subprocess, sys, time

# Windows: umgeleitetes stdout ist cp1252, die Suiten drucken aber Pfeile (↑↓) und
# sterben dann mit UnicodeEncodeError, bevor der eigentliche Schritt läuft.
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

HOST, PORT = "127.0.0.1", 9999
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ZID = os.path.join(ROOT, "zig-out", "bin", "zid.exe" if os.name == "nt" else "zid")


def rmtree(path):
    """Verzeichnis samt Inhalt löschen, auch schreibgeschützte Dateien.

    Git legt Objekte unter .git/objects schreibgeschützt an; unter Windows scheitert
    shutil.rmtree daran mit PermissionError, mit ignore_errors=True bleibt das Fixture
    dann still stehen und das folgende os.makedirs wirft FileExistsError."""
    def force(func, p, _exc):
        os.chmod(p, 0o700)
        func(p)

    if os.path.exists(path):
        shutil.rmtree(path, onexc=force)


def isolated_env(name):
    """Umgebung mit frischem XDG_CONFIG_HOME und XDG_DATA_HOME unter tmp/e2e_env/<name>.

    Ohne das liest zid die State-Datei des Benutzers (Zeilenumbruch, Schriftgröße,
    Sidebar-Breite) und die Suite misst Fremdzustand; außerdem überschreibt sie sie."""
    base = os.path.join(ROOT, "tmp", "e2e_env", name)
    shutil.rmtree(base, ignore_errors=True)
    config, data = os.path.join(base, "config"), os.path.join(base, "data")
    os.makedirs(config)
    os.makedirs(data)
    return dict(os.environ, XDG_CONFIG_HOME=config, XDG_DATA_HOME=data)


def start_zid(args, log, env=None):
    """Baut mit `zig build` und startet dann das Binary direkt (Linux wie Windows).

    Nicht `zig build run`: dort ist zid ein Kind von zig, proc.kill() träfe nur zig
    und das verwaiste zid bliebe auf Port 9999. Prozessgruppen (killpg) gibt es
    unter Windows nicht; mit dem Binary als direktem Kind reicht proc.kill().

    Ohne `env` bekommt zid eine eigene, frische Konfiguration (`isolated_env`,
    benannt nach der Log-Datei)."""
    if env is None:
        env = isolated_env(os.path.splitext(os.path.basename(log.name))[0])
    log.flush()
    # ZID_BUILD_ARGS reicht Build-Optionen durch, z.B. ZID_BUILD_ARGS=-Dmupdf=bundled
    build_args = os.environ.get("ZID_BUILD_ARGS", "").split()
    build = subprocess.run(["zig", "build"] + build_args, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, env=env)
    if build.returncode != 0:
        raise RuntimeError(f"zig build fehlgeschlagen (Code {build.returncode}), siehe {log.name}")
    log.flush()
    return subprocess.Popen([ZID] + list(args), cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, env=env)


def stop_zid(proc, timeout=10):
    """Per RPC beenden, notfalls hart. Gibt den Exit-Code zurück (None nach kill)."""
    try:
        rpc("shutdown")
    except Exception:
        pass
    try:
        return proc.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
        return None


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


def bounds(elem_id, index=None):
    if index is None:
        b = result_json("element_bounds", [elem_id])
    else:
        b = result_json("element_bounds_i", [elem_id, index])
    if not b["found"]:
        raise AssertionError(f"Element {elem_id!r} nicht im Layout")
    return b


def click_center(elem_id, index=None):
    b = bounds(elem_id, index)
    rpc("click", [b["x"] + b["w"] / 2, b["y"] + b["h"] / 2])
    settle()


def shot(name):
    """Screenshot nach tmp/<name>. Zweimal rendern: der SVG-Atlas rasterisiert
    höchstens 4 neue Icons pro Render-Durchgang, der Rest kommt im nächsten."""
    for _ in range(2):
        rpc("screenshot")
        settle(10)
    os.replace(os.path.join(ROOT, "tmp", "vulkan-screenshot.ppm"), os.path.join(ROOT, "tmp", name))


def check(cond, msg):
    print(("PASS " if cond else "FAIL ") + msg)
    if not cond:
        raise AssertionError(msg)


def main():
    # realpath: zid löst Symlinks/Junctions auf (hier: C:\Users\x.WA\projects -> C:\Users\x\projects),
    # unter Windows mischt expanduser ausserdem "\" und "/".
    target = os.path.realpath(os.path.expanduser(sys.argv[1] if len(sys.argv) > 1 else "~/projects"))
    target_input = sys.argv[1] if len(sys.argv) > 1 else "~/projects"
    log = open(os.path.join(ROOT, "tmp", "e2e_open_folder.log"), "w")
    proc = start_zid(["--headless", "--ai=off"], log)
    try:
        wait_port(proc)
        settle(20)
        state = result_json("get_state")
        old_root = state["root"]
        check(old_root == ROOT, f"Start-Root ist das Projekt: {old_root}")

        # 1) Menü "File" öffnen, "Open Folder…" anklicken
        click_center("menu_file")
        check(bounds("menu_item_open_folder")["found"], "Dropdown zeigt 'Open Folder…'")
        shot("e2e_menu.ppm")
        click_center("menu_item_open_folder")
        check(bounds("fp_input")["found"], "Ordner-Dialog ist offen (Pfadfeld sichtbar)")
        picker = result_json("folder_picker_state")
        check(picker["open"] and picker["path"] == old_root, f"Dialog startet im aktuellen Ordner: {picker['path']}")
        check(any(e == "src" for e in picker["entries"]), "Dialog listet Unterordner (src)")
        # Cursorstrich muss sichtbar sein: lag er mit z 10 unter dem Dialog (z 2000),
        # hatte das Pixel die Farbe des Feldhintergrunds.
        from e2e_pdf_pager import pixel
        caret = bounds("fp_input_text_caret")
        shot("e2e_caret.ppm")
        cy = caret["y"] + caret["h"] / 2
        check(pixel("e2e_caret.ppm", caret["x"] + 1, cy) != pixel("e2e_caret.ppm", caret["x"] + 8, cy),
              "Cursorstrich im Pfadfeld ist sichtbar")

        # 2) Unterordner per Klick betreten und mit ↑ zurück
        # Erster Eintrag statt "src": lokale Ordner (engines, models, zig-pkg …) schieben
        # "src" je nach Rechner unter den sichtbaren Rand der Liste.
        first = picker["entries"][0]
        click_center("fp_entry", 0)
        picker = result_json("folder_picker_state")
        check(picker["path"] == os.path.join(old_root, first), f"Klick auf Ordner steigt ab: {picker['path']}")
        click_center("fp_up")
        picker = result_json("folder_picker_state")
        check(picker["path"] == old_root, "↑ steigt wieder auf")

        # 3) Pfad tippen (Feld leeren, ~-Pfad eingeben) und mit Enter öffnen
        for _ in range(len(picker["path"])):
            rpc("key_press", ["backspace", False])
        rpc("type_text", [target_input])
        settle()
        picker = result_json("folder_picker_state")
        check(picker["path"] == target_input, f"Getippter Pfad steht im Feld: {picker['path']}")
        # Cursor im Pfadfeld: Pos1 + Entf löscht vorne, Klick an den Anfang + Tippen fügt vorne ein
        rpc("key_press", ["home", False])
        rpc("key_press", ["delete", False])
        settle()
        check(result_json("folder_picker_state")["path"] == target_input[1:], "Pos1 + Entf löscht das erste Zeichen")
        rpc("key_press", ["end", False])
        b = bounds("fp_input")
        rpc("click", [b["x"] + 11, b["y"] + b["h"] / 2])
        settle()
        check(result_json("folder_picker_state")["open"], "Klick ins Pfadfeld schließt den Dialog nicht")
        rpc("type_text", [target_input[0]])
        settle()
        check(result_json("folder_picker_state")["path"] == target_input, "Klick an den Anfang + Tippen stellt den Pfad wieder her")
        rpc("key_press", ["enter", False])
        settle(20)

        picker = result_json("folder_picker_state")
        check(not picker["open"], "Dialog schließt nach Enter")
        state = result_json("get_state")
        check(state["root"] == target, f"Explorer-Root ist jetzt {state['root']}")
        entries = result_json("explorer_entries")["entries"]
        check(entries and entries[0]["path"] == target, "Erster Explorer-Eintrag ist der neue Root")
        check(bounds("menu_file")["found"], "Menü-Button weiterhin im Header")

        # 4) Ctrl+O öffnet den Dialog erneut, Escape schließt
        rpc("key_press", ["o", True])
        settle()
        check(result_json("folder_picker_state")["open"], "Ctrl+O öffnet den Dialog")
        rpc("key_press", ["escape", False])
        settle()
        check(not result_json("folder_picker_state")["open"], "Escape schließt den Dialog")

        # Screenshot des Dialogs im neuen Ordner
        rpc("key_press", ["o", True]); settle()
        shot("e2e_dialog.ppm")
        rpc("key_press", ["escape", False]); settle()
        print("ALL PASSED")
    finally:
        stop_zid(proc)
        log.close()


if __name__ == "__main__":
    main()
