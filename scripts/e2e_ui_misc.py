#!/usr/bin/env python3
"""Headless-E2E: Theme-Umschalter, Zoom, Autosave, Toasts, Menü per Tastatur, scrollbarer
Kürzel-Dialog, gemerkter Zustand. Aufruf: python3 scripts/e2e_ui_misc.py
"""
import os, shutil, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e2e_open_folder import ROOT, rpc, result_json, wait_port, settle, bounds, click_center, check, shot  # noqa: E402
from e2e_shortcuts import key, ui_state, dialog_open  # noqa: E402

FX = os.path.join(ROOT, "tmp", "e2e_misc")
SRC = os.path.join(FX, "note.txt")
XDG = os.path.join(ROOT, "tmp", "xdg")
XDG_CONFIG = os.path.join(ROOT, "tmp", "xdg-config-misc")


def key_alt(name):
    rpc("key_press_alt", [name, False, False, True]); settle()


def palette(text):
    """Command Palette öffnen, `text` tippen (auf die Anfrage warten), Enter."""
    key("p", ctrl=True, shift=True); settle()
    rpc("type_text", [text])
    t0 = time.time()
    while time.time() - t0 < 5 and result_json("picker_state")["query"] != text:
        time.sleep(0.05)
    settle(5)
    key("enter")
    t0 = time.time()
    while time.time() - t0 < 5 and result_json("picker_state")["open"]:
        time.sleep(0.05)
    settle(10)


def setup():
    shutil.rmtree(FX, ignore_errors=True)
    shutil.rmtree(XDG_CONFIG, ignore_errors=True)
    os.makedirs(FX)
    with open(SRC, "w") as f:
        f.write("hello\n")
    time.sleep(0.3)


def step_theme_zoom():
    print("--- Theme und Zoom")
    check(not ui_state()["light_theme"], "Start: dunkles Theme")
    palette("toggle light")
    check(ui_state()["light_theme"], "Command Palette → helles Theme")
    shot("e2e_misc_light.ppm")
    key("equals", ctrl=True); key("equals", ctrl=True)
    check(ui_state()["font_size"] == 28, f"Ctrl+= zweimal: Schrift 28 ({ui_state()['font_size']})")
    check("Font size 28" in ui_state()["toast"], f"Toast meldet die Größe: {ui_state()['toast']!r}")
    key("minus", ctrl=True)
    check(ui_state()["font_size"] == 26, "Ctrl+- verkleinert")
    key("0", ctrl=True)
    check(ui_state()["font_size"] == 24, "Ctrl+0 setzt zurück")
    state_file = os.path.join(XDG_CONFIG, "vulkan-ed", "state")
    check(os.path.exists(state_file) and "theme=light" in open(state_file).read(), "Theme steht in der State-Datei")
    palette("toggle light")
    check(not ui_state()["light_theme"], "zurück auf dunkel")


def step_autosave_toast():
    print("--- Autosave und Toast beim Speichern")
    rpc("open_file", [SRC]); settle(20)
    rpc("click", [700, 300]); settle()
    rpc("type_text", ["X"]); settle()
    key("s", ctrl=True); settle(10)
    check("Saved note.txt" in ui_state()["toast"], f"Ctrl+S zeigt einen Toast: {ui_state()['toast']!r}")
    check(open(SRC).read().startswith("Xhello") or "X" in open(SRC).read(), "Datei ist gespeichert")
    backup_dir = os.path.join(XDG, "vulkan-ed", "backup")
    check(os.path.isdir(backup_dir) and any(n.startswith("note.txt.") for n in os.listdir(backup_dir)), "Sicherung der alten Version liegt im Backup-Ordner")
    palette("toggle autosave")
    check(ui_state()["autosave"] and "Autosave on" in ui_state()["toast"], "Autosave eingeschaltet")
    rpc("click", [700, 300]); settle()
    rpc("type_text", ["Y"]); settle()
    t0 = time.time()
    while time.time() - t0 < 5 and "Y" not in open(SRC).read():
        time.sleep(0.1)
    check("Y" in open(SRC).read(), f"Autosave schreibt nach {time.time() - t0:.1f}s")
    palette("toggle autosave")
    check(not ui_state()["autosave"], "Autosave wieder aus")


def step_menu_keyboard():
    print("--- Menü per Tastatur")
    tabs_before = ui_state()["tab_count"]
    key_alt("f")
    check(ui_state()["open_menu"] == "File" and ui_state()["menu_highlight"] == 0, "Alt+F öffnet File mit markiertem ersten Eintrag")
    key("right")
    check(ui_state()["open_menu"] == "Edit", "→ wechselt zu Edit")
    key("left")
    key("down"); key("up")
    key("enter"); settle(10)
    check(ui_state()["open_menu"] is None and ui_state()["tab_count"] == tabs_before + 1, "Enter führt 'New File' aus (neuer Tab)")
    key_alt("v")
    check(ui_state()["open_menu"] == "View", "Alt+V öffnet View")
    key("escape")
    check(ui_state()["open_menu"] is None, "Escape schließt")


def step_shortcuts_scroll():
    print("--- Kürzel-Dialog scrollt")
    key("f1")
    check(ui_state()["shortcuts_open"], "F1 öffnet den Dialog")
    b = bounds("sc_viewport")
    rpc("scroll", [b["x"] + 50, b["y"] + 50, -5]); settle()
    check(ui_state()["shortcuts_scroll"] > 0, f"Mausrad scrollt ({ui_state()['shortcuts_scroll']})")
    key("down"); key("down")
    shot("e2e_misc_shortcuts.ppm")
    key("f1")
    check(not ui_state()["shortcuts_open"], "F1 schließt wieder")


STEPS = [step_theme_zoom, step_autosave_toast, step_menu_keyboard, step_shortcuts_scroll]


def main():
    setup()
    log = open(os.path.join(ROOT, "tmp", "e2e_ui_misc.log"), "w")
    proc = subprocess.Popen(
        [os.path.join(ROOT, "zig-out", "bin", "vulkan-ed"), "--headless", "--ai=off"],
        cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
        env=dict(os.environ, XDG_DATA_HOME=XDG, XDG_CONFIG_HOME=XDG_CONFIG),
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
