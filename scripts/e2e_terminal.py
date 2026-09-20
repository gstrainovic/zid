#!/usr/bin/env python3
"""Headless-E2E für das Terminal: Scrollbalken (Lage, Blättern, Ziehen, Pfeil-Cursor,
gezeichnet). Aufruf: python3 scripts/e2e_terminal.py
"""
import os, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e2e_open_folder import ROOT, rpc, result_json, wait_port, settle, bounds, check, shot, start_zid, stop_zid  # noqa: E402
from e2e_shortcuts import key, ui_state  # noqa: E402
from e2e_pdf_pager import pixel  # noqa: E402
from e2e_md_preview import differs  # noqa: E402


def term():
    return result_json("terminal_state")


def wait_for(cond, what, timeout=10):
    t0 = time.time()
    while time.time() - t0 < timeout:
        if cond():
            check(True, what)
            return
        time.sleep(0.1)
    check(False, what)


def step_scrollbar():
    print("--- Scrollbalken: Lage, Blättern, Ziehen, Pfeil-Cursor, gezeichnet")
    rpc("open_terminal"); settle(10)
    wait_for(lambda: term() is not None and term()["visible_rows"] > 5, "Terminal-Tab offen")
    rpc("type_text", ["seq 1 400"]); key("enter")
    wait_for(lambda: term()["total_rows"] > 400, "Ausgabe länger als der Bildschirm")
    settle(10)
    st = term()
    idx = st["pane_index"]
    max_row = st["total_rows"] - st["visible_rows"]
    check(st["view_row"] == max_row, f"Terminal folgt der Ausgabe ans Ende ({st['view_row']} von {max_row})")
    outer = bounds("terminal_outer", idx)
    track = bounds("terminal_scrollbar_track", idx)
    thumb = bounds("terminal_scrollbar_thumb", idx)
    check(abs(track["y"] - outer["y"]) < 1 and abs(track["h"] - outer["h"]) < 1, "Track so hoch wie das Terminal")
    check(abs(track["x"] + track["w"] - (outer["x"] + outer["w"])) < 1, "Track am rechten Rand")
    check(abs(thumb["y"] + thumb["h"] - (track["y"] + track["h"])) < 1,
          f"Thumb am Ende steht unten im Track (Thumb-Unterkante {thumb['y'] + thumb['h']:.0f}, Track {track['y'] + track['h']:.0f})")
    # Cursorform: Pfeil über Thumb und Track
    tx = track["x"] + track["w"] / 2
    rpc("move_mouse", [tx, thumb["y"] + thumb["h"] / 2]); settle()
    check(ui_state()["cursor"] == "arrow", f"Pfeil über dem Thumb ({ui_state()['cursor']})")
    rpc("move_mouse", [tx, track["y"] + 5]); settle()
    check(ui_state()["cursor"] == "arrow", f"Pfeil über dem Track ({ui_state()['cursor']})")
    # Screenshot: Thumb heller als der Track
    shot("e2e_terminal_scrollbar.ppm")
    on_thumb = pixel("e2e_terminal_scrollbar.ppm", tx, thumb["y"] + thumb["h"] / 2)
    on_track = pixel("e2e_terminal_scrollbar.ppm", tx, thumb["y"] - 40)
    check(differs(on_thumb, on_track), f"Thumb ist gezeichnet ({on_thumb} neben Track {on_track})")
    # Klick über dem Thumb blättert eine Seite zurück
    rpc("click", [tx, track["y"] + 5]); settle()
    check(term()["view_row"] == max_row - st["visible_rows"], f"Klick über dem Thumb blättert eine Seite ({term()['view_row']})")
    # Thumb ziehen bis ganz nach oben: Zeile 0
    thumb = bounds("terminal_scrollbar_thumb", idx)
    x0, y0 = tx, thumb["y"] + thumb["h"] / 2
    rpc("mouse_down", [x0, y0]); settle()
    for i in range(1, 6):
        rpc("move_mouse", [x0, y0 - (y0 - track["y"] + 50) * i / 5]); settle(3)
    rpc("mouse_up", [x0, track["y"] - 50]); settle()
    check(term()["view_row"] == 0, f"Thumb nach oben ziehen scrollt an den Anfang ({term()['view_row']})")
    thumb2 = bounds("terminal_scrollbar_thumb", idx)
    check(abs(thumb2["y"] - track["y"]) < 1, "Thumb steht oben")


STEPS = [step_scrollbar]


def step_toggle():
    """Ctrl+J: hin zum zuletzt benutzten Terminal, zurück zum Tab davor.

    Vorher sprang es immer zum ersten Terminal, und war der gemerkte Tab inzwischen
    selbst ein Terminal, tat die Taste gar nichts."""
    print("--- Ctrl+J wechselt zum zuletzt benutzten Terminal und zurück")
    rpc("open_file", [os.path.join(ROOT, "README.md")])
    settle(10)
    start = ui_state()["active_tab"]

    rpc("open_terminal"); settle(10)
    rpc("open_terminal"); settle(10)
    second = ui_state()["active_tab"]

    # Zurück auf die Datei, dann Ctrl+J: erwartet das zuletzt benutzte Terminal
    rpc("setActiveTab", [start]); settle(8)
    key("j", ctrl=True); settle(8)
    check(ui_state()["active_tab"] == second, f"Ctrl+J öffnet das zuletzt benutzte Terminal (ist {ui_state()['active_tab']}, erwartet {second})")

    key("j", ctrl=True); settle(8)
    check(ui_state()["active_tab"] == start, f"Ctrl+J springt zurück zur Datei (ist {ui_state()['active_tab']}, erwartet {start})")


def main():
    log = open(os.path.join(ROOT, "tmp", "e2e_terminal.log"), "w")
    proc = start_zid(["--headless", "--ai=off"], log)
    try:
        wait_port(proc)
        settle(20)
        for step in STEPS:
            step()
        step_toggle()
    finally:
        stop_zid(proc)
        log.close()
    print("ALL PASSED")


if __name__ == "__main__":
    main()
