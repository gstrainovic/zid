#!/usr/bin/env python3
"""Headless-E2E für die Markdown-Vorschau grosser Dateien.

Deckt ab: die Vorschau legt nur die sichtbaren Bloecke als Clay-Elemente an
(Virtualisierung), Scrollen zeigt andere Bloecke, Tabellen passen in den Viewport
und bilden ein Raster, jede Beispieldatei aus libs/zigdown/test rendert ohne
Absturz, und Clay meldet waehrend der ganzen Sitzung keinen Fehler — weder
`duplicate_id` noch die gesprengte Elementgrenze, an der die Vorschau von
AGENTS.md im Fenster abbrach.

Aufruf: python3 scripts/e2e_md_preview.py
"""
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e2e_open_folder import (  # noqa: E402
    ROOT, rpc, result_json, wait_port, settle, check, shot, bounds, start_zid, stop_zid,
)
from e2e_pdf_pager import pixel  # noqa: E402
from e2e_shortcuts import ui_state  # noqa: E402

TARGET = "AGENTS.md"
LOG = os.path.join(ROOT, "tmp", "e2e_md_preview.log")


def open_preview(name):
    rpc("open_file", [os.path.join(ROOT, name)])
    settle(20)
    tabs = ui_state()["tabs"]
    idx = next(i for i, t in enumerate(tabs) if t["path"].endswith(name))
    b = result_json("tab_bounds", [idx])
    rpc("right_click", [b["x"] + b["w"] / 2, b["y"] + b["h"] / 2])
    settle(4)
    e = result_json("element_bounds", ["tab_menu_md_preview"])
    rpc("click", [e["x"] + e["w"] / 2, e["y"] + e["h"] / 2])
    settle(30)


def visible_blocks(limit=400):
    """Bloecke, die gerade eine Flaeche haben. element_bounds behaelt Daten
    verschwundener Elemente, deshalb zaehlt nur die Hoehe > 0 direkt nach dem
    ersten Aufbau als verlaesslich."""
    return [i for i in range(limit)
            if result_json("element_bounds_i", ["md_block", i])["found"]]


def step_virtualized():
    print("--- Vorschau legt nur den sichtbaren Ausschnitt an")
    open_preview(TARGET)
    hits = visible_blocks()
    check(len(hits) > 0, f"Bloecke im Layout: {len(hits)}")
    check(hits[0] == 0, "beginnt beim ersten Block")
    check(len(hits) < 60, f"nicht das ganze Dokument ({len(hits)} Bloecke)")
    top_last = hits[-1]
    shot("e2e_md_preview_top.ppm")

    for _ in range(30):
        rpc("scroll", [600, 400, -3])
    settle(30)
    after = visible_blocks()
    check(after[-1] > top_last, f"Scrollen erschliesst weitere Bloecke ({top_last} -> {after[-1]})")
    shot("e2e_md_preview_scrolled.ppm")

    # Rad-Schritt = 60 px, und der sichtbare Inhalt wandert um genau so viel. Vorher ersetzten
    # Messungen die Schaetzungen der Bloecke ueber der Oberkante und der Inhalt sprang mit.
    vp = bounds("md_viewport")
    limit = after[-1] + 60

    def block_ys():
        return {i: result_json("element_bounds_i", ["md_block", i])["y"] for i in visible_blocks(limit)}

    prev = block_ys()
    worst, samples = 0.0, 0
    for _ in range(12):
        rpc("scroll", [600, 400, -1]); settle(6)
        cur = block_ys()
        # element_bounds behaelt verschwundene Bloecke mit alter Lage: lebendig ist, was sich
        # bewegt hat und im Viewport steht
        live = [i for i in cur if i in prev and cur[i] != prev[i] and vp["y"] <= cur[i] <= vp["y"] + vp["h"]]
        for i in live:
            worst = max(worst, abs((prev[i] - cur[i]) - 60))
            samples += 1
        prev = cur
    check(samples > 0 and worst < 1.5, f"Rad-Schritt bewegt sichtbare Bloecke um 60 px ({samples} Proben, groesste Abweichung {worst:.1f} px)")


