#!/usr/bin/env python3
"""Speicheroption: Inhalt, Rückgängig, Autosave, Aufteilung und Neustart."""
import os
import time
import json

from e2e_open_folder import ROOT, bounds, check, click_center, isolated_env, rpc, settle, shot, start_zid, stop_zid, wait_port
from e2e_ui_misc import palette


def main():
    root = os.path.join(ROOT, "tmp", "e2e_save_whitespace")
    os.makedirs(root, exist_ok=True)
    path = os.path.join(root, "note.txt")
    source = "Grösse  \r\n\t  \r\nletzte\t "
    with open(path, "wb") as f:
        f.write(source.encode("cp1252"))
    env = isolated_env("e2e_save_whitespace")
    env["ZID_LSP"] = "off"
    state_path = os.path.join(env["XDG_CONFIG_HOME"], "zid", "state")

    def disk():
        with open(path, "rb") as f:
            return f.read()

    def key(name, ctrl=False):
        rpc("key_press", [name, ctrl]); settle()

    with open(os.path.join(ROOT, "tmp", "e2e_save_whitespace.log"), "w") as log:
        proc = start_zid(["--headless", "--ai=off"], log, env=env)
        try:
            wait_port(proc)
            rpc("open_file", [path]); settle(20)
            rpc("click", [700, 300]); settle()
            key("s", True)
            check(disk() == "Grösse\r\n\r\nletzte".encode("cp1252"), "Speichern entfernt Leerzeichen und Tabs, erhält CRLF und Windows-1252")
            key("z", True)
            check("  \n" in json.loads(rpc("editor_state"))["text"], "Entfernen ist mit einem Schritt rückgängig")
            palette("toggle trim trailing whitespace")
            key("s", True)
            check(disk() == source.encode("cp1252"), "Abgeschaltete Option erhält Leerzeichen")
            with open(state_path) as f:
                check("trim_trailing_whitespace=false" in f.read(), "Option wird gespeichert")
            palette("toggle trim trailing whitespace")
            click_center("menu_file")
            mark = bounds("menu_check_toggle_trim_trailing_whitespace")
            check(mark["w"] == 18 and mark["h"] == 18 and mark["x"] >= 0, "Aktive Option hat ein 18-Pixel-Menühäkchen")
            # Der Explorer und das neue Häkchen teilen sich das SVG-Budget (4 pro Bild).
            for _ in range(8):
                rpc("screenshot"); settle(5)
            shot("e2e_save_whitespace_menu.ppm")
            key("escape")
            palette("toggle autosave")
            key("backslash", True)
            rpc("open_file", [path]); settle(15)
            rpc("click", [950, 350]); settle()
            key("home"); rpc("type_text", ["x"]); settle()
            t0 = time.monotonic()
            while time.monotonic() - t0 < 5 and b"  \r\n" in disk():
                time.sleep(0.1)
            check(b"  \r\n" not in disk() and b"\t " not in disk(), "Autosave im neuen Pane entfernt Leerzeichen ebenfalls")
            palette("toggle trim trailing whitespace")
        finally:
            stop_zid(proc)
        proc = start_zid(["--headless", "--ai=off"], log, env=env)
        try:
            wait_port(proc)
            rpc("open_file", [path]); settle(20)
            rpc("click", [700, 300]); settle()
            key("home", True); key("end"); rpc("type_text", ["  "]); settle()
            key("s", True)
            check(b"  \r\n" in disk(), "Neustart behält die abgeschaltete Option")
            palette("toggle autosave")
            palette("toggle trim trailing whitespace")
            # Diesen geänderten Buffer danach in keinem Pane anzeigen.
            key("end"); rpc("type_text", ["Q  "]); settle()
            other = os.path.join(root, "other.txt")
            with open(other, "w") as f:
                f.write("andere Datei\n")
            rpc("open_file", [other]); settle(20)
            rpc("request_quit"); settle(10)
            click_center("Save All")
            proc.wait(timeout=10)
            check(b"Q\r\n" in disk() and b"  \r\n" not in disk(), "Save All bereinigt auch den inaktiven Buffer")
            print("ALL PASSED")
        finally:
            stop_zid(proc)


if __name__ == "__main__":
    main()
