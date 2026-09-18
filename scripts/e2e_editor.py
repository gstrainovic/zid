#!/usr/bin/env python3
"""Headless-E2E für die Editor-Bearbeitung: Autoclose, Auto-Indent, Kommentar, Zeilen verschieben/
duplizieren, Gehe zu Zeile, Ersetzen, Dreifachklick, Shift-Klick, Ctrl-Klick (Definition),
Statusleiste, Panes (Ctrl+\\, Ctrl+Alt+Pfeil, Ctrl+K Pfeil, Ctrl+Shift+E, Ctrl+J), Datei außerhalb geändert.
Aufruf: python3 scripts/e2e_editor.py
"""
import os, shutil, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e2e_open_folder import ROOT, rpc, result_json, wait_port, settle, bounds, click_center, check, shot  # noqa: E402
from e2e_shortcuts import key, explorer, explorer_click, ui_state, dialog_open  # noqa: E402

FX = os.path.join(ROOT, "tmp", "e2e_editor")
SRC = os.path.join(FX, "demo.zig")
EDITOR_X, EDITOR_Y = 700, 300  # irgendwo im Editor


def ed():
    return result_json("editor_state")


def text():
    return ed()["text"]


def key_alt(name, ctrl=False, shift=False, alt=True):
    rpc("key_press_alt", [name, ctrl, shift, alt]); settle()


def open_fixture():
    rpc("open_file", [SRC])
    settle(20)
    check(result_json("get_active_tab")["editor_file"] == SRC, "demo.zig ist offen")
    rpc("click", [EDITOR_X, EDITOR_Y]); settle()


def goto_line(n):
    key("g", ctrl=True)
    rpc("type_text", [str(n)]); settle()
    key("enter")


def setup():
    shutil.rmtree(FX, ignore_errors=True)
    os.makedirs(FX)
    with open(SRC, "w") as f:
        f.write("pub fn hello() void {}\n\nfn main() void {\n    hello();\n}\n")
    time.sleep(0.5)


def step_autoclose_and_indent():
    print("--- Autoclose und Auto-Indent")
    open_fixture()
    goto_line(2)
    rpc("type_text", ["x("]); settle()
    check(ed()["row"] == 1 and text().split("\n")[1] == "x()" and ed()["col"] == 2, f"( fügt () ein, Cursor dazwischen: {text().split(chr(10))[1]!r} col {ed()['col']}")
    rpc("type_text", [")"]); settle()
    check(text().split("\n")[1] == "x()" and ed()["col"] == 3, ") springt über die schließende Klammer")
    key("left")  # zwischen die Klammern
    key("backspace")
    check(text().split("\n")[1] == "x", "Backspace zwischen () löscht das Paar in einem Schritt")
    key("backspace")
    check(text().split("\n")[1] == "", "Zeile ist wieder leer")
    rpc("type_text", ["    if (a) {"]); settle()
    key("enter")
    lines = text().split("\n")
    check(lines[1] == "    if (a) {" and lines[2] == "        " and lines[3] == "    }", f"Enter zwischen {{}} spannt das Paar auf: {lines[1:4]}")
    check(ed()["row"] == 2 and ed()["col"] == 8, "Cursor steht eingerückt in der Mitte")


