#!/usr/bin/env python3
"""Headless-E2E: Ctrl+F in der Markdown-Vorschau und danach im Editor-Tab.

Ablauf: tmp/e2e_find_preview.md öffnen, Vorschau über das Tab-Menü öffnen, Ctrl+F: die
Vorschau zeigt dieselbe Suchleiste wie der Editor (`find_bar.zig`), zählt Treffer, springt mit
Enter/Shift+Enter (auch weit nach unten, der Treffer muss im Sichtbereich stehen), Alt+C schaltet
Groß/Klein. Danach zurück in den Editor-Tab, Ctrl+F, tippen, Backspace. Prüft, dass kein Zeichen
im Buffer landet und dass Clay keine duplicate_id meldet. Aufruf: python3 scripts/e2e_find_preview.py
"""
import os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e2e_open_folder import ROOT, rpc, result_json, wait_port, settle, bounds, check, start_zid, stop_zid  # noqa: E402

FIXTURE = os.path.join(ROOT, "tmp", "e2e_find_preview.md")
# Vier Treffer für „konto“ ohne Groß/Klein: oben, weit unten zweimal (einmal KONTO), im Codeblock.
TEXT = ("# Titel\n\nErster Absatz mit Konto.\n\nZweiter Absatz.\n\n"
        + "".join(f"Fülltext {i} ohne den Begriff.\n\n" for i in range(80))
        + "Letzter Absatz mit Konto und KONTO.\n\n```\ncode Konto\n```\n")


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


def find_state():
    return result_json("md_find_state")


def current_line_visible():
    """Zeile des aktuellen Treffers liegt im Viewport der Vorschau."""
    st = find_state()
    if st["current_line"] is None:
        return False, st
    line = result_json("element_bounds_i", ["md_line", st["current_line"]])
    vp = bounds("md_viewport")
    ok = line["found"] and line["y"] >= vp["y"] and line["y"] + line["h"] <= vp["y"] + vp["h"]
    return ok, st


def main():
    with open(FIXTURE, "w", encoding="utf-8", newline="\n") as f:
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

        print("--- Ctrl+F in der Vorschau: Suchleiste wie im Editor")
        key("f", ctrl=True)
        rpc("type_text", ["konto"]); settle(10)
        rpc("screenshot"); settle(10)
        fs = find_state()
        check(fs["open"], "Vorschau: Ctrl+F öffnet die Suchleiste der Vorschau")
        check(fs["query"] == "konto", f"Vorschau: Suchbegriff {fs['query']!r}")
        check(fs["total"] == 4, f"Vorschau: vier Treffer ohne Groß/Klein ({fs['total']})")
        check(fs["current"] == 0, f"Vorschau: erster Treffer ab Leseposition ({fs['current']})")
        check(bounds("md_find_input")["found"], "Vorschau: Suchfeld wird gezeichnet")
        check(result_json("element_bounds_i", ["md_hit_cur", 1])["found"], "Vorschau: aktueller Treffer ist markiert")
        st = editor_state()
        check(not st["find_open"] and st["find_query"] == "", "Vorschau: unsichtbarer Editor bekommt nichts ab")
        check(st["text"] == TEXT, "Vorschau: Tippen ändert den Buffer nicht")

        print("--- Enter springt nach unten, Treffer im Sichtbereich")
        key("enter"); settle(20)
        ok, fs = current_line_visible()
        check(fs["current"] == 1 and fs["scroll_y"] > 0, f"Enter: zweiter Treffer, gescrollt ({fs['current']}, {fs['scroll_y']})")
        check(ok, f"Enter: Zeile des Treffers liegt im Viewport ({fs})")
        key("enter"); settle(20)
        key("enter"); settle(20)
        ok, fs = current_line_visible()
        check(fs["current"] == 3 and ok, f"Treffer im Codeblock sichtbar ({fs['current']})")
        key("enter"); settle(20)
        ok, fs = current_line_visible()
        check(fs["current"] == 0 and ok, f"Enter nach dem letzten springt zum ersten, oben sichtbar ({fs})")
        rpc("key_press_mods", ["enter", False, True]); settle(20)
        ok, fs = current_line_visible()
        check(fs["current"] == 3 and ok, f"Shift+Enter rückwärts mit Umbruch ({fs['current']})")

        print("--- Alt+C: Groß/Klein")
        rpc("key_press_alt", ["c", False, False, True]); settle(10)
        fs = find_state()
        check(fs["case_sensitive"] and fs["total"] == 0 and fs["not_found"], f"Alt+C: 'konto' klein findet nichts ({fs['total']})")
        rpc("key_press_alt", ["c", False, False, True]); settle(10)
        fs = find_state()
        check(not fs["case_sensitive"] and fs["total"] == 4, f"Alt+C erneut: wieder vier ({fs['total']})")
        key("backspace"); settle(6)
        check(find_state()["query"] == "kont", "Backspace kürzt den Begriff")
        errs = result_json("ui_state")["clay_errors"]
        check(errs == 0, f"Vorschau: keine Clay-Fehler ({errs})")
        key("escape"); settle(6)
        check(not find_state()["open"], "Escape schließt die Suchleiste der Vorschau")
        check(editor_state()["text"] == TEXT, "Vorschau: Buffer unverändert")

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
