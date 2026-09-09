#!/usr/bin/env python3
"""Headless-E2E für Schnellöffner (Ctrl+P) und Command Palette (Ctrl+Shift+P).
Aufruf: python3 scripts/e2e_picker.py
"""
import os, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e2e_open_folder import ROOT, rpc, result_json, wait_port, settle, bounds, click_center, check, shot  # noqa: E402
from e2e_shortcuts import key, ui_state  # noqa: E402


def picker():
    return result_json("picker_state")


def step_quick_open():
    print("--- Ctrl+P: Datei fuzzy öffnen")
    key("p", ctrl=True); settle()
    st = picker()
    check(st["open"] and st["mode"] == "files", "Ctrl+P öffnet den Picker sofort (Scan läuft im Hintergrund)")
    t0 = time.time()
    while time.time() - t0 < 20 and picker()["scanning"]:
        time.sleep(0.1)
    st = picker()
    check(not st["scanning"] and st["items"] > 50, f"Scan fertig nach {time.time() - t0:.1f}s: {st['items']} Projektdateien")
    rpc("type_text", ["uimodzig"]); settle(10)
    t0 = time.time()
    while time.time() - t0 < 5 and picker()["query"] != "uimodzig":
        time.sleep(0.05)
    settle(5)
    st = picker()
    check(st["matches"] >= 1 and st["selected_label"] == "src/ui/mod.zig", f"fuzzy 'uimodzig' → {st['selected_label']!r} ({st['matches']} Treffer)")
    shot("e2e_picker_files.ppm")
    key("enter"); settle(20)
    check(not picker()["open"], "Enter schließt den Picker")
    check(result_json("get_active_tab")["editor_file"].endswith("src/ui/mod.zig"), "src/ui/mod.zig ist offen")
    key("p", ctrl=True); settle()
    rpc("type_text", ["qqqqqqqqqq"]); settle(10)
    t0 = time.time()
    while time.time() - t0 < 5 and picker()["query"] != "qqqqqqqqqq":
        time.sleep(0.05)
    settle(5)
    check(picker()["matches"] == 0, "keine Treffer bei Unsinn")
    key("escape")
    check(not picker()["open"], "Escape schließt")


def step_command_palette():
    print("--- Ctrl+Shift+P: Kommando ausführen")
    key("p", ctrl=True, shift=True); settle()
    st = picker()
    check(st["open"] and st["mode"] == "commands" and st["items"] > 30, f"Palette listet {st['items']} Kommandos")
    rpc("type_text", ["toggle expl"]); settle(10)
    check(picker()["selected_label"] == "Toggle Explorer", f"'toggle expl' → {picker()['selected_label']!r}")
    shot("e2e_picker_commands.ppm")
    key("enter"); settle()
    check(not ui_state()["show_file_explorer"], "Enter führt Toggle Explorer aus (Explorer weg)")
    key("p", ctrl=True, shift=True); settle()
    rpc("type_text", ["toggle expl"]); settle(10)
    key("down"); key("up")
    key("enter"); settle()
    check(ui_state()["show_file_explorer"], "erneut: Explorer wieder da")
    key("p", ctrl=True, shift=True); settle()
    rpc("type_text", ["keyboard"]); settle(10)
    click_center("pk_row", 0); settle()
    check(ui_state()["shortcuts_open"], "Klick auf die Zeile führt 'Keyboard Shortcuts' aus")
    key("escape")


STEPS = [step_quick_open, step_command_palette]


def main():
    log = open(os.path.join(ROOT, "tmp", "e2e_picker.log"), "w")
    proc = subprocess.Popen(
        [os.path.join(ROOT, "zig-out", "bin", "zid"), "--headless", "--ai=off"],
        cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
        env=dict(os.environ, XDG_DATA_HOME=os.path.join(ROOT, "tmp", "xdg"), XDG_CONFIG_HOME=os.path.join(ROOT, "tmp", "xdg-config")),
    )
    try:
        wait_port(proc)
        settle(20)
        for step in STEPS:
            step()
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