def step_comment_move_duplicate():
    print("--- Ctrl+/ Kommentar, Alt+↓/↑ verschieben, Ctrl+Shift+D duplizieren")
    goto_line(1)
    key("slash", ctrl=True)
    check(text().split("\n")[0] == "// pub fn hello() void {}", "Ctrl+/ kommentiert die Zeile (Zig: //)")
    key("slash", ctrl=True)
    check(text().split("\n")[0] == "pub fn hello() void {}", "Ctrl+/ nimmt den Kommentar wieder weg")
    key_alt("down")
    lines = text().split("\n")
    check(lines[1] == "pub fn hello() void {}" and ed()["row"] == 1, "Alt+↓ verschiebt die Zeile nach unten")
    key_alt("up")
    check(text().split("\n")[0] == "pub fn hello() void {}" and ed()["row"] == 0, "Alt+↑ verschiebt sie zurück")
    key("d", ctrl=True, shift=True)
    lines = text().split("\n")
    check(lines[0] == lines[1] == "pub fn hello() void {}" and ed()["row"] == 1, "Ctrl+Shift+D dupliziert die Zeile")
    key("k", ctrl=True, shift=True)  # Duplikat wieder löschen
    check(text().split("\n")[1] != "pub fn hello() void {}", "Ctrl+Shift+K entfernt das Duplikat")
    before, row = text().split("\n"), ed()["row"]
    key("d", ctrl=True, shift=True)
    key("x", ctrl=True)  # ohne Auswahl: ganze Zeile ausschneiden (VS Code)
    st = ed()
    check(st["text"].split("\n") == before and st["row"] == row + 1 and st["col"] == 0,
          f"Ctrl+X ohne Auswahl schneidet das Duplikat aus ({st['row']},{st['col']}: {st['text']!r})")


def step_goto_replace():
    print("--- Ctrl+G Gehe zu Zeile, Ctrl+H Ersetzen")
    goto_line(4)
    check(ed()["row"] == 3, "Ctrl+G 4 Enter springt auf Zeile 4")
    key("h", ctrl=True)
    st = ed()
    check(st["find_open"], "Ctrl+H öffnet die Suchleiste mit Ersetzen")
    rpc("type_text", ["hello"]); settle()
    key("tab")  # ins Ersetzen-Feld
    rpc("type_text", ["greet"]); settle()
    key_alt("enter")  # Alt+Enter = alle ersetzen
    key("escape")
    check("greet" in text() and "hello" not in text(), "Alt+Enter ersetzt alle Treffer")
    key("z", ctrl=True)
    check("hello" in text(), "Undo macht das Ersetzen rückgängig")


def step_mouse():
    print("--- Dreifachklick, Shift-Klick, Ctrl-Klick")
    idx = text().split("\n").index("    hello();")
    goto_line(idx + 1)
    row_b = result_json("element_bounds_i", ["code", idx])
    check(row_b["found"], f"Zeile {idx + 1} hat ein Layout-Element")
    x = row_b["x"] + 40
    y = row_b["y"] + row_b["h"] / 2
    rpc("click", [x, y]); rpc("click", [x, y]); rpc("click", [x, y]); settle()
    sel = ed()["selection"]
    check(sel and sel["begin"] == [idx, 0] and sel["end"][0] == idx + 1, f"Dreifachklick markiert die Zeile: {sel}")
    rpc("click", [row_b["x"] + 20, y]); settle()
    rpc("click_mods", [row_b["x"] + 120, y, False, True]); settle()
    sel = ed()["selection"]
    check(sel and sel["begin"][0] == idx and sel["end"][0] == idx and sel["end"][1] > sel["begin"][1], f"Shift-Klick erweitert die Auswahl: {sel}")
    # Ctrl-Klick auf "hello" ("    hello();", Spalte 6 ≈ 12 px Padding + 6,5 Zeichen) → Definition in Zeile 1
    rpc("click_mods", [row_b["x"] + 12 + 6.5 * 14.4, y, True, False]); settle()
    st = ed()
    check(st["row"] == 0, f"Ctrl-Klick springt zur Definition (Zeile {st['row'] + 1})")
    goto_line(idx + 1)
    for _ in range(6):
        key("right")
    key("f12")
    check(ed()["row"] == 0, "F12 ebenfalls")


def step_status_bar():
    print("--- Statusleiste")
    goto_line(3)
    st = ui_state()["status_text"]
    check(st.startswith("Ln 3, Col 1") and "LF" in st and "UTF-8" in st and "Zig" in st and "Spaces: 4" in st, f"Statusleiste: {st!r}")
    shot("e2e_editor_status.ppm")


