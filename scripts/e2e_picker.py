#!/usr/bin/env python3
"""Headless-E2E für Schnellöffner (Ctrl+P) und Command Palette (Ctrl+Shift+P).
Aufruf: python3 scripts/e2e_picker.py
"""
import os, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e2e_open_folder import ROOT, rpc, result_json, wait_port, settle, bounds, click_center, check, shot  # noqa: E402
from e2e_shortcuts import key, ui_state  # noqa: E402


def picker():
    return result_json("picker_state")


def step_quick_open():
    print("--- Ctrl+P: Datei fuzzy öffnen")
    key("p", ctrl=True); settle()
    st = picker()
    check(st["open"] and st["mode"] == "files", "Ctrl+P öffnet den Picker sofort (Scan läuft im Hintergrund)")
    t0 = time.time()
    while time.time() - t0 < 20 and picker()["scanning"]:
        time.sleep(0.1)
    st = picker()
    check(not st["scanning"] and st["items"] > 50, f"Scan fertig nach {time.time() - t0:.1f}s: {st['items']} Projektdateien")
    rpc("type_text", ["uimodzig"]); settle(10)
    t0 = time.time()
    while time.time() - t0 < 5 and picker()["query"] != "uimodzig":
        time.sleep(0.05)
    settle(5)
    st = picker()
    check(st["matches"] >= 1 and st["selected_label"] == "src/ui/mod.zig", f"fuzzy 'uimodzig' → {st['selected_label']!r} ({st['matches']} Treffer)")
    shot("e2e_picker_files.ppm")
    key("enter"); settle(20)
    check(not picker()["open"], "Enter schließt den Picker")
    check(result_json("get_active_tab")["editor_file"].endswith("src/ui/mod.zig"), "src/ui/mod.zig ist offen")
    key("p", ctrl=True); settle()
    rpc("type_text", ["qqqqqqqqqq"]); settle(10)
    t0 = time.time()
    while time.time() - t0 < 5 and picker()["query"] != "qqqqqqqqqq":
        time.sleep(0.05)
    settle(5)
    check(picker()["matches"] == 0, "keine Treffer bei Unsinn")
    # Cursor in der Suchzeile: Links + Entf löscht hinter dem Cursor, Klick an den Anfang + Tippen fügt vorne ein
    key("left"); key("delete")
    check(picker()["query"] == "qqqqqqqqq", f"Links + Entf löscht ein Zeichen hinter dem Cursor: {picker()['query']}")
    b = bounds("pk_query")
    rpc("click", [b["x"] + 1, b["y"] + b["h"] / 2]); settle()
    check(picker()["open"], "Klick in die Suchzeile schließt den Picker nicht")
    rpc("type_text", ["a"]); settle(5)
    check(picker()["query"] == "aqqqqqqqqq", f"Klick an den Anfang + Tippen fügt vorne ein: {picker()['query']}")
    key("escape")
    check(not picker()["open"], "Escape schließt")


def step_command_palette():
    print("--- Ctrl+Shift+P: Kommando ausführen")
    key("p", ctrl=True, shift=True); settle()
    st = picker()
    check(st["open"] and st["mode"] == "commands" and st["items"] > 30, f"Palette listet {st['items']} Kommandos")
    rpc("type_text", ["toggle expl"]); settle(10)
    check(picker()["selected_label"] == "Toggle Explorer", f"'toggle expl' → {picker()['selected_label']!r}")
    shot("e2e_picker_commands.ppm")
    key("enter"); settle()
    check(not ui_state()["show_file_explorer"], "Enter führt Toggle Explorer aus (Explorer weg)")
    key("p", ctrl=True, shift=True); settle()
    rpc("type_text", ["toggle expl"]); settle(10)
    key("down"); key("up")
    key("enter"); settle()
    check(ui_state()["show_file_explorer"], "erneut: Explorer wieder da")
    key("p", ctrl=True, shift=True); settle()
    rpc("type_text", ["keyboard"]); settle(10)
    click_center("pk_row", 0); settle()
    check(ui_state()["shortcuts_open"], "Klick auf die Zeile führt 'Keyboard Shortcuts' aus")
    key("escape")


def step_long_paths():
    """Der Dateiname muss sichtbar bleiben. Vorher stand der ganze Pfad von links
    in der Zeile und wurde rechts abgeschnitten, womit alle Zeilen gleich aussahen."""
    print("--- Lange Pfade: Name zuerst, Ordner gekuerzt")
    key("p", ctrl=True); settle()
    t0 = time.time()
    while time.time() - t0 < 20 and picker()["scanning"]:
        time.sleep(0.1)
    rpc("type_text", ["gradleproperties"]); settle(10)
    t0 = time.time()
    while time.time() - t0 < 5 and picker()["query"] != "gradleproperties":
        time.sleep(0.05)
    settle(10)

    st = picker()
    label = st["selected_label"]
    check(st["matches"] >= 1, f"Treffer fuer einen tief liegenden Pfad: {label!r}")
    check("/" in label, f"Treffer liegt in Unterordnern: {label!r}")

    # Der eigentliche Fehler war die Geometrie, nicht der Text: Text ohne Umbruch
    # meldet seine volle Breite als Mindestmass und zog Zeile und Liste ueber den
    # Kasten hinaus (gemessen 1236 statt 720).
    box = bounds("pk_box")
    for i in range(3):
        row = result_json("element_bounds_i", ["pk_row", i])
        if not row["found"]:
            continue
        check(row["w"] <= box["w"], f"Zeile {i} bleibt im Kasten ({row['w']:.0f} <= {box['w']:.0f})")
        check(
            row["x"] + row["w"] <= box["x"] + box["w"] + 0.5,
            f"Zeile {i} endet nicht rechts vom Kasten",
        )

    shown = st["selected_dir_shown"]
    name = label.rsplit("/", 1)[-1]
    directory = label.rsplit("/", 1)[0]
    check(shown != "", "Ordner wird angezeigt")
    check(len(shown) <= len(directory), "gezeigter Ordner ist nicht laenger als der echte")
    if len(directory) > len(shown):
        check("…" in shown, f"gekuerzt mit Auslassungszeichen: {shown!r}")
        check(shown.startswith(directory[:4]), "Anfang des Pfades bleibt stehen")
        check(shown.endswith(directory[-4:]), "Ende des Pfades bleibt stehen")
    # Name plus gezeigter Ordner muessen in eine Zeile passen.
    check(len(name) + len(shown) < 90, f"Zeile bleibt im Rahmen ({len(name) + len(shown)} Zeichen)")
    shot("e2e_picker_long_paths.ppm")
    key("escape")
    check(not picker()["open"], "Escape schliesst")


STEPS = [step_quick_open, step_command_palette, step_long_paths]


def main():
    log = open(os.path.join(ROOT, "tmp", "e2e_picker.log"), "w")
    proc = subprocess.Popen(
        [os.path.join(ROOT, "zig-out", "bin", "zid"), "--headless", "--ai=off"],
        cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
        env=dict(os.environ, XDG_DATA_HOME=os.path.join(ROOT, "tmp", "xdg"), XDG_CONFIG_HOME=os.path.join(ROOT, "tmp", "xdg-config")),
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
