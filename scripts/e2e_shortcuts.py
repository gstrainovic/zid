#!/usr/bin/env python3
"""Headless-E2E für Tastenkürzel und Menüs (todo.md: Kürzel sichtbar machen).

Startet vulkan-ed mit --headless --ai=off und prüft pro Punkt der todo.md,
dass Taste und Menüeintrag dasselbe tun. Aufruf: python3 scripts/e2e_shortcuts.py
"""
import os, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e2e_open_folder import ROOT, rpc, result_json, wait_port, settle, bounds, click_center, check, shot  # noqa: E402


def key(name, ctrl=False, shift=False):
    rpc("key_press_mods", [name, ctrl, shift])
    settle()


def menu_click(menu_id, item_id):
    """Menü öffnen, Eintrag anklicken (beide müssen im Layout stehen)."""
    click_center(menu_id)
    check(bounds(item_id)["found"], f"Menü zeigt {item_id}")
    click_center(item_id)


def picker_open():
    return result_json("folder_picker_state")["open"]


def item1_table_drives_ctrl_o():
    print("--- 1. Kürzel-Tabelle: Ctrl+O und Menüeintrag laufen über executeCommand")
    key("o", ctrl=True)
    check(picker_open(), "Ctrl+O öffnet den Ordner-Dialog")
    key("escape")
    check(not picker_open(), "Escape schließt ihn")
    menu_click("menu_file", "menu_open_folder")
    check(picker_open(), "Menü File → Open Folder… öffnet den Dialog")
    key("escape")


STEPS = [item1_table_drives_ctrl_o]


def main():
    log = open(os.path.join(ROOT, "tmp", "e2e_shortcuts.log"), "w")
    proc = subprocess.Popen(
        [os.path.join(ROOT, "zig-out", "bin", "vulkan-ed"), "--headless", "--ai=off"],
        cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
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
