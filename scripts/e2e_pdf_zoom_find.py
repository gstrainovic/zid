#!/usr/bin/env python3
"""Headless-E2E: Zoom und Suche in der PDF-Vorschau.

Deckt ab: Zoom-Knöpfe und Ctrl+Plus/Minus/0, scharfes Neu-Rendern im neuen Maßstab,
Mausrad scrollt in der vergrößerten Seite statt zu blättern, Suche mit Ctrl+F (Sprung
zur Trefferseite, Enter/Shift+Enter, Markierung im Bild, Escape).

Aufruf: python3 scripts/e2e_pdf_zoom_find.py
"""
import os
import shutil
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e2e_fixtures import write_pdf  # noqa: E402
from e2e_open_folder import ROOT, rpc, result_json, wait_port, settle, bounds, click_center, check, shot, start_zid  # noqa: E402
from e2e_pdf_pager import wait_port_free  # noqa: E402

PDF = os.path.join(ROOT, "tmp", "e2e_pdf", "zoom_find.pdf")


def state():
    return result_json("pdf_state")


def wait_for(pred, msg, timeout=5):
    """Zustand wechselt erst in einem der nächsten Frames: nachfassen."""
    t0 = time.time()
    st = state()
    while not pred(st) and time.time() - t0 < timeout:
        settle(6)
        st = state()
    check(pred(st), f"{msg} ({ {k: st[k] for k in ('page', 'zoom', 'scale', 'scroll_y', 'hits', 'current', 'searching')} })")
    return st


def key(name, ctrl=False):
    rpc("key_press", [name, ctrl])
    settle(8)


def orange_pixels(name):
    """Pixel in der Farbe des aktuellen Treffers (Orange über Weiß) im Screenshot."""
    with open(os.path.join(ROOT, "tmp", name), "rb") as f:
        data = f.read()
    fields, pos = [], 2
    while len(fields) < 3:
        while data[pos:pos + 1].isspace():
            pos += 1
        start = pos
        while not data[pos:pos + 1].isspace():
            pos += 1
        fields.append(int(data[start:pos]))
    pos += 1
    px = data[pos:]
    n = 0
    for i in range(0, len(px) - 2, 3):
        r, g, b = px[i], px[i + 1], px[i + 2]
        if r > 230 and 150 < g < 215 and b < 140:
            n += 1
    return n


def step_zoom():
    st = wait_for(lambda s: s["scale"] > 0, "Seite gerendert")
    scale1 = st["scale"]

    click_center("pdf_zoom_in")
    st = wait_for(lambda s: abs(s["zoom"] - 1.25) < 0.01, "Knopf + zoomt auf 125 %")
    st = wait_for(lambda s: abs(s["scale"] - scale1 * 1.25) < scale1 * 0.05, "Seite wird im neuen Maßstab gerendert")

    click_center("pdf_zoom_out")
    wait_for(lambda s: abs(s["zoom"] - 1.0) < 0.01, "Knopf − zoomt zurück auf 100 %")

    key("equals", True)
    key("equals", True)
    wait_for(lambda s: abs(s["zoom"] - 1.5) < 0.01, "Ctrl+= zweimal: 150 %")
    key("minus", True)
    wait_for(lambda s: abs(s["zoom"] - 1.25) < 0.01, "Ctrl+- : 125 %")
    key("0", True)
    wait_for(lambda s: abs(s["zoom"] - 1.0) < 0.01, "Ctrl+0 setzt auf 100 %")

    # Vergrößert ragt die Seite über das Fenster: das Rad scrollt darin, blättert nicht
    for _ in range(3):
        click_center("pdf_zoom_in")
    wait_for(lambda s: abs(s["zoom"] - 2.0) < 0.01, "auf 200 % vergrößert")
    vp = bounds("pdf_viewport")
    cx, cy = vp["x"] + vp["w"] / 2, vp["y"] + vp["h"] / 2
    page0 = state()["page"]
    rpc("scroll", [cx, cy, -1])
    st = wait_for(lambda s: s["scroll_y"] > 0, "Mausrad scrollt in der vergrößerten Seite")
    check(st["page"] == page0, "und blättert dabei nicht")
    # Bis zum Seitenende und darüber hinaus: dann die nächste Seite, oben. Jede Stufe
    # abwarten, sonst trifft eine gepufferte Stufe schon die neue Seite.
    for _ in range(60):
        before = state()
        rpc("scroll", [cx, cy, -1])
        st = wait_for(lambda s: s["scroll_y"] != before["scroll_y"] or s["page"] != before["page"], "Radstufe angekommen")
        if st["page"] != page0:
            break
    st = wait_for(lambda s: s["page"] == page0 + 1, "am Seitenende blättert das Rad weiter")
    check(st["scroll_y"] == 0, "die neue Seite beginnt oben")
    rpc("scroll", [cx, cy, 1])
    st = wait_for(lambda s: s["page"] == page0, "am Seitenanfang zurück")
    check(st["scroll_y"] > 0, f"und zwar ans Ende der vorigen Seite (scroll_y={st['scroll_y']})")
    key("0", True)
    wait_for(lambda s: abs(s["zoom"] - 1.0) < 0.01, "zurück auf 100 %")


