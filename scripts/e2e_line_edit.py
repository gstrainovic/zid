#!/usr/bin/env python3
"""Headless-E2E für die Auswahl in Editierfeldern: Commit-Nachricht (ein CodeEditor, Auswahl
über `scm_state.changes.selected_text`) und Umbenennen im Explorer (line_edit / EditBuffer,
Markierung als Element `<feld>_sel`). Shift+Pfeile, Ctrl+Shift+Pfeile, Ctrl+A/C/X/V, Tippen
ersetzt die Auswahl, Shift+Klick und Ziehen mit der Maus. Aufruf: python3 scripts/e2e_line_edit.py
"""
import os, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e2e_open_folder import ROOT, rpc, result_json, wait_port, settle, start_zid, stop_zid, check, bounds  # noqa: E402
from e2e_explorer import rows_in_view  # noqa: E402


def key(name, ctrl=False, shift=False):
    rpc("key_press_mods", [name, ctrl, shift]); settle(2)


def msg():
    return result_json("scm_state")["changes"]["message"]


def selected():
    """Markierter Text im Commit-Feld. Es ist ein CodeEditor, die Auswahl hat kein eigenes
    Element mehr (früher `sc_input_sel` aus line_edit)."""
    return result_json("scm_state")["changes"]["selected_text"]


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
    check(selected() == "hall", f"Ctrl+A markiert alles: {selected()!r}")
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
    # Nicht über Ctrl+X prüfen: im CodeEditor schneidet es ohne Auswahl die Zeile aus (VS Code)
    check(selected() == "" and msg() == "hallo welt", f"Klick hebt die Auswahl auf: {selected()!r}")
    rpc("click_mods", [ib["x"] + 200, y, False, True]); settle(3)
    check(selected() == "hallo welt", f"Shift+Klick markiert bis zum Klick: {selected()!r}")
    key("c", ctrl=True)
    check(clip() == "hallo welt", f"Shift+Klick-Auswahl kopiert: {clip()!r}")
    # sonst zählt der Druck als Doppelklick auf den vorigen Klick und markiert das Wort
    time.sleep(0.6)
    rpc("mouse_down", [ib["x"] + 8, y])
    rpc("move_mouse", [ib["x"] + 40, y]); settle(3)
    s1 = selected()
    rpc("move_mouse", [ib["x"] + 70, y]); settle(3)
    s2 = selected()
    rpc("mouse_up", [ib["x"] + 70, y]); settle(3)
    check(s1 and len(s2) > len(s1), f"Ziehen erweitert die Markierung: {s1!r} → {s2!r}")
    rpc("move_mouse", [ib["x"] + 20, y]); settle(3)
    check(selected() == s2, "nach dem Loslassen zieht Bewegen nicht weiter")


def step_rename():
    print("--- Umbenennen im Explorer")
    rpc("key_press_mods", ["e", True, True]); settle(6)
    entries = result_json("explorer_entries")["entries"]
    names = [e["name"] for e in entries]
    target = "README.md" if "README.md" in names else names[-1]
    # Im Projekt-Root liegt README.md unterhalb des Viewports: erst hereinscrollen
    [(x, y)], _ = rows_in_view(entries[names.index(target)]["path"])
    rpc("click", [x, y]); settle(4)
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