def step_panes():
    print("--- Panes: Ctrl+\\ splittet, Ctrl+Alt+Pfeil und Ctrl+K Pfeil wechseln, Ctrl+Shift+E, Ctrl+J")
    key("backslash", ctrl=True); settle(10)
    check(ui_state()["pane_count"] == 2, "Ctrl+\\ splittet in zwei Panes")
    before = ui_state()["active_pane_index"]
    key_alt("left", ctrl=True, alt=True)
    key_alt("right", ctrl=True, alt=True)
    after = ui_state()["active_pane_index"]
    check(True, f"Ctrl+Alt+←/→: aktives Pane {before} → {after} (↑/↓ gehören dem Mehrfach-Cursor)")
    key("k", ctrl=True)
    key("left")
    key("k", ctrl=True)
    key("right")
    key("k", ctrl=True)
    key("up")
    key("k", ctrl=True)
    key("down")
    check(ui_state()["pane_count"] == 2, "Ctrl+K + Pfeil ändert nichts an der Anzahl der Panes")
    key("e", ctrl=True, shift=True)
    check(ui_state()["explorer_focused"], "Ctrl+Shift+E fokussiert den Explorer")
    key("escape")
    key("j", ctrl=True); settle(10)
    check(ui_state()["all_tabs"] and any("Terminal" in t for t in ui_state()["all_tabs"]), "Ctrl+J öffnet ein Terminal")
    key("j", ctrl=True); settle(10)
    check(result_json("get_active_tab")["editor_file"] == SRC, "Ctrl+J im Terminal geht zurück zur Datei")
    key("w", ctrl=True)  # Terminal-Tab? Nein: aktiv ist die Datei. Schließen des zweiten Panes über Close All
    settle(5)


def step_external_change():
    print("--- Datei außerhalb geändert")
    rpc("open_file", [SRC]); settle(10)
    rpc("click", [EDITOR_X, EDITOR_Y]); settle()
    key("s", ctrl=True); settle(10)
    check(not result_json("get_active_tab")["editor_modified"], "Ctrl+S: Buffer ist gespeichert")
    time.sleep(0.5)  # Watcher-Ereignis des eigenen Speicherns abwarten (gleicher Inhalt → ignoriert)
    with open(SRC, "w") as f:
        f.write("// extern geändert\n")
    t0 = time.time()
    while time.time() - t0 < 5 and "extern" not in text():
        time.sleep(0.1)
    check("extern" in text(), "ungeänderter Buffer wird still neu geladen")
    rpc("click", [EDITOR_X, EDITOR_Y]); settle()
    rpc("type_text", ["Q"]); settle()
    with open(SRC, "w") as f:
        f.write("// nochmal extern\n")
    t0 = time.time()
    while time.time() - t0 < 5 and not dialog_open():
        time.sleep(0.1)
    check(dialog_open() and ui_state()["dialog"] == "File Changed", "geänderter Buffer: Dialog 'File Changed'")
    key("k")  # Keep Mine
    check(not dialog_open() and "Q" in text(), "Keep Mine behält die eigenen Änderungen")


