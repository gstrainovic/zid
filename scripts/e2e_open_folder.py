#!/usr/bin/env python3
"""Headless-E2E: File-Menü → "Open Folder…" → Pfad tippen → Explorer-Root wechselt.

Startet vulkan-ed mit --headless --ai=off (kein Fenster), fährt den Dialog
über RPC und prüft, dass der Explorer danach den neuen Ordner zeigt.
Aufruf: python3 scripts/e2e_open_folder.py [zielordner]  (Default: ~/projects)
"""
import json, os, socket, subprocess, sys, time

HOST, PORT = "127.0.0.1", 9999
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


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
            raise RuntimeError("vulkan-ed beendet sich vor RPC-Start")
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
    target = os.path.expanduser(sys.argv[1] if len(sys.argv) > 1 else "~/projects")
    target_input = sys.argv[1] if len(sys.argv) > 1 else "~/projects"
    log = open(os.path.join(ROOT, "tmp", "e2e_open_folder.log"), "w")
    proc = subprocess.Popen(
        ["zig", "build", "run", "--", "--headless", "--ai=off"],
        cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
    )
    try:
        wait_port(proc)
        settle(20)
        state = result_json("get_state")
        old_root = state["root"]
        check(old_root == ROOT, f"Start-Root ist das Projekt: {old_root}")

        # 1) Menü "File" öffnen, "Open Folder…" anklicken
        click_center("menu_file")
        check(bounds("menu_open_folder")["found"], "Dropdown zeigt 'Open Folder…'")
        shot("e2e_menu.ppm")
        click_center("menu_open_folder")
        check(bounds("fp_input")["found"], "Ordner-Dialog ist offen (Pfadfeld sichtbar)")
        picker = result_json("folder_picker_state")
        check(picker["open"] and picker["path"] == old_root, f"Dialog startet im aktuellen Ordner: {picker['path']}")
        check(any(e == "src" for e in picker["entries"]), "Dialog listet Unterordner (src)")

        # 2) Unterordner per Klick betreten und mit ↑ zurück
        idx = picker["entries"].index("src")
        click_center("fp_entry", idx)
        picker = result_json("folder_picker_state")
        check(picker["path"] == os.path.join(old_root, "src"), f"Klick auf Ordner steigt ab: {picker['path']}")
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
        try:
            rpc("shutdown")
        except Exception:
            pass
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
        log.close()


if __name__ == "__main__":
    main()
