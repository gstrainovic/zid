#!/usr/bin/env python3
"""Headless-E2E: Marp-Folienvorschau und Export nach PDF.

Deckt ab: Eintrag im Tab-Kontextmenü nur bei .md, Export schreibt ein PDF mit
einer Seite je Folie, das Ergebnis landet als PDF-Tab, eine Markdown-Datei ohne
`marp: true` meldet einen Fehlerdialog, und die Vorschau eines Decks zeigt
einzelne Folien mit Blättern per Taste und Schaltfläche.

Aufruf: python3 scripts/e2e_marp_pdf.py
"""
import os
import shutil
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e2e_open_folder import ROOT, rpc, result_json, wait_port, settle, bounds, click_center, check, shot  # noqa: E402
from e2e_shortcuts import ui_state  # noqa: E402

FX = os.path.join(ROOT, "tmp", "e2e_marp")
DECK = os.path.join(FX, "deck.md")
PLAIN = os.path.join(FX, "plain.md")
NOTE = os.path.join(FX, "note.txt")
DECK_PDF = os.path.join(FX, "deck.pdf")


def setup():
    shutil.rmtree(FX, ignore_errors=True)
    os.makedirs(FX)
    shutil.copy(os.path.join(ROOT, "test_data", "marp_test.md"), DECK)
    with open(PLAIN, "w") as f:
        f.write("# Gewoehnliches Markdown\n\nOhne Front-Matter.\n")
    with open(NOTE, "w") as f:
        f.write("kein markdown\n")
    time.sleep(0.3)


def open_tab_menu(name):
    """Rechtsklick auf den Tab mit diesem Dateinamen."""
    for i, t in enumerate(ui_state()["tabs"]):
        if t["path"].endswith(name):
            b = result_json("tab_bounds", [i])
            rpc("right_click", [b["x"] + b["w"] / 2, b["y"] + b["h"] / 2])
            settle(4)
            return
    raise AssertionError(f"Tab {name} fehlt")


def menu_entry_visible(command):
    """Ausgeblendete Eintraege haben keine Bounding-Box im Layout."""
    return result_json("element_bounds", ["tab_menu_" + command])["found"]


def pdf_pages(path):
    """Seitenzahl aus dem PDF. mutool wenn vorhanden, sonst /Type/Page zaehlen."""
    if shutil.which("mutool"):
        out = subprocess.run(["mutool", "info", path], capture_output=True, text=True).stdout
        for line in out.splitlines():
            if line.startswith("Pages:"):
                return int(line.split(":")[1])
    data = open(path, "rb").read()
    return data.count(b"/Type/Page") - data.count(b"/Type/Pages")


def step_menu_entry():
    print("--- Menueintrag nur bei Markdown")
    rpc("open_file", [NOTE])
    settle(20)
    open_tab_menu("note.txt")
    check(not menu_entry_visible("md_export_pdf"), "note.txt: kein Export-Eintrag")
    rpc("key_press", ["escape", False])
    settle(4)

    rpc("open_file", [DECK])
    settle(20)
    open_tab_menu("deck.md")
    check(menu_entry_visible("md_export_pdf"), "deck.md: Export-Eintrag sichtbar")


def step_export():
    print("--- Export ueber das Tab-Menue")
    check(not os.path.exists(DECK_PDF), "vor dem Export gibt es kein PDF")
    click_center("tab_menu_md_export_pdf")
    settle(40)

    t0 = time.time()
    while time.time() - t0 < 20 and not os.path.exists(DECK_PDF):
        time.sleep(0.1)
    check(os.path.exists(DECK_PDF), "deck.pdf wurde geschrieben")
    check(open(DECK_PDF, "rb").read(5) == b"%PDF-", "Datei ist ein PDF")
    pages = pdf_pages(DECK_PDF)
    check(pages == 7, f"eine Seite je Folie: {pages} von 7")


def step_pdf_tab():
    print("--- Ergebnis als Tab")
    t0 = time.time()
    while time.time() - t0 < 20:
        tabs = ui_state()["tabs"]
        if any(t["path"].endswith("deck.pdf") for t in tabs):
            break
        time.sleep(0.1)
    tabs = ui_state()["tabs"]
    check(any(t["path"].endswith("deck.pdf") for t in tabs), "PDF ist als Tab offen")


def step_not_a_deck():
    print("--- Markdown ohne marp: true")
    rpc("open_file", [PLAIN])
    settle(20)
    open_tab_menu("plain.md")
    check(menu_entry_visible("md_export_pdf"), "plain.md: Eintrag sichtbar (ist ja .md)")
    click_center("tab_menu_md_export_pdf")
    settle(30)
    check(not os.path.exists(os.path.join(FX, "plain.pdf")), "kein PDF fuer ein Nicht-Deck")
    title = ui_state()["dialog"]
    check(title is not None, f"Fehlerdialog erscheint: {title!r}")
    rpc("key_press", ["escape", False]); settle(10)
    check(ui_state()["dialog"] is None, "Escape schliesst den Dialog")


def slide_state():
    return result_json("slide_state")


