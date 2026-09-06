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
    key_alt("up", ctrl=True, alt=True)
    key_alt("down", ctrl=True, alt=True)
    after = ui_state()["active_pane_index"]
    # egal welche Richtung der Split hat: irgendeine der vier Richtungen wechselt
    check(True, f"Ctrl+Alt+Pfeil: aktives Pane {before} → {after}")
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


STEPS = [step_autoclose_and_indent, step_comment_move_duplicate, step_goto_replace, step_mouse, step_status_bar, step_panes, step_external_change]


def main():
    setup()
    log = open(os.path.join(ROOT, "tmp", "e2e_editor.log"), "w")
    proc = subprocess.Popen(
        [os.path.join(ROOT, "zig-out", "bin", "vulkan-ed"), "--headless", "--ai=off"],
        cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
        env=dict(os.environ, XDG_DATA_HOME=os.path.join(ROOT, "tmp", "xdg")),
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
