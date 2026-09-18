#!/usr/bin/env python3
"""Headless-E2E für die Auswahl in den kleinen Editierfeldern (line_edit / EditBuffer):
Commit-Nachricht (mehrzeilig) und Umbenennen im Explorer. Shift+Pfeile, Ctrl+Shift+Pfeile,
Ctrl+A/C/X/V, Tippen ersetzt die Auswahl, Shift+Klick und Ziehen mit der Maus, Markierung
als Element `<feld>_sel`. Aufruf: python3 scripts/e2e_line_edit.py
"""
import os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e2e_open_folder import ROOT, rpc, result_json, wait_port, settle, start_zid, stop_zid, check, bounds  # noqa: E402


def key(name, ctrl=False, shift=False):
    rpc("key_press_mods", [name, ctrl, shift]); settle(2)


def msg():
    return result_json("scm_state")["changes"]["message"]


def clip():
    return result_json("ui_state")["clipboard_text"]


def sel_box(elem, index=None):
    if index is None:
        return result_json("element_bounds", [elem])
    return result_json("element_bounds_i", [elem, index])


def step_commit_message():
    print("--- Commit-Nachricht: Tastatur")
    rpc("key_press_mods", ["g", True, True]); settle(30)
    rpc("type_text", ["hallo welt"]); settle(4)
    check(msg() == "hallo welt", "getippt")
    for _ in range(4):
        key("left", shift=True)
    key("c", ctrl=True)
    check(clip() == "welt", f"Shift+← markiert, Ctrl+C kopiert: {clip()!r}")
    rpc("type_text", ["x"]); settle(4)
    check(msg() == "hallo x", f"Tippen ersetzt die Auswahl: {msg()!r}")
    key("a", ctrl=True)
    key("x", ctrl=True)
    check(msg() == "" and clip() == "hallo x", f"Ctrl+A, Ctrl+X: msg={msg()!r} clip={clip()!r}")
    key("v", ctrl=True)
    key("v", ctrl=True)
    check(msg() == "hallo xhallo x", f"Ctrl+V zweimal: {msg()!r}")
    key("left", ctrl=True, shift=True)
    key("backspace")
    check(msg() == "hallo xhallo ", f"Ctrl+Shift+← markiert das Wort, Backspace löscht: {msg()!r}")
    rpc("type_text", ["zwei"]); settle(2)
    key("enter")
    rpc("type_text", ["drei"]); settle(2)
    # Cursor hinter "drei" (Spalte 4), Shift+↑ nach Zeile 0 Spalte 4: über den Umbruch markiert
    key("up", shift=True)
    key("delete")
    check(msg() == "hall", f"Auswahl über den Umbruch gelöscht: {msg()!r}")
    key("a", ctrl=True)
    b = sel_box("sc_input_sel", 0)
    check(b["found"] and b["w"] > 10, f"Markierung als Rechteck im Feld: {b}")
    # Einfügen einzeilig in mehrzeiliges Feld: Umbruch bleibt erhalten
    rpc("type_text", ["a"]); settle(2)
    key("enter")
    rpc("type_text", ["b"]); settle(2)
    key("a", ctrl=True)
    key("c", ctrl=True)
    check(clip() == "a\nb", f"mehrzeilig kopiert: {clip()!r}")
    key("end")
    key("v", ctrl=True)
    check(msg() == "a\nba\nb", f"mehrzeilig eingefügt: {msg()!r}")


def step_commit_mouse():
    print("--- Commit-Nachricht: Maus")
    key("a", ctrl=True)
    rpc("type_text", ["hallo welt"]); settle(3)
    ib = bounds("sc_input_box")
    y = ib["y"] + 12
    rpc("click", [ib["x"] + 8, y]); settle(3)
    # „Element ist weg“ ist in Clay nicht prüfbar (alte Geometrie bleibt): ohne Auswahl
    # schneidet Ctrl+X nichts aus
    key("x", ctrl=True)
    check(msg() == "hallo welt", f"Klick hebt die Auswahl auf (Ctrl+X ändert nichts): {msg()!r}")
    rpc("click_mods", [ib["x"] + 200, y, False, True]); settle(3)
    b = sel_box("sc_input_sel", 0)
    check(b["found"] and b["w"] > 60, f"Shift+Klick markiert bis zum Klick: {b}")
    key("c", ctrl=True)
    check(clip() == "hallo welt", f"Shift+Klick-Auswahl kopiert: {clip()!r}")
    rpc("mouse_down", [ib["x"] + 8, y])
    rpc("move_mouse", [ib["x"] + 40, y]); settle(3)
    b1 = sel_box("sc_input_sel", 0)
    rpc("move_mouse", [ib["x"] + 70, y]); settle(3)
    b2 = sel_box("sc_input_sel", 0)
    rpc("mouse_up", [ib["x"] + 70, y]); settle(3)
    check(b1["found"] and b2["found"] and b2["w"] > b1["w"], f"Ziehen erweitert die Markierung: {b1['w']:.0f} → {b2['w']:.0f}")
    rpc("move_mouse", [ib["x"] + 20, y]); settle(3)
    b3 = sel_box("sc_input_sel", 0)
    check(abs(b3["w"] - b2["w"]) < 1, "nach dem Loslassen zieht Bewegen nicht weiter")


def step_rename():
    print("--- Umbenennen im Explorer")
    rpc("key_press_mods", ["e", True, True]); settle(6)
    ex = result_json("explorer_entries")
    names = [e["name"] for e in ex["entries"]]
    target = "README.md" if "README.md" in names else names[-1]
    idx = names.index(target)
    vp, rh = ex["viewport"], ex["row_height"]
    rpc("click", [vp["x"] + 60, vp["y"] + idx * rh + rh / 2 - ex["scroll"]]); settle(4)
    key("f2")
    check(result_json("explorer_entries")["renaming"], "Umbenennen aktiv")
    key("a", ctrl=True)
    b = sel_box("fx_rename_text_sel")
    check(b["found"] and b["w"] > 20, f"Ctrl+A markiert den Namen: {b}")
    key("c", ctrl=True)
    check(clip() == target, f"Ctrl+C im Umbenennen-Feld: {clip()!r}")
    key("home")
    key("right", ctrl=True, shift=True)
    key("c", ctrl=True)
    check(clip() == target.split(".")[0], f"Ctrl+Shift+→ markiert das erste Wort: {clip()!r}")
    key("escape")
    check(not result_json("explorer_entries")["renaming"], "Escape bricht ab, Name unverändert")


def main():
    log = open(os.path.join(ROOT, "tmp", "e2e_line_edit.log"), "w")
    proc = start_zid(["--headless", "--ai=off"], log)
    try:
        wait_port(proc)
        settle(20)
        rpc("open_folder", [ROOT]); settle(20)
        step_commit_message()
        step_commit_mouse()
        step_rename()
        print("ALL PASSED")
    finally:
        stop_zid(proc)
        log.close()


if __name__ == "__main__":
    main()