def step_table_fits():
    """Tabellen bleiben im Fenster: die Spaltenbreiten werden aus dem Inhalt berechnet
    und notfalls gestaucht. Vorher liefen breite Tabellen über den rechten Rand hinaus."""
    print("--- Tabelle bleibt innerhalb des Viewports")
    open_preview(os.path.join("libs", "zigdown", "test", "table.md"))
    view = result_json("element_bounds", ["md_viewport"])
    rows = [result_json("element_bounds_i", ["md_table_row", i]) for i in range(1, 4)]
    found = [r for r in rows if r["found"] and r["h"] > 0]
    check(len(found) >= 2, f"Tabellen im Layout: {len(found)}")
    for i, r in enumerate(found):
        right = r["x"] + r["w"]
        check(right <= view["x"] + view["w"] + 1, f"Tabelle {i} endet bei {right:.0f} im Viewport")
    shot("e2e_md_preview_table.ppm")


def fixture_tables(path):
    """(Spalten, Zeilen inkl. Kopf) je Tabelle, direkt aus dem Markdown gelesen."""
    tables, block = [], []
    with open(path, encoding="utf-8") as f:
        for line in list(f) + [""]:
            if line.lstrip().startswith("|"):
                block.append(line.strip())
                continue
            if len(block) >= 2:
                ncol = len(block[0].strip("|").split("|"))
                tables.append((ncol, len(block) - 1))  # ohne Trennzeile
            block = []
    return tables


def step_table_cells():
    """Das Raster selbst: Zellen einer Zeile auf gleicher Höhe, von links nach rechts,
    jede Zeile unter der vorigen (Kopf zuerst). Vorher standen alle Zellen untereinander."""
    print("--- Tabellenzellen bilden ein Raster")
    rel = os.path.join("libs", "zigdown", "test", "table.md")
    tables = fixture_tables(os.path.join(ROOT, rel))
    check(len(tables) == 3, f"Fixture hat {len(tables)} Tabellen")
    for t, (ncol, nrow) in enumerate(tables, start=1):
        cells = [[result_json("element_bounds_i", ["md_tcell", t * 100000 + r * ncol + c])
                  for c in range(ncol)] for r in range(nrow)]
        missing = sum(1 for row in cells for b in row if not (b["found"] and b["h"] > 0))
        check(missing == 0, f"Tabelle {t}: alle {ncol * nrow} Zellen im Layout ({missing} fehlen)")
        for r, row in enumerate(cells):
            check(all(abs(b["y"] - row[0]["y"]) <= 1 for b in row), f"Tabelle {t} Zeile {r}: gleiches y")
            check(all(row[c + 1]["x"] > row[c]["x"] for c in range(ncol - 1)),
                  f"Tabelle {t} Zeile {r}: x steigt")
            if r > 0:
                prev = cells[r - 1][0]
                check(row[0]["y"] >= prev["y"] + prev["h"] - 1, f"Tabelle {t} Zeile {r} unter Zeile {r - 1}")


EXAMPLES = os.path.join(ROOT, "libs", "zigdown", "test")


def differs(a, b, tol=12):
    return any(abs(x - y) > tol for x, y in zip(a, b))


def check_quote(name):
    """Zitat: linker Rand in Akzentfarbe, daneben Hintergrund, erst dann der Text."""
    q = bounds("md_quote", 1)
    y = q["y"] + q["h"] / 2
    edge, gap = pixel(name, q["x"] + 1, y), pixel(name, q["x"] + 10, y)
    check(differs(edge, gap), f"Zitat hat linken Rand ({edge} neben {gap})")


def check_list(name):
    """Liste: Aufzählungszeichen links vom Eintrag, mit sichtbarer Glyphe."""
    b, row = bounds("md_bullet", 1), bounds("md_li", 1)
    check(b["w"] > 0 and b["h"] > 0, "Aufzählungszeichen hat eine Fläche")
    check(abs(b["x"] - row["x"]) <= 1 and b["x"] + b["w"] < row["x"] + row["w"], "Aufzählungszeichen steht vorn")
    bg = pixel(name, row["x"] - 4, b["y"] + 1)
    ink = [pixel(name, b["x"] + dx, b["y"] + dy)
           for dx in range(int(b["w"])) for dy in range(int(b["h"]))]
    check(any(differs(p, bg, 40) for p in ink), "Aufzählungszeichen ist gezeichnet")