def step_find():
    key("f", True)
    wait_for(lambda s: s["find_active"], "Ctrl+F öffnet die Suchleiste")
    rpc("type_text", ["Seite 5"])
    st = wait_for(lambda s: not s["searching"] and s["hits"] == 1, "„Seite 5“ hat einen Treffer")
    st = wait_for(lambda s: s["page"] == 4, "Sprung auf Seite 5")
    check(st["current"] == 0, "Treffer ist der aktuelle")

    settle(10)
    shot("e2e_pdf_find.ppm")
    n = orange_pixels("e2e_pdf_find.ppm")
    check(n > 200, f"aktueller Treffer ist im Bild markiert ({n} Pixel)")

    # Kürzerer Begriff: alle sieben Seiten, Treffer ab der Leseposition (Seite 5)
    for _ in range(2):
        key("backspace")
    st = wait_for(lambda s: not s["searching"] and s["hits"] == 7, "„Seite“ findet sieben Treffer")
    check(st["hit_page"] == 4, f"aktueller Treffer bleibt auf der Leseposition (Seite {st['hit_page'] + 1})")
    key("enter")
    wait_for(lambda s: s["current"] == 5 and s["page"] == 5, "Enter springt zum nächsten Treffer auf Seite 6")
    rpc("key_press_mods", ["enter", False, True])
    settle(8)
    wait_for(lambda s: s["current"] == 4 and s["page"] == 4, "Shift+Enter zurück auf Seite 5")
    key("enter")
    key("enter")
    key("enter")
    wait_for(lambda s: s["current"] == 0 and s["page"] == 0, "nach dem letzten Treffer wieder der erste")

    # Blättern bleibt bei offener Leiste möglich
    key("page_down")
    wait_for(lambda s: s["page"] == 1, "Bild ab blättert trotz Suchleiste")

    # Kein Treffer
    rpc("type_text", ["xyz"])
    wait_for(lambda s: not s["searching"] and s["hits"] == 0, "„Seitexyz“ findet nichts")

    key("escape")
    wait_for(lambda s: not s["find_active"] and s["hits"] == 0, "Escape schließt die Suche")
    settle(10)
    shot("e2e_pdf_find_closed.ppm")
    check(orange_pixels("e2e_pdf_find_closed.ppm") == 0, "ohne Suche keine Markierung")


def main():
    log = open(os.path.join(ROOT, "tmp", "e2e_pdf_zoom_find.log"), "w")
    cfg = os.path.join(ROOT, "tmp", "e2e_pdf_zoom_cfg")
    shutil.rmtree(cfg, ignore_errors=True)
    env = dict(os.environ, XDG_CONFIG_HOME=cfg)
    write_pdf(PDF, 7)
    wait_port_free()
    proc = start_zid(["--headless", "--ai=off", PDF], log, env=env)
    try:
        wait_port(proc)
        settle(20)
        wait_for(lambda s: s["pdf"], "PDF-Tab ist aktiv", timeout=30)
        step_zoom()
        step_find()
        try:
            rpc("shutdown")
        except Exception:
            pass
        code = proc.wait(timeout=30)
        check(code == 0, f"Prozess beendet sauber (Code {code})")
    finally:
        if proc.poll() is None:
            proc.kill()
        log.close()
    print("OK")


if __name__ == "__main__":
    main()
