#!/usr/bin/env python3
"""Headless-E2E: Das Layout darf im Leerlauf nicht wachsen.

Vorher wuchs die Editor-Bounding-Box mit eingeschalteter Minimap jeden zweiten Frame um 2 px
(Balken + Innenabstand waren höher als der Editor, Clay reichte die Mindesthöhe bis zur Wurzel
durch). Nach Minuten zeichnete der Editor hunderte Zeilen, klein gezoomt wurde alles extrem langsam.
Prüft: Editor-Höhe und sichtbare Reihen bleiben über ~150 Frames konstant, auch nach 7× Ctrl+-.
Aufruf: python3 scripts/e2e_layout_stable.py
"""
import os, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e2e_open_folder import ROOT, rpc, result_json, wait_port, settle, bounds, click_center, check, shot  # noqa: E402


def editor():
    return result_json("editor_state")


def ensure_minimap():
    if editor()["minimap"]:
        return
    click_center("menu_view")
    check(bounds("menu_item_toggle_minimap")["found"], "View-Menü zeigt Toggle Minimap")
    click_center("menu_item_toggle_minimap")
    check(editor()["minimap"], "Minimap eingeschaltet")


def stable_for(seconds, label):
    before = editor()
    time.sleep(seconds)
    after = editor()
    print(f"     {label}: height {before['height']} -> {after['height']}, rows {before['visible_rows']} -> {after['visible_rows']}")
    check(after["height"] == before["height"], f"{label}: Editor-Höhe bleibt {before['height']}")
    check(after["visible_rows"] == before["visible_rows"], f"{label}: sichtbare Reihen bleiben {before['visible_rows']}")
    check(0 < after["height"] <= 800, f"{label}: Höhe {after['height']} liegt im Headless-Fenster (800)")


def main():
    log = open(os.path.join(ROOT, "tmp", "e2e_layout_stable.log"), "w")
    proc = subprocess.Popen(
        ["zig", "build", "run", "--", "--headless", "--ai=off"],
        cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
    )
    try:
        wait_port(proc)
        settle(20)
        rpc("open_file", [os.path.join(ROOT, "src/ui/mod.zig")])
        settle(60)
        ensure_minimap()
        settle(30)
        rpc("key_press", ["0", True])  # Ctrl+0: Zoom zurücksetzen (24), unabhängig vom gespeicherten State
        settle(30)
        check(result_json("ui_state")["font_size"] == 24, "Ctrl+0 setzt die Schriftgröße auf 24")
        print("--- 1. Leerlauf mit Minimap")
        stable_for(3.0, "Leerlauf")
        rows_24 = editor()["visible_rows"]
        print("--- 2. Sieben Mal Ctrl+- (Zoom Out)")
        for _ in range(7):
            rpc("key_press", ["minus", True])
            settle(10)
        settle(30)
        st = result_json("ui_state")
        print(f"     font_size={st['font_size']} last_frame_ms={st['last_frame_ms']}")
        check(st["font_size"] == 10, "7× Ctrl+- landet bei Schriftgröße 10")
        check(editor()["visible_rows"] > rows_24, f"klein gezoomt passen mehr Reihen ({editor()['visible_rows']} > {rows_24})")
        stable_for(3.0, "nach Zoom Out")
        shot("e2e_layout_stable.ppm")
        print("PASS alle Prüfungen (Screenshot tmp/e2e_layout_stable.ppm)")
    finally:
        try:
            rpc("shutdown")
        except Exception:
            pass
        time.sleep(0.5)
        if proc.poll() is None:
            proc.terminate()
            proc.wait(timeout=10)


if __name__ == "__main__":
    main()