def check_code(name):
    """Codeblock: eigener Hintergrund gegenüber der Fläche daneben."""
    c = bounds("md_code", 1)
    inside, outside = pixel(name, c["x"] + 8, c["y"] + 8), pixel(name, c["x"] - 4, c["y"] + 8)
    check(differs(inside, outside, 4), f"Codeblock hat Hintergrund ({inside} gegen {outside})")


TARGETED = {"quote.md": check_quote, "list.md": check_list, "code.md": check_code}


def step_all_examples(proc):
    """Jede Beispieldatei aus zigdown in der Vorschau: rendert Blöcke, stürzt nicht ab.
    Neue Dateien im Ordner laufen automatisch mit. Clay-Fehler prüft step_no_clay_errors."""
    names = sorted(n for n in os.listdir(EXAMPLES) if n.endswith(".md"))
    print(f"--- {len(names)} Beispieldateien aus libs/zigdown/test")
    check(len(names) >= 14, f"Beispieldateien gefunden: {len(names)}")
    for n in names:
        open_preview(os.path.join("libs", "zigdown", "test", n))
        check(proc.poll() is None, f"{n}: zid läuft noch")
        first = result_json("element_bounds_i", ["md_block", 0])
        check(first["found"] and first["h"] > 0, f"{n}: erster Block im Layout")
        shot_name = f"e2e_md_example_{n[:-3]}.ppm"
        shot(shot_name)
        if n in TARGETED:
            TARGETED[n](shot_name)


SELECT_MD = os.path.join(ROOT, "tmp", "e2e_md_select.md")


def md_selection():
    return result_json("md_selection")


def step_selection():
    """Text markieren wie im Browser: Ziehen über Zeilen und Blöcke, Hervorhebung sichtbar,
    Kopiertext mit Leerzeile zwischen Absätzen, Escape hebt auf. Vorher kannte die Vorschau
    keine Auswahl, Ctrl+C ging ins Leere."""
    print("--- Textauswahl in der Vorschau")
    with open(SELECT_MD, "w", encoding="utf-8") as f:
        f.write("# Titel\n\nAlpha beta gamma.\n\nDelta epsilon.\n\n```zig\nconst a = 1;\nconst b = 2;\n```\n")
    time.sleep(0.3)
    open_preview(os.path.join("tmp", "e2e_md_select.md"))
    settle(10)
    st = md_selection()
    check(st["open"] and st["lines"] == 5, f"Vorschau kennt 5 Zeilen ({st})")
    check(st["text"] is None, "ohne Ziehen keine Auswahl")
    l1, l2 = bounds("md_line", 1), bounds("md_line", 2)
    check(l1["h"] > 0 and l2["y"] > l1["y"], "Zeilen 1 und 2 im Layout")

    # Über zwei Absätze ziehen, Ende rechts hinter dem Text: klemmt ans Zeilenende
    rpc("mouse_down", [l1["x"] + 1, l1["y"] + l1["h"] / 2]); settle(4)
    rpc("move_mouse", [l2["x"] + l2["w"] + 40, l2["y"] + l2["h"] / 2]); settle(4)
    rpc("mouse_up", [l2["x"] + l2["w"] + 40, l2["y"] + l2["h"] / 2]); settle(6)
    got = md_selection()["text"]
    check(got == "Alpha beta gamma.\n\nDelta epsilon.", f"Auswahl über zwei Absätze: {got!r}")
    sel = bounds("md_sel", 1)
    check(sel["w"] > 0 and abs(sel["y"] - l1["y"]) <= 2, "Hervorhebung liegt auf Zeile 1")
    shot("e2e_md_preview_selection.ppm")
    inside = pixel("e2e_md_preview_selection.ppm", sel["x"] + 2, sel["y"] + sel["h"] - 3)
    outside = pixel("e2e_md_preview_selection.ppm", l1["x"] - 6, sel["y"] + sel["h"] - 3)
    check(differs(inside, outside, 8), f"Hervorhebung ist gezeichnet ({inside} gegen {outside})")

    # Teil einer Zeile: Start in der Mitte, Ende am Zeilenende
    rpc("mouse_down", [l1["x"] + l1["w"] * 0.05, l1["y"] + l1["h"] / 2]); settle(4)
    rpc("mouse_up", [l1["x"] + 400, l1["y"] + l1["h"] / 2]); settle(6)
    got = md_selection()["text"]
    check(got and got.endswith("gamma.") and len(got) < len("Alpha beta gamma."), f"Teilauswahl endet am Zeilenende: {got!r}")

    # Codeblock: harte Zeilen bleiben Zeilen
    c1, c2 = bounds("md_line", 3), bounds("md_line", 4)
    rpc("mouse_down", [c1["x"] + 1, c1["y"] + c1["h"] / 2]); settle(4)
    rpc("mouse_up", [c2["x"] + c2["w"], c2["y"] + c2["h"] / 2]); settle(6)
    got = md_selection()["text"]
    check(got == "const a = 1;\nconst b = 2;", f"Codeblock-Auswahl: {got!r}")

    rpc("key_press", ["escape", False]); settle(4)
    check(md_selection()["text"] is None, "Escape hebt die Auswahl auf")

    # Klick ohne Ziehen: keine Auswahl, nichts im Menü zu kopieren
    rpc("click", [l1["x"] + 5, l1["y"] + l1["h"] / 2]); settle(4)
    check(md_selection()["text"] is None, "Einfacher Klick markiert nichts")