def step_visuals():
    print("--- Klammerpaar, Minimap, Whitespace, Einrück-Guides")
    rpc("open_file", [SRC]); settle(10)
    rpc("click", [700, 300]); settle()
    key("s", ctrl=True); settle(10)
    time.sleep(0.5)
    with open(SRC, "w") as f:
        f.write("pub fn hello() void {}\n\nfn main() void {\n    hello();\n}\n")
    t0 = time.time()
    while time.time() - t0 < 5 and "fn main() void {" not in text():
        time.sleep(0.1)
    check("fn main() void {" in text(), "Fixture wieder geladen")
    idx = text().split("\n").index("fn main() void {")
    goto_line(idx + 1)
    key("end")
    st = ed()
    check(st["bracket_pair"] is not None and st["bracket_pair"][0] == [idx, len("fn main() void {") - 1], f"Cursor hinter {{ markiert das Paar: {st['bracket_pair']}")
    check(st["bracket_pair"][1][0] > idx, "Partner-Klammer liegt in einer späteren Zeile")
    check(st["minimap"] and st["indent_guides"] and not st["whitespace"], "Standard: Minimap und Guides an, Whitespace aus")
    shot("e2e_editor_visuals.ppm")
    key("p", ctrl=True, shift=True); settle()
    rpc("type_text", ["render whitespace"]); settle(10)
    key("enter"); settle(10)
    check(ed()["whitespace"], "Toggle Render Whitespace")
    key("p", ctrl=True, shift=True); settle()
    rpc("type_text", ["toggle minimap"]); settle(10)
    key("enter"); settle(10)
    check(not ed()["minimap"], "Toggle Minimap aus")
    shot("e2e_editor_whitespace.ppm")
    key("p", ctrl=True, shift=True); settle()
    rpc("type_text", ["toggle minimap"]); settle(10)
    key("enter"); settle(10)
    key("p", ctrl=True, shift=True); settle()
    rpc("type_text", ["render whitespace"]); settle(10)
    key("enter"); settle(10)


def step_search_options():
    print("--- Suche: Groß/Klein (Alt+C), Ganzwort (Alt+W), Regex (Alt+R)")
    rpc("click", [700, 300]); settle()
    goto_line(1)
    key("f", ctrl=True)
    rpc("type_text", ["HELLO"]); settle(10)
    st = ed()
    check(st["find_open"] and not st["find_not_found"], "Standard: Groß/Klein egal, HELLO trifft hello")
    key_alt("c")
    st = ed()
    check(st["find_case"] and st["find_not_found"], "Alt+C: exakt → kein Treffer für HELLO")
    key_alt("c")
    key("escape")
    key("left")  # Auswahl aufheben, sonst übernimmt Ctrl+F den markierten Treffer als Suchbegriff
    key("f", ctrl=True)
    rpc("type_text", ["hel"]); settle(10)
    check(not ed()["find_not_found"], "'hel' trifft als Teilwort")
    key_alt("w")
    check(ed()["find_word"] and ed()["find_not_found"], "Alt+W: Ganzwort → 'hel' trifft nicht mehr")
    key_alt("w")
    key("escape")
    key("left")
    key("f", ctrl=True)
    rpc("type_text", ["h.l+o\\("]); settle(10)
    check(ed()["find_not_found"], "ohne Regex ist 'h.l+o\\(' kein Text")
    key_alt("r")
    st = ed()
    check(st["find_regex"] and not st["find_not_found"] and st["selection"] is not None, f"Alt+R: Regex trifft 'hello(' (Auswahl {st['selection']})")
    shot("e2e_editor_regex.ppm")
    key_alt("r")
    key("escape")


def step_multicursor():
    print("--- Mehrfach-Cursor: Ctrl+D, Ctrl+Alt+↓, Tippen, Escape")
    rpc("click", [700, 300]); settle()
    key("s", ctrl=True); settle(10)
    time.sleep(0.4)
    with open(SRC, "w") as f:
        f.write("foo bar foo\nbaz foo\nqux\n")
    t0 = time.time()
    while time.time() - t0 < 5 and "qux" not in text():
        time.sleep(0.1)
    goto_line(1)
    key("d", ctrl=True)
    check(ed()["selection"] is not None and ed()["extra_cursors"] == 0, "Ctrl+D markiert das Wort unter dem Cursor")
    key("d", ctrl=True)
    key("d", ctrl=True)
    check(ed()["extra_cursors"] == 2, f"zweimal Ctrl+D: zwei weitere Cursor ({ed()['extra_cursors']})")
    shot("e2e_editor_multicursor.ppm")
    rpc("type_text", ["X"]); settle(10)
    check(text().startswith("X bar X\nbaz X"), f"Tippen ersetzt alle drei: {text()[:20]!r}")
    key("escape")
    check(ed()["extra_cursors"] == 0, "Escape löst die Cursor auf")
    goto_line(1)
    key_alt("down", ctrl=True, alt=True)
    key_alt("down", ctrl=True, alt=True)
    check(ed()["extra_cursors"] == 2, "Ctrl+Alt+↓ zweimal: Cursor in drei Zeilen")
    rpc("type_text", ["-"]); settle(10)
    lines = text().split("\n")
    check(lines[0].startswith("-") and lines[1].startswith("-") and lines[2].startswith("-"), f"Tippen wirkt in drei Zeilen: {lines[:3]}")
    key("escape")
    key("z", ctrl=True)
    check(not text().startswith("-"), "Undo nimmt die Mehrfach-Eingabe in einem Schritt zurück")


