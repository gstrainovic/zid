#!/usr/bin/env python3
"""Headless-E2E: ein offenes PDF lädt neu, wenn sich die Datei ändert.

1. Sieben Seiten öffnen, auf Seite 5 blättern.
2. Datei mit drei Seiten überschreiben → drei Seiten, Seite auf 3 geklemmt.
3. Halb geschriebene Datei → alter Stand bleibt, kein Absturz.
4. Langsamer Schreiber in place (Teil, Pause, Rest) → der fertige Stand wird geladen.
Aufruf: python3 scripts/e2e_pdf_reload.py
"""
import os, shutil, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e2e_fixtures import write_pdf  # noqa: E402
from e2e_open_folder import ROOT, rpc, result_json, wait_port, settle, check, start_zid, stop_zid  # noqa: E402

PDF = os.path.join(ROOT, "tmp", "e2e_pdf_reload", "doc.pdf")


def state():
    return result_json("pdf_state")


def wait_state(pred, what, timeout=10):
    t0 = time.time()
    st = state()
    while not pred(st) and time.time() - t0 < timeout:
        settle(6)
        st = state()
    check(pred(st), f"{what} (Seiten {st['pages']}, Seite {st['page'] + 1}, {time.time() - t0:.1f}s)")
    return st


def reloads():
    """Anzahl erfolgreicher Reloads laut zid-Log."""
    with open(os.path.join(ROOT, "tmp", "e2e_pdf_reload.log"), encoding="utf-8", errors="replace") as f:
        return f.read().count("PDF reloaded:")


def replace_atomic(pages):
    """Wie ein Exporter: in eine Nachbardatei schreiben, dann umbenennen."""
    tmp = PDF + ".part"
    write_pdf(tmp, pages)
    os.replace(tmp, PDF)


def main():
    shutil.rmtree(os.path.dirname(PDF), ignore_errors=True)
    write_pdf(PDF, 7)
    cfg = os.path.join(ROOT, "tmp", "e2e_pdf_reload_cfg")
    shutil.rmtree(cfg, ignore_errors=True)
    log = open(os.path.join(ROOT, "tmp", "e2e_pdf_reload.log"), "w")
    proc = start_zid(["--headless", "--ai=off", PDF], log, env=dict(os.environ, XDG_CONFIG_HOME=cfg))
    try:
        wait_port(proc); settle(20)
        wait_state(lambda s: s["pdf"] and s["pages"] == 7, "PDF mit 7 Seiten ist offen", 30)
        for _ in range(4):
            rpc("key_press", ["page_down", False]); settle(10)
        wait_state(lambda s: s["page"] == 4, "auf Seite 5 geblättert")

        print("--- Datei mit 3 Seiten überschrieben")
        replace_atomic(3)
        wait_state(lambda s: s["pages"] == 3 and s["page"] == 2, "neu geladen, Seite auf 3 geklemmt")

        print("--- Halb geschriebene Datei")
        data = open(PDF, "rb").read()
        write_pdf(PDF + ".full", 5)
        full = open(PDF + ".full", "rb").read()
        with open(PDF, "wb") as f:
            f.write(full[: len(full) // 2])
        settle(40)
        check(proc.poll() is None, "zid läuft nach halb geschriebener Datei weiter")
        st = state()
        check(st["pdf"] and st["pages"] in (3, 5), f"Vorschau bleibt benutzbar (Seiten {st['pages']})")

        print("--- Langsamer Schreiber in place: 40 %, 40 ms Pause, Rest (6 Seiten)")
        write_pdf(PDF + ".six", 6)
        six = open(PDF + ".six", "rb").read()
        with open(PDF, "wb") as f:
            f.write(six[: len(six) * 2 // 5]); f.flush(); os.fsync(f.fileno())
            time.sleep(0.04)  # länger als ein Frame, kürzer als das 100-ms-Fenster des Watchers
            f.write(six[len(six) * 2 // 5:])
        wait_state(lambda s: s["pages"] == 6 and s["page"] == 2, "fertig geschriebener Stand ist geladen: 6 Seiten, Seite 3", 5)
        del data
        print("ALL PASSED")
    finally:
        if proc.poll() is None:
            stop_zid(proc)
        log.close()


if __name__ == "__main__":
    main()
