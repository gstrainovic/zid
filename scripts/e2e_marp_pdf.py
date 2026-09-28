#!/usr/bin/env python3
"""Headless-E2E: Marp-Folienvorschau und Export nach PDF über marp-cli.

Deckt ab: Export-Eintrag im Tab-Kontextmenü nur bei Marp-Decks (Preview bei jeder
.md), Export über marp-cli (beim ersten Lauf von zid nach tmp/tools geladen)
schreibt ein PDF mit einer Seite je Folie, das Ergebnis landet als
PDF-Tab, eine Markdown-Datei ohne `marp: true` meldet über das View-Menü einen
Fehlerdialog, und die Vorschau eines Decks zeigt
einzelne Folien mit Blättern per Taste und Schaltfläche.

Aufruf: python3 scripts/e2e_marp_pdf.py
"""
import os
import shutil
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e2e_fixtures import MARP_DECK  # noqa: E402
from e2e_open_folder import ROOT, rpc, result_json, wait_port, settle, bounds, click_center, check, shot, start_zid, stop_zid, isolated_env  # noqa: E402
from e2e_shortcuts import ui_state  # noqa: E402

FX = os.path.join(ROOT, "tmp", "e2e_marp")
DECK = os.path.join(FX, "deck.md")
PLAIN = os.path.join(FX, "plain.md")
NOTE = os.path.join(FX, "note.txt")
DECK_PDF = os.path.join(FX, "deck.pdf")


def setup():
    shutil.rmtree(FX, ignore_errors=True)
    os.makedirs(FX)
    shutil.copy(MARP_DECK, DECK)
    shutil.copy(os.path.join(os.path.dirname(MARP_DECK), "marp_skizze.svg"), FX)
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
    """Eintrag liegt im aktuell gezeichneten Menuerahmen.

    Clay behaelt die Bounds jeder einmal gezeichneten ID ueber Frames hinweg, `found`
    allein sagt also nichts ueber den aktuellen Frame. Der Rahmen `tab_menu_container`
    wird bei jedem Oeffnen an der Klickposition neu gezeichnet; ein ausgeblendeter
    Eintrag behaelt die Bounds vom letzten Menue an einer anderen Stelle.
    """
    frame = bounds("tab_menu_container")
    entry = result_json("element_bounds", ["tab_menu_" + command])
    if not (frame["found"] and entry["found"]):
        return False
    inside_x = frame["x"] <= entry["x"] and entry["x"] + entry["w"] <= frame["x"] + frame["w"] + 0.5
    inside_y = frame["y"] <= entry["y"] and entry["y"] + entry["h"] <= frame["y"] + frame["h"] + 0.5
    return inside_x and inside_y


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


def wait_export(timeout=300):
    """Export laeuft im Hintergrund: beim ersten Lauf laedt zid marp-cli (49 MB)
    nach tmp/tools, danach dauert die Umwandlung einige Sekunden."""
    t0 = time.time()
    st = result_json("marp_export_state")
    while (st["state"] != "idle" or st["last"] == "idle") and time.time() - t0 < timeout:
        time.sleep(0.5)
        settle(2)
        st = result_json("marp_export_state")
    return st


def step_export():
    print("--- Export ueber das Tab-Menue (marp-cli)")
    check(not os.path.exists(DECK_PDF), "vor dem Export gibt es kein PDF")
    click_center("tab_menu_md_export_pdf")
    settle(4)
    st = wait_export()
    check(st["last"] == "done", f"Export abgeschlossen: {st}")
    check(os.path.exists(DECK_PDF), "deck.pdf wurde geschrieben")
    check(open(DECK_PDF, "rb").read(5) == b"%PDF-", "Datei ist ein PDF")
    tools = os.path.join(ROOT, "tmp", "tools")
    marp = [d for d in os.listdir(tools) if d.startswith("marp-cli-")]
    check(marp, f"marp-cli unter tmp/tools eingerichtet: {marp}")


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
    settle(20)
    pages = result_json("pdf_state")["pages"]
    check(pages == 7, f"eine Seite je Folie: {pages} von 7")


def step_pdf_background():
    """`![bg right:40%]` auf Folie 2: die SVG-Skizze steht im PDF samt Text aus
    einem `<symbol>` (marp-cli druckt das SVG als Vektor)."""
    print("--- Hintergrundbild im PDF")
    settle(20)
    rpc("key_press", ["f", True]); settle(8)
    rpc("type_text", ["Skizzenwort"])
    t0 = time.time()
    st = result_json("pdf_state")
    while (st["searching"] or st["hits"] == 0) and time.time() - t0 < 10:
        settle(6)
        st = result_json("pdf_state")
    check(st["hits"] == 1 and st["hit_page"] == 1, f"Text der Skizze auf Seite 2: {st}")
    rpc("key_press", ["escape", False]); settle(8)


def step_reexport_reloads_pdf():
    print("--- Erneuter Export: der offene PDF-Tab zeigt den neuen Stand")
    with open(DECK, "a") as f:
        f.write("\n---\n\n# Nachtrag\n\nNeue Folie.\n")
    settle(30)  # Watcher lädt deck.md im Editor neu
    # Über das View-Menü mit deck.md als aktivem Tab (der Tab-Streifen ist hier schon voll)
    rpc("open_file", [DECK]); settle(20)
    click_center("menu_view")
    click_center("menu_item_md_export_pdf")
    settle(4)
    st = wait_export()
    check(st["last"] == "done", f"zweiter Export abgeschlossen: {st}")
    t0 = time.time()
    st = result_json("pdf_state")
    while time.time() - t0 < 10 and not (st["pdf"] and st["pages"] == 8):
        settle(6)
        st = result_json("pdf_state")
    check(st["pdf"] and st["pages"] == 8, f"offener PDF-Tab zeigt 8 Seiten (ist {st['pages']})")


