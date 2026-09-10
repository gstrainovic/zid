#!/usr/bin/env python3
"""Headless-E2E: Blättern in der PDF-Vorschau.

Deckt ab: Tasten (Bild ab/auf, Pfeile), Mausrad über der Seite, die Schaltflächen
der Leiste und die Sperren an erster und letzter Seite.

Aufruf: python3 scripts/e2e_pdf_pager.py
"""
import os
import shutil
import signal
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e2e_open_folder import ROOT, rpc, result_json, wait_port, settle, bounds, click_center, check, shot  # noqa: E402

PDF = os.path.join(ROOT, "test_data", "marp_test.pdf")


def page():
    return result_json("pdf_state")


def wait_bounds(elem_id, timeout=5):
    """element_bounds spiegelt das zuletzt gebaute Layout; kurz nachfassen."""
    t0 = time.time()
    while time.time() - t0 < timeout:
        b = result_json("element_bounds", [elem_id])
        if b["found"]:
            return b
        settle(6)
    raise AssertionError(f"Element {elem_id!r} nicht im Layout")


def key(name):
    rpc("key_press", [name, False])
    settle(10)


def pixel(name, x, y):
    """Farbe eines Pixels aus einem PPM (P6, 8 Bit) ohne Fremdbibliothek."""
    with open(os.path.join(ROOT, "tmp", name), "rb") as f:
        data = f.read()
    fields, pos = [], 2
    while len(fields) < 3:
        while data[pos:pos + 1].isspace():
            pos += 1
        if data[pos:pos + 1] == b"#":
            while data[pos:pos + 1] not in (b"\n", b""):
                pos += 1
            continue
        start = pos
        while not data[pos:pos + 1].isspace():
            pos += 1
        fields.append(int(data[start:pos]))
    w, _h, _max = fields
    pos += 1
    off = pos + (int(y) * w + int(x)) * 3
    return tuple(data[off:off + 3])


def expect_page(n, msg, timeout=5):
    """Der Seitenwechsel wird erst im nächsten Frame gerendert: kurz nachfassen."""
    t0 = time.time()
    cur = page()["page"]
    while cur != n and time.time() - t0 < timeout:
        settle(6)
        cur = page()["page"]
    check(cur == n, f"{msg} (ist Seite {cur + 1})")


def to_first_page():
    """Auf Seite 1 zurück, eine Taste nach der anderen. Blind viele Tasten zu
    schicken hinterlässt Nachzügler in der Warteschlange, die später blättern."""
    while page()["page"] > 0:
        before = page()["page"]
        key("page_up")
        expect_page(before - 1, "zurück zum Anfang")


def wait_port_free(timeout=15):
    """Der Vorgänger gibt Port 9999 erst beim Beenden frei; sonst scheitert der
    Start mit AddressInUse."""
    import socket as _s
    t0 = time.time()
    while time.time() - t0 < timeout:
        try:
            with _s.create_connection(("127.0.0.1", 9999), timeout=0.5):
                pass
        except OSError:
            return
        time.sleep(0.5)
    raise RuntimeError("Port 9999 bleibt belegt — läuft noch eine zid-Instanz?")