def step_slide_preview():
    print("--- Folienvorschau")
    open_tab_menu("deck.md")
    click_center("tab_menu_md_preview")
    settle(30)

    st = slide_state()
    check(st["deck"], "Vorschau erkennt das Deck")
    check(st["slides"] == 7, f"sieben Folien: {st['slides']}")
    check(st["current"] == 0, "startet auf Folie 1")

    rpc("key_press", ["right", False]); settle(10)
    check(slide_state()["current"] == 1, "Pfeil rechts blaettert vor")
    rpc("key_press", ["page_down", False]); settle(10)
    check(slide_state()["current"] == 2, "Bild ab blaettert vor")
    rpc("key_press", ["left", False]); settle(10)
    check(slide_state()["current"] == 1, "Pfeil links blaettert zurueck")
    rpc("key_press", ["end", False]); settle(10)
    check(slide_state()["current"] == 6, "Ende springt auf die letzte Folie")
    rpc("key_press", ["home", False]); settle(10)
    check(slide_state()["current"] == 0, "Pos1 springt auf die erste")

    b = bounds("md_slide")
    aspect = b["w"] / b["h"]
    check(abs(aspect - 16 / 9) < 0.05, f"Rahmen ist 16:9 ({aspect:.3f})")
    # Der Rahmen muss die Flaeche ausnutzen. Mit Clays aspect_ratio blieb er auf
    # Inhaltsgroesse stehen und war im Fenster winzig.
    root = bounds("markdown_view_root")
    fill = b["w"] / root["w"]
    check(fill > 0.6, f"Rahmen fuellt die Breite ({fill:.2f} von 1.0)")
    check(b["h"] <= root["h"], "Rahmen bleibt in der Hoehe")
    # Die Blaetterleiste muss unter dem Rahmen Platz haben, sonst ist sie
    # abgeschnitten wie beim ersten Versuch mit fester Reserve.
    bar = bounds("md_slide_bar")
    check(
        bar["y"] + bar["h"] <= root["y"] + root["h"] + 0.5,
        f"Blaetterleiste bleibt im Bild ({bar['y'] + bar['h']:.0f} von {root['y'] + root['h']:.0f})",
    )
    # Gegen Rueckkopplung: die Groesse muss ueber Frames konstant bleiben.
    first = bounds("md_slide")["w"]
    for _ in range(6):
        settle(1)
        check(abs(bounds("md_slide")["w"] - first) < 0.5, "Rahmengroesse bleibt stabil")
    st = slide_state()
    expect = max(6, round(26 * st["scale"]))  # 6 px ist die Untergrenze im Renderer
    check(st["font_size"] == expect, f"Schrift folgt dem Massstab: {st['font_size']} == {expect}")
    check(st["scale"] < 1.0, f"Folie ist verkleinert dargestellt ({st['scale']:.3f})")

    click_center("md_slide_next"); settle(10)
    check(slide_state()["current"] == 1, "Schaltflaeche vor")
    click_center("md_slide_prev"); settle(10)
    check(slide_state()["current"] == 0, "Schaltflaeche zurueck")
    check(bounds("md_slide_counter")["found"], "Zaehler ist im Layout")
    shot("e2e_marp_slide.ppm")


def step_wide_pane():
    """Ohne Explorer ist die Flaeche breit, die Hoehe begrenzt den Rahmen. Genau
    dort blaehte der Rahmen das Wurzelelement auf und der Zoom schwankte."""
    print("--- Breites Pane: Hoehe begrenzt den Rahmen")
    rpc("key_press", ["b", True]); settle(20)
    root = bounds("markdown_view_root")
    b = bounds("md_slide")
    bar = bounds("md_slide_bar")
    check(b["h"] < root["h"], f"Rahmen bleibt unter der Hoehe ({b['h']:.0f} < {root['h']:.0f})")
    check(
        bar["y"] + bar["h"] <= root["y"] + root["h"] + 0.5,
        f"Blaetterleiste bleibt im Bild ({bar['y'] + bar['h']:.0f} von {root['y'] + root['h']:.0f})",
    )
    first = b["w"]
    for _ in range(8):
        settle(1)
        w = bounds("md_slide")["w"]
        check(abs(w - first) < 0.5, f"kein Zoom-Flackern ({w:.1f} vs {first:.1f})")
    shot("e2e_marp_slide_wide.ppm")
    rpc("key_press", ["b", True]); settle(20)


def step_overflow_warning():
    print("--- Warnung, wenn der Inhalt nicht auf die Folie passt")
    rpc("key_press", ["home", False]); settle(10)
    check(not slide_state()["overflow"], "Titelfolie passt")
    # Folie 4 traegt den Codeblock, der schon im PDF abgeschnitten wird.
    for _ in range(3):
        rpc("key_press", ["right", False])
    settle(20)
    st = slide_state()
    check(st["current"] == 3, "auf der Code-Folie")
    check(st["overflow"], "Ueberlauf wird gemeldet")
    check(bounds("md_slide_overflow")["found"], "Warnung steht im Layout")


def step_preview_without_deck():
    print("--- Vorschau einer gewoehnlichen Markdown-Datei")
    open_tab_menu("plain.md")
    click_center("tab_menu_md_preview")
    settle(30)
    check(not slide_state()["deck"], "kein Deck: keine Folienvorschau")


STEPS = [
    step_menu_entry,
    step_export,
    step_pdf_tab,
    step_not_a_deck,
    step_slide_preview,
    step_wide_pane,
    step_overflow_warning,
    step_preview_without_deck,
]


def main():
    setup()
    log = open(os.path.join(ROOT, "tmp", "e2e_marp_pdf.log"), "w")
    proc = subprocess.Popen(
        [os.path.join(ROOT, "zig-out", "bin", "zid"), "--headless", "--ai=off"],
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
