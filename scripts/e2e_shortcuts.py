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


def explorer():
    return result_json("explorer_entries")


def explorer_row_center(name):
    """Zeilenmitte des Explorer-Eintrags `name`; scrollt ihn bei Bedarf in den Viewport."""
    for _ in range(40):
        ex = explorer()
        rows = [e for e in ex["entries"] if e["name"] == name]
        if not rows:
            raise AssertionError(f"Explorer-Eintrag {name!r} nicht sichtbar")
        vp, rh = ex["viewport"], ex["row_height"]
        y = vp["y"] + rows[0]["index"] * rh + rh / 2 - ex["scroll"]
        if vp["y"] <= y < vp["y"] + vp["h"]:
            return vp["x"] + 60, y
        lines = -3 if y >= vp["y"] + vp["h"] else 3
        rpc("scroll", [vp["x"] + 60, vp["y"] + vp["h"] / 2, lines])
        settle()
    raise AssertionError(f"{name!r} nicht in den Viewport gescrollt")


def explorer_click(name, right=False):
    x, y = explorer_row_center(name)
    rpc("right_click" if right else "click", [x, y])
    settle()


def ui_state():
    return result_json("ui_state")


def dialog_open():
    return ui_state()["dialog"] is not None


def item2_explorer_f2_delete():
    print("--- 2. Explorer: F2 benennt um, Entf löscht (mit Dialog), nur mit Fokus im Explorer")
    fixture_dir = os.path.join(ROOT, "tmp", "e2e_fx")
    os.makedirs(fixture_dir, exist_ok=True)
    victim = os.path.join(fixture_dir, "victim.txt")
    with open(victim, "w") as f:
        f.write("bye\n")
    time.sleep(0.5)  # Watcher/Refresh
    # tmp → e2e_fx aufklappen, Datei markieren
    if not any(e["name"] == "e2e_fx" for e in explorer()["entries"]):
        explorer_click("tmp")
    if not any(e["name"] == "victim.txt" for e in explorer()["entries"]):
        explorer_click("e2e_fx")
    explorer_click("victim.txt")
    settle(10)

    key("f2")
    check(explorer()["renaming"], "F2 startet das Umbenennen des markierten Eintrags")
    key("escape")
    check(not explorer()["renaming"], "Escape bricht das Umbenennen ab")

    key("delete")
    check(dialog_open(), "Entf öffnet den Lösch-Dialog")
    click_center("Cancel")
    check(not dialog_open() and os.path.exists(victim), "Cancel: Datei bleibt")

    # Fokus im Editor: Entf darf nichts löschen
    rpc("click", [1100, 400])
    settle()
    key("delete")
    check(not dialog_open(), "Entf ohne Explorer-Fokus öffnet keinen Dialog")

    explorer_click("victim.txt")
    key("delete")
    check(dialog_open(), "Entf nach erneutem Klick im Explorer öffnet den Dialog")
    click_center("Delete")
    settle(10)
    check(not os.path.exists(victim), "Delete: Datei ist gelöscht")
    os.rmdir(fixture_dir)


STEPS = [item1_table_drives_ctrl_o, item2_explorer_f2_delete]


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