def step_wide_code():
    """Lange Codezeilen ragen über den Viewport, unten erscheint ein waagrechter Balken (Klick
    rechts davon blättert). Alt+Z (Word Wrap der Editoren) aendert daran nichts, wie in der
    VS-Code-Vorschau. Fliesstext bricht immer um."""
    print("--- Lange Codezeilen: waagrechter Bildlauf, Alt+Z ohne Wirkung")
    # Vorab: eingerueckter Text (Liste, Zitat, verschachtelt) bricht an der eingerueckten Breite
    # um und ragt nicht ueber den Viewport. Vorher brach er an der vollen Breite und wurde
    # rechts abgeschnitten (Business-Plan-Listen, 18.09.2026).
    rel_list = os.path.join("tmp", "e2e_md_list.md")
    with open(os.path.join(ROOT, rel_list), "w", encoding="utf-8") as f:
        f.write("# Listen\n\n" + "".join(f"- **Punkt {i}**: " + "immer weiter " * 30 + "geht.\n" for i in range(4))
                + "\n> " + "Zitat das lange " * 30 + "\n\n- aussen\n  - innen " + "verschachtelt " * 30 + "\n")
    open_preview(rel_list)
    vp = bounds("md_viewport")
    content = bounds("md_content")
    check(content["w"] <= vp["w"] + 1, f"Listen und Zitat passen in den Viewport ({content['w']:.0f} <= {vp['w']:.0f})")
    rel = os.path.join("tmp", "e2e_md_wide.md")
    with open(os.path.join(ROOT, rel), "w", encoding="utf-8") as f:
        f.write("# Breit\n\nEin Absatz, der " + "immer weiter " * 40 + "geht.\n\n```zig\n"
                "const sehr_lange_zeile = \"" + "x" * 400 + "\";\nconst kurz = 1;\n```\n\n"
                + "Noch ein Absatz, damit die Seite auch senkrecht scrollt.\n\n" * 40)
    open_preview(rel)
    vp = bounds("md_viewport")
    content = bounds("md_content")
    check(content["w"] > vp["w"] + 100, f"Inhalt breiter als der Viewport ({content['w']:.0f} > {vp['w']:.0f})")
    # Ueberschrift, Absatz, Codeblock (zigdown streut Break-Bloecke ein): der Absatz ist der
    # hoechste der ersten Bloecke, weil er auf Viewportbreite in viele Zeilen bricht
    para_h = max(bounds("md_block", i)["h"] for i in range(5))
    check(para_h > 120, f"Absatz bricht trotzdem um (Hoehe {para_h:.0f})")
    track = bounds("md_hscroll_track")
    check(track["y"] + track["h"] <= vp["y"] + vp["h"] + 1 and track["w"] < vp["w"] + 1, "waagrechter Balken unten im Viewport")
    thumb = bounds("md_hscroll_thumb")
    check(thumb["w"] < track["w"], f"Thumb kuerzer als der Track ({thumb['w']:.0f} < {track['w']:.0f})")
    # Cursorform: Pfeil ueber beiden Balken, I-Beam ueber dem Text (zweimal kaputt gewesen)
    rpc("move_mouse", [thumb["x"] + thumb["w"] / 2, thumb["y"] + thumb["h"] / 2]); settle(4)
    check(ui_state()["cursor"] == "arrow", f"Pfeil ueber dem waagrechten Thumb ({ui_state()['cursor']})")
    vtrack = bounds("md_scrollbar_track")
    rpc("move_mouse", [vtrack["x"] + vtrack["w"] / 2, vtrack["y"] + vtrack["h"] / 2]); settle(4)
    check(ui_state()["cursor"] == "arrow", f"Pfeil ueber dem senkrechten Balken ({ui_state()['cursor']})")
    rpc("move_mouse", [vp["x"] + vp["w"] / 2, vp["y"] + 60]); settle(4)
    check(ui_state()["cursor"] == "text", f"I-Beam ueber dem Text ({ui_state()['cursor']})")
    # Screenshot: Thumb heller als der Track daneben, Track dunkler als der Seitenhintergrund
    shot("e2e_md_preview_wide.ppm")
    ty = track["y"] + track["h"] / 2
    on_thumb = pixel("e2e_md_preview_wide.ppm", thumb["x"] + thumb["w"] / 2, ty)
    on_track = pixel("e2e_md_preview_wide.ppm", thumb["x"] + thumb["w"] + 40, ty)
    on_page = pixel("e2e_md_preview_wide.ppm", thumb["x"] + thumb["w"] + 40, ty - 40)
    check(differs(on_thumb, on_track), f"Thumb ist gezeichnet ({on_thumb} neben Track {on_track})")
    # Track (30,30,46) liegt nur wenige Stufen unter dem Seitenhintergrund (36,39,58): enge Toleranz
    check(differs(on_track, on_page, tol=4), f"Track ist gezeichnet ({on_track} gegen Seite {on_page})")
    x0 = bounds("md_content")["x"]
    rpc("click", [track["x"] + track["w"] - 3, track["y"] + track["h"] / 2]); settle(8)
    x1 = bounds("md_content")["x"]
    check(x1 < x0 - 100, f"Klick rechts vom Thumb blaettert nach rechts ({x0:.0f} -> {x1:.0f})")
    shot("e2e_md_preview_wide_scrolled.ppm")
    thumb2 = bounds("md_hscroll_thumb")
    check(thumb2["x"] > thumb["x"] + 100, f"Thumb ist nach rechts gewandert ({thumb['x']:.0f} -> {thumb2['x']:.0f})")
    check(differs(pixel("e2e_md_preview_wide_scrolled.ppm", thumb2["x"] + thumb2["w"] / 2, ty), on_track), "Thumb an neuer Stelle gezeichnet")
    # Alt+Z schaltet Word Wrap der Editoren, die Vorschau bleibt wie sie ist (VS Code: pre scrollt)
    rpc("key_press_alt", ["z", False, False, True]); settle(20)
    check("word_wrap on" in ui_state().get("toast", ""), f"Toast: {ui_state().get('toast')!r}")
    content = bounds("md_content")
    check(content["w"] > vp["w"] + 100, f"Codeblock bricht mit Word Wrap nicht um ({content['w']:.0f} > {vp['w']:.0f})")
    check(bounds("md_hscroll_track")["found"], "waagrechter Balken bleibt")
    rpc("key_press_alt", ["z", False, False, True]); settle(20)
    check("word_wrap off" in ui_state().get("toast", ""), "Alt+Z schaltet zurueck")


def step_no_clay_errors():
    print("--- Clay meldet keine Fehler")
    time.sleep(0.5)
    with open(LOG) as f:
        errors = [line.strip() for line in f if "Clay:" in line and "error" in line]
    for line in errors[:5]:
        print("   ", line)
    check(not errors, f"{len(errors)} Clay-Fehler im Log")


def main():
    log = open(LOG, "w")
    proc = start_zid(["--headless", "--ai=off"], log)
    try:
        wait_port(proc)
        settle(20)
        step_virtualized()
        step_table_fits()
        step_table_cells()
        step_all_examples(proc)
        step_selection()
        step_wide_code()
        step_no_clay_errors()
        print("ALL PASSED")
    finally:
        stop_zid(proc)
        log.close()


if __name__ == "__main__":
    main()