def main():
    log = open(os.path.join(ROOT, "tmp", "e2e_pdf_pager.log"), "w")
    # Eigener, frischer Sitzungszustand pro Lauf: sonst stellt der Start die Tabs
    # des Benutzers oder des letzten Laufs wieder her, der aktive Tab wechselt
    # und der Test misst Fremdzustand.
    cfg = os.path.join(ROOT, "tmp", "e2e_pdf_cfg")
    shutil.rmtree(cfg, ignore_errors=True)
    env = dict(os.environ, XDG_CONFIG_HOME=cfg)
    wait_port_free()
    proc = subprocess.Popen(
        ["zig", "build", "run", "--", "--headless", "--ai=off", PDF],
        cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, env=env,
        start_new_session=True,  # eigene Prozessgruppe, siehe finally
    )
    try:
        wait_port(proc)
        settle(20)

        t0 = time.time()
        st = page()
        while not st["pdf"] and time.time() - t0 < 30:
            settle(10)
            st = page()
        check(st["pdf"], f"PDF-Tab ist aktiv (nach {time.time() - t0:.1f}s)")
        check(st["pages"] >= 3, f"Dokument hat {st['pages']} Seiten")
        to_first_page()
        expect_page(0, "Bild auf hält am Anfang bei Seite 1")

        # Leiste ist da und zeigt beide Schaltflächen
        check(wait_bounds("pdf_next_page") is not None, "Schaltfläche Weiter sichtbar")
        check(wait_bounds("pdf_prev_page") is not None, "Schaltfläche Zurück sichtbar")

        # Tasten
        key("page_down")
        expect_page(1, "Bild ab blättert auf Seite 2")
        key("right")
        expect_page(2, "Pfeil rechts blättert auf Seite 3")
        key("page_up")
        expect_page(1, "Bild auf blättert zurück auf Seite 2")
        key("left")
        expect_page(0, "Pfeil links blättert zurück auf Seite 1")

        # Erste Seite: zurück ist gesperrt
        key("page_up")
        expect_page(0, "Auf Seite 1 bleibt Bild auf wirkungslos")

        # Hoch und Runter gehören der Navigation, nicht dem Blättern
        key("down")
        expect_page(0, "Pfeil runter blättert nicht")

        # Mausrad über der Seite: Mitte zwischen den Schaltflächen, weiter oben
        nb = wait_bounds("pdf_next_page")
        pb = wait_bounds("pdf_prev_page")
        # Zwischen den Schaltflächen, auf ihrer Höhe: sicher im PDF-Bereich.
        cx = (pb["x"] + pb["w"] + nb["x"]) / 2
        cy = pb["y"] + pb["h"] / 2
        rpc("scroll", [cx, cy, -1])
        settle(10)
        expect_page(1, "Mausrad nach unten blättert vorwärts")
        rpc("scroll", [cx, cy, 1])
        settle(10)
        expect_page(0, "Mausrad nach oben blättert zurück")

        # Schaltflächen
        click_center("pdf_next_page")
        settle(10)
        expect_page(1, "Klick auf Weiter blättert vorwärts")
        click_center("pdf_prev_page")
        settle(10)
        expect_page(0, "Klick auf Zurück blättert zurück")

        # Letzte Seite: weiter ist gesperrt
        total = page()["pages"]
        for _ in range(total + 2):
            key("page_down")
        check(page()["page"] == total - 1, f"Nach dem Ende bleibt Seite {total} stehen")

        # Hover: die überfahrene Schaltfläche hellt auf. Vorher zurück auf Seite 1,
        # sonst ist Weiter gesperrt und darf gar nicht aufhellen.
        to_first_page()
        nb = wait_bounds("pdf_next_page")
        top_x, top_y = nb["x"] + nb["w"] * 0.25, nb["y"] + nb["h"] * 0.25
        rpc("move_mouse", [10, 400])
        settle(15)
        shot("e2e_pdf_hover_off.ppm")
        rpc("move_mouse", [nb["x"] + nb["w"] / 2, nb["y"] + nb["h"] / 2])
        settle(15)
        shot("e2e_pdf_hover_on.ppm")
        off = pixel("e2e_pdf_hover_off.ppm", top_x, top_y)
        on = pixel("e2e_pdf_hover_on.ppm", top_x, top_y)
        check(on != off and all(a >= b for a, b in zip(on, off)),
              f"Schaltfläche hellt beim Überfahren auf ({off} -> {on})")

        # Screenshots am Ende: der Screenshot-RPC rendert selbst und stört sonst
        # die Frames, in denen ein Seitenwechsel verarbeitet wird.
        to_first_page()
        shot("e2e_pdf_page1.ppm")
        key("page_down")
        shot("e2e_pdf_page2.ppm")

        # Ctrl+Bild ab bleibt der Tabwechsel, blättert also nicht
        before = page()["page"]
        rpc("key_press", ["page_down", True])
        settle(10)
        after = page()
        check(not after["pdf"] or after["page"] == before, "Ctrl+Bild ab blättert nicht")

        try:
            rpc("shutdown")
        except Exception:
            pass
        code = proc.wait(timeout=30)
        check(code == 0, f"Prozess beendet sauber (Code {code})")
    finally:
        # `zig build run` startet zid als Kind: proc.kill() träfe nur zig, das
        # verwaiste zid bliebe auf Port 9999 und beantwortete später fremde RPCs.
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        log.close()
    print("OK")


if __name__ == "__main__":
    main()
