#!/usr/bin/env python3
"""Headless-E2E: Ctrl+F über der Markdown-Vorschau und danach im Editor-Tab.

Ablauf: tmp/e2e_find_preview.md öffnen, Vorschau über das Tab-Menü öffnen, Ctrl+F drücken und
tippen (die Suchleiste gehört dem Editor, die Vorschau zeigt sie nicht), zurück in den
Editor-Tab, Ctrl+F, tippen, Backspace. Prüft, dass der Suchbegriff stimmt, dass kein Zeichen im
Buffer landet und dass Clay keine duplicate_id meldet. Aufruf: python3 scripts/e2e_find_preview.py
"""
import os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e2e_open_folder import ROOT, rpc, result_json, wait_port, settle, bounds, check, start_zid, stop_zid  # noqa: E402

FIXTURE = os.path.join(ROOT, "tmp", "e2e_find_preview.md")
TEXT = "# Titel\n\nErster Absatz mit Konto.\n\nZweiter Absatz.\n"


def tabs():
    return result_json("ui_state")["tabs"]


def click_tab(pred):
    idx = next(i for i, t in enumerate(tabs()) if pred(t))
    b = result_json("tab_bounds", [idx])
    rpc("click", [b["x"] + b["w"] / 2, b["y"] + b["h"] / 2])
    settle(20)


def open_preview():
    idx = next(i for i, t in enumerate(tabs()) if t["path"] == FIXTURE)
    b = result_json("tab_bounds", [idx])
    rpc("right_click", [b["x"] + b["w"] / 2, b["y"] + b["h"] / 2])
    settle(4)
    e = bounds("tab_menu_md_preview")
    rpc("click", [e["x"] + e["w"] / 2, e["y"] + e["h"] / 2])
    settle(40)


def key(name, ctrl=False):
    rpc("key_press", [name, ctrl])
    settle(4)


def active_path():
    st = result_json("ui_state")
    return st["tabs"][st["active_tab"]]["path"]


def editor_state():
    return result_json("editor_state")


def main():
    with open(FIXTURE, "w") as f:
        f.write(TEXT)
    log = open(os.path.join(ROOT, "tmp", "e2e_find_preview.log"), "w")
    proc = start_zid(["--headless", "--ai=off"], log)
    try:
        wait_port(proc)
        settle(20)
        rpc("open_file", [FIXTURE])
        settle(30)
        open_preview()
        rpc("screenshot"); settle(10)
        check(active_path() == "preview://" + FIXTURE, "Vorschau-Tab aktiv")

        print("--- Ctrl+F über der Vorschau")
        key("f", ctrl=True)
        rpc("type_text", ["Konto"]); settle(6)
        rpc("screenshot"); settle(10)
        st = editor_state()
        check(not st["find_open"], f"Vorschau: Ctrl+F öffnet keine Suchleiste im unsichtbaren Editor (find_open={st['find_open']})")
        check(st["find_query"] == "", f"Vorschau: Getipptes landet nicht im Suchfeld ({st['find_query']!r})")
        check(st["text"] == TEXT, "Vorschau: Tippen ändert den Buffer nicht")
        errs = result_json("ui_state")["clay_errors"]
        check(errs == 0, f"Vorschau: keine Clay-Fehler ({errs})")

        print("--- zurück in den Editor-Tab, Ctrl+F, tippen, Backspace")
        click_tab(lambda t: t["path"] == FIXTURE)
        check(active_path() == FIXTURE, "Editor-Tab aktiv")
        key("f", ctrl=True)
        rpc("screenshot"); settle(10)
        st = editor_state()
        check(st["find_open"], "Ctrl+F im Editor öffnet die Suchleiste")
        check(bounds("find_input")["found"], "Suchfeld wird gezeichnet")
        rpc("type_text", ["Absatz"]); settle(6)
        st = editor_state()
        check(st["find_query"] == "Absatz", f"Suchbegriff: {st['find_query']!r}")
        key("backspace")
        st = editor_state()
        check(st["find_query"] == "Absat", f"Backspace kürzt den Suchbegriff: {st['find_query']!r}")
        check(st["text"] == TEXT, "Editor: Suchen ändert den Buffer nicht")
        rpc("screenshot"); settle(10)
        errs = result_json("ui_state")["clay_errors"]
        check(errs == 0, f"Editor: keine Clay-Fehler ({errs})")
        key("escape")
        check(not editor_state()["find_open"], "Escape schließt die Suchleiste")

        print("--- Split: Suchleiste in beiden Editoren zugleich")
        rpc("split_pane", ["v"]); settle(30)
        rpc("click", [600, 700]); settle(10)
        check(result_json("ui_state")["active_pane_index"] == 1, "Klick unten aktiviert die zweite Pane")
        key("f", ctrl=True)
        rpc("click", [600, 200]); settle(10)
        check(result_json("ui_state")["active_pane_index"] == 0, "Klick oben aktiviert die erste Pane")
        key("f", ctrl=True)
        rpc("screenshot"); settle(10)
        check(bounds("find_input")["found"], "Suchfeld der aktiven Pane wird gezeichnet")
        errs = result_json("ui_state")["clay_errors"]
        check(errs == 0, f"Split: zwei Suchleisten ohne Clay-Fehler ({errs})")
        print("ALLE PRÜFUNGEN BESTANDEN")
    finally:
        stop_zid(proc)
        log.close()


if __name__ == "__main__":
    main()