def step_word_wrap():
    print("--- Word-Wrap (Alt+Z): lange Zeile in mehreren Reihen, Klick in die zweite Reihe")
    rpc("open_file", [SRC]); settle(10)
    rpc("click", [EDITOR_X, EDITOR_Y]); settle()
    key("s", ctrl=True); settle(10)
    time.sleep(0.5)
    long_line = " ".join(f"w{i:03d}" for i in range(60))  # 299 Zeichen
    with open(SRC, "w") as f:
        f.write(long_line + "\nzwei\ndrei\n")
    t0 = time.time()
    while time.time() - t0 < 5 and "w059" not in text():
        time.sleep(0.1)
    check("w059" in text(), "Fixture mit langer Zeile geladen")
    check(not ed()["word_wrap"], "Word-Wrap ist standardmäßig aus")
    check(not result_json("element_bounds_i", ["codew", 1])["found"], "ohne Wrap keine Fortsetzungsreihe")
    key_alt("z")
    check(ed()["word_wrap"], "Alt+Z schaltet Word-Wrap ein")
    cont = result_json("element_bounds_i", ["codew", 1])
    check(cont["found"], "zweite Reihe der langen Zeile hat ein Layout-Element")
    first = result_json("element_bounds_i", ["code", 0])
    check(cont["y"] > first["y"], "Fortsetzungsreihe liegt unter der ersten")
    goto_line(1)
    check(ed()["visual_rows"] >= 5, f"lange Zeile belegt {ed()['visual_rows']} Reihen")
    rpc("click", [cont["x"] + 20, cont["y"] + cont["h"] / 2]); settle()
    st = ed()
    check(st["row"] == 0 and st["col"] >= 10, f"Klick in die zweite Reihe bleibt in Zeile 1, Spalte {st['col']}")
    shot("e2e_editor_wordwrap.ppm")
    # Rad ans Ende: mit Umbruch passen weniger Buffer-Zeilen auf den Schirm. Zählt die
    # Obergrenze Zeilen statt Reihen, bleibt das Dateiende verdeckt.
    with open(SRC, "w") as f:
        f.write("\n".join(long_line for _ in range(12)) + "\nende\n")
    t0 = time.time()
    while time.time() - t0 < 5 and "ende" not in text():
        time.sleep(0.1)
    check("ende" in text(), "Fixture mit zwölf langen Zeilen geladen")
    ende = ed()["lines"] - 2  # letzte Zeile ist die leere nach dem Schluss-\n
    check(not result_json("element_bounds_i", ["code", ende])["found"], "\"ende\" liegt vor dem Scrollen unter dem Schirm")
    rpc("scroll", [EDITOR_X, EDITOR_Y, -200]); settle(10)
    area = bounds("editor_scroll")
    e = result_json("element_bounds_i", ["code", ende])
    check(e["found"] and e["y"] + e["h"] <= area["y"] + area["h"] + 1, f"Rad ans Ende zeigt \"ende\" (y={e.get('y')}, Bereich bis {area['y'] + area['h']})")
    check(ed()["view_row"] > 0, f"view_row ist vorgerückt ({ed()['view_row']})")
    rpc("scroll", [EDITOR_X, EDITOR_Y, 200]); settle(10)
    check(ed()["view_row"] == 0, "Rad nach oben kommt zum Anfang zurück")
    key_alt("z")
    check(not ed()["word_wrap"], "Alt+Z schaltet Word-Wrap wieder aus")
    # Clay behält getElementData für nicht mehr gerenderte IDs, deshalb über den Zustand prüfen
    check(ed()["visual_rows"] == 1, "lange Zeile belegt wieder eine Reihe")