def step_not_a_deck():
    print("--- Markdown ohne marp: true")
    rpc("open_file", [PLAIN])
    settle(20)
    open_tab_menu("plain.md")
    check(menu_entry_visible("md_preview"), "plain.md: Preview-Eintrag sichtbar (ist ja .md)")
    check(not menu_entry_visible("md_export_pdf"), "plain.md: kein Export-Eintrag (kein marp: true)")
    rpc("key_press", ["escape", False]); settle(4)
    # Über das View-Menü geht der Export trotzdem, dann meldet er den Nicht-Deck als Dialog.
    click_center("menu_view")
    check(bounds("menu_item_md_export_pdf")["found"], "View-Menü zeigt Export to PDF")
    click_center("menu_item_md_export_pdf")
    settle(30)
    check(not os.path.exists(os.path.join(FX, "plain.pdf")), "kein PDF fuer ein Nicht-Deck")
    title = ui_state()["dialog"]
    check(title is not None, f"Fehlerdialog erscheint: {title!r}")
    rpc("key_press", ["escape", False]); settle(10)
    check(ui_state()["dialog"] is None, "Escape schliesst den Dialog")


def marp_preview_state():
    return result_json("marp_preview_state")


def active_tab_path():
    st = ui_state()
    return st["tabs"][st["active_tab"]]["path"]


def wait_for(pred, timeout, what):
    t0 = time.time()
    while time.time() - t0 < timeout:
        v = pred()
        if v:
            return v
        time.sleep(0.3)
        settle(2)
    check(False, f"{what} (nach {timeout} s)")


def step_deck_preview():
    """Vorschau eines Decks ist das PDF aus marp-cli im Watch-Modus: Tab mit dem
    Vorschau-PDF, Neuladen nach dem Speichern, Ende des Watch-Prozesses mit dem Tab."""
    print("--- Folienvorschau ueber marp-cli")
    rpc("open_file", [DECK]); settle(20)
    click_center("menu_view")
    click_center("menu_item_md_preview")
    settle(4)
    wait_for(lambda: marp_preview_state()["previews"], 120, "Vorschau laeuft")
    st = marp_preview_state()
    check(st["last"] == "done", f"erstes Rendern fertig: {st['last']} {st['message']!r}")
    p = st["previews"][0]
    check(p["md"].endswith("deck.md") and p["watching"], f"Watch-Prozess fuer deck.md: {p}")
    check(os.path.join("tmp", "tools", "preview") in p["pdf"], f"Vorschau-PDF liegt im Cache: {p['pdf']}")
    check(not os.path.exists(os.path.join(FX, "deck.preview.pdf")), "nichts neben dem Deck abgelegt")
    wait_for(lambda: active_tab_path() == p["pdf"], 20, "Vorschau-PDF ist der aktive Tab")
    wait_for(lambda: result_json("pdf_state")["pages"] == 8, 20, "Vorschau zeigt 8 Folien")

    # Speichern (hier: Datei schreiben) rendert neu, der Tab laedt nach.
    with open(DECK, "a") as f:
        f.write("\n---\n\n# Noch eine\n\nNach dem Speichern.\n")
    wait_for(lambda: result_json("pdf_state")["pages"] == 9, 30, "nach dem Speichern 9 Folien")

    # Zweiter Aufruf fuer dasselbe Deck: kein neuer Prozess, nur der Tab.
    rpc("open_file", [DECK]); settle(20)
    click_center("menu_view")
    click_center("menu_item_md_preview")
    settle(20)
    check(len(marp_preview_state()["previews"]) == 1, "eine Vorschau je Deck")
    check(active_tab_path() == p["pdf"], "zeigt wieder den Vorschau-Tab")

    rpc("key_press", ["w", True]); settle(10)
    check(active_tab_path() != p["pdf"], "Ctrl+W schliesst den Vorschau-Tab")
    wait_for(lambda: not marp_preview_state()["previews"], 15, "Tab zu: Watch-Prozess beendet")


def step_preview_without_deck():
    print("--- Vorschau einer gewoehnlichen Markdown-Datei")
    rpc("open_file", [PLAIN]); settle(20)
    click_center("menu_view")
    click_center("menu_item_md_preview")
    settle(30)
    check(active_tab_path().startswith("preview://"), f"eigene Markdown-Vorschau: {active_tab_path()}")
    check(not marp_preview_state()["previews"], "kein Deck: kein marp-cli")


STEPS = [
    step_menu_entry,
    step_export,
    step_pdf_tab,
    step_pdf_background,
    step_not_a_deck,
    step_reexport_reloads_pdf,  # haengt eine Folie an (8 Folien)
    step_deck_preview,          # haengt noch eine an (9 Folien)
    step_preview_without_deck,
]


def main():
    setup()
    log = open(os.path.join(ROOT, "tmp", "e2e_marp_pdf.log"), "w")
    # marp-cli (und falls kein Browser da ist chrome-headless-shell) bleibt unter
    # tmp/tools liegen: nur der erste Lauf laedt.
    env = dict(isolated_env("e2e_marp_pdf"), ZID_TOOLS_DIR=os.path.join(ROOT, "tmp", "tools"))
    proc = start_zid(["--headless", "--ai=off"], log, env)
    try:
        wait_port(proc)
        settle(20)
        for step in STEPS:
            step()
    finally:
        stop_zid(proc)
        log.close()
    print("ALL PASSED")


if __name__ == "__main__":
    main()
