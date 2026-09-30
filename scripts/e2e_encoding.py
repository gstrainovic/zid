#!/usr/bin/env python3
"""Headless-E2E: Dateien in Windows-1252 (ASP-Dateien unter Windows) im Editor.

Fixture tmp/e2e_encoding/: seite.asp in Windows-1252 (Umlaute, €, „“, –), utf8.txt in UTF-8.
Prüft:
  1. Anzeige als Windows-1252: Umlaute, €, typografische Zeichen richtig; Statusleiste
     „Windows 1252“ (UTF-8-Datei: „UTF-8“)
  2. Speichern schreibt wieder Windows-1252; nur das getippte Zeichen kommt dazu
  3. Der eigene Save gilt nicht als externe Änderung: Undo geht danach noch
  4. Ein Zeichen, das Windows-1252 nicht kennt (Emoji): Speichern scheitert mit Meldung,
     die Datei bleibt unverändert
Aufruf: python3 scripts/e2e_encoding.py
"""
import os, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e2e_open_folder import ROOT, rpc, result_json, wait_port, settle, check, rmtree, start_zid, stop_zid  # noqa: E402

FX = os.path.join(ROOT, "tmp", "e2e_encoding")
LOG = os.path.join(ROOT, "tmp", "e2e_encoding.log")
ASP = os.path.join(FX, "seite.asp")
UTF8 = os.path.join(FX, "utf8.txt")
TEXT = "<% ' Grösse prüfen %>\r\n<p>Übersicht – „neu“ 5 €</p>\r\n"


def disk(path):
    with open(path, "rb") as f:
        return f.read()


def editor_text():
    return result_json("editor_state")["text"]


def status():
    return result_json("ui_state")["status_text"]


def wait(cond, what, timeout=5):
    t0 = time.time()
    while time.time() - t0 < timeout:
        if cond():
            check(True, what)
            return
        time.sleep(0.05)
    check(False, what)


def setup_fixture():
    rmtree(FX)
    os.makedirs(FX)
    with open(ASP, "wb") as f:
        f.write(TEXT.encode("cp1252"))
    with open(UTF8, "wb") as f:
        f.write("Grösse\n".encode("utf-8"))


def step_display():
    print("--- 1. Anzeige und Statusleiste")
    rpc("open_file", [UTF8]); settle(10)
    wait(lambda: "UTF-8" in status(), f"UTF-8-Datei: Statusleiste UTF-8 ({status()})")
    rpc("open_file", [ASP]); settle(10)
    wait(lambda: editor_text() == TEXT.replace("\r\n", "\n"), "Windows-1252 richtig dekodiert")
    check("Windows 1252" in status(), f"Statusleiste: {status()}")


def step_save():
    print("--- 2./3. Speichern in Windows-1252, Undo danach")
    rpc("key_press", ["end", False]); settle(2)
    rpc("type_text", ["ä"]); settle(4)
    check(rpc("save_file", [""]) == "ok", "gespeichert")
    expected = TEXT.replace(" %>\r\n", " %>ä\r\n", 1).encode("cp1252")
    check(disk(ASP) == expected, f"Datei bleibt Windows-1252, nur „ä“ (E4) dazu: {disk(ASP)!r}")
    # Watcher meldet den eigenen Save; der darf den Buffer nicht neu laden
    time.sleep(1.0); settle(10)
    rpc("key_press", ["z", True]); settle(4)
    wait(lambda: editor_text() == TEXT.replace("\r\n", "\n"), "Undo nach dem Speichern geht noch")
    check("Windows 1252" in status(), "Kodierung bleibt nach dem Speichern")
    check(rpc("save_file", [""]) == "ok", "zurück gespeichert")
    check(disk(ASP) == TEXT.encode("cp1252"), "Datei wieder byte-gleich mit dem Original")


def step_unrepresentable():
    print("--- 4. Zeichen außerhalb von Windows-1252")
    before = disk(ASP)
    rpc("type_text", ["😀"]); settle(4)
    wait(lambda: "😀" in editor_text(), "Emoji eingetippt")
    res = rpc("save_file", [""])
    check("NotInWindows1252" in res, f"Speichern scheitert ({res})")
    check(disk(ASP) == before, "Datei unverändert")


def main():
    setup_fixture()
    log = open(LOG, "w")
    proc = start_zid(["--headless", "--ai=off"], log)
    try:
        wait_port(proc)
        settle(10)
        for step in (step_display, step_save, step_unrepresentable):
            step()
        print("ALL PASSED")
    finally:
        stop_zid(proc)
        log.close()


if __name__ == "__main__":
    main()