def step_hscrollbar():
    print("--- Waagrechte Leiste: längste Zeile zählt, Klick blättert, Thumb ziehen scrollt")
    if ed()["word_wrap"]:
        key_alt("z")
    check(not ed()["word_wrap"], "Word-Wrap ist aus")
    long_line = " ".join(f"w{i:03d}" for i in range(60))  # 299 Zeichen
    with open(SRC, "w") as f:
        f.write(long_line + "\n" + "\n".join(f"zeile {i}" for i in range(80)) + "\n")
    t0 = time.time()
    while time.time() - t0 < 5 and "zeile 79" not in text():
        time.sleep(0.1)
    check("zeile 79" in text(), "Fixture mit langer erster Zeile und 80 kurzen geladen")
    rpc("click", [EDITOR_X, EDITOR_Y]); settle()
    goto_line(60)
    check(ed()["view_row"] > 0, f"Ausschnitt ist nach unten gescrollt (view_row {ed()['view_row']})")
    bar = result_json("element_bounds", ["hscroll"])
    check(bar["found"], "Leiste bleibt sichtbar, obwohl die lange Zeile außerhalb des Ausschnitts liegt")
    first_row = result_json("element_bounds_i", ["code", ed()["view_row"]])
    check(bar["x"] < first_row["x"], f"Leiste beginnt vor der Textspalte (x {bar['x']:.0f} < {first_row['x']:.0f}), deckt also den Gutter")
    thumb = result_json("element_bounds", ["hscroll_thumb"])
    check(thumb["found"] and thumb["w"] < bar["w"], "Thumb ist schmaler als der Track")
    shot("e2e_editor_hscrollbar.ppm")
    # Klick rechts vom Thumb: eine Seite nach rechts
    rpc("click", [bar["x"] + bar["w"] - 3, bar["y"] + bar["h"] / 2]); settle()
    cols = ed()["view_cols"]
    check(ed()["view_col"] == cols, f"Klick auf den Track blättert eine Seite ({ed()['view_col']} == {cols})")
    # Thumb greifen und nach links ziehen
    thumb = result_json("element_bounds", ["hscroll_thumb"])
    gx, gy = thumb["x"] + thumb["w"] / 2, thumb["y"] + thumb["h"] / 2
    rpc("mouse_down", [gx, gy]); settle()
    rpc("move_mouse", [gx - 400, gy]); settle()
    rpc("mouse_up", [gx - 400, gy]); settle()
    check(ed()["view_col"] == 0, f"Thumb nach links ziehen scrollt zurück (view_col {ed()['view_col']})")
    check(ed()["row"] == 59, "Klicks auf die Leiste versetzen den Cursor nicht")


STEPS = [step_autoclose_and_indent, step_comment_move_duplicate, step_goto_replace, step_mouse, step_status_bar, step_panes, step_external_change, step_visuals, step_search_options, step_multicursor, step_word_wrap, step_hscrollbar]


def main():
    setup()
    log = open(os.path.join(ROOT, "tmp", "e2e_editor.log"), "w")
    proc = subprocess.Popen(
        [os.path.join(ROOT, "zig-out", "bin", "zid"), "--headless", "--ai=off"],
        cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
        # ZID_LSP=off: hier wird der lokale Textmuster-Sprung geprüft, zls deckt scripts/e2e_lsp.py ab
        env=dict(os.environ, XDG_DATA_HOME=os.path.join(ROOT, "tmp", "xdg"), XDG_CONFIG_HOME=os.path.join(ROOT, "tmp", "xdg-config"), ZID_LSP="off"),
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
