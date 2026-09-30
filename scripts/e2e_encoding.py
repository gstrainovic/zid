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
  5. „Save with Encoding: UTF-8“ aus der Command Palette wandelt bewusst nach UTF-8
  6. Ersetzen im Projekt (Ctrl+Shift+H) schreibt den Ersatz in Windows-1252; nicht
     darstellbarer Ersatz lässt die Datei aus, mit Hinweis; die Trefferliste zeigt 1252-Zeilen
     dekodiert (kein ungültiges UTF-8 im Log)
  7. Agent-Werkzeuge (RPC agent_tool): read_file liefert UTF-8, replace_text/write_file
     schreiben 1252 zurück, neue Dateien UTF-8
Aufruf: python3 scripts/e2e_encoding.py
"""
import json, os, sys, time

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


def key(name, ctrl=False, shift=False, alt=False):
    rpc("key_press_alt", [name, ctrl, shift, alt])
    settle()


def write_cp1252(name, text):
    with open(os.path.join(FX, name), "wb") as f:
        f.write(text.encode("cp1252"))


def step_save_as_utf8():
    print("--- 5. Save with Encoding: UTF-8 (Command Palette)")
    key("z", ctrl=True); settle(4)  # Emoji aus Schritt 4 zurücknehmen
    wait(lambda: editor_text() == TEXT.replace("\r\n", "\n"), "Emoji zurückgenommen")
    key("p", ctrl=True, shift=True)
    rpc("type_text", ["save with enc"]); settle(10)
    label = result_json("picker_state")["selected_label"]
    check(label == "Save with Encoding: UTF-8", f"Palette findet den Befehl ({label!r})")
    key("enter"); settle(10)
    wait(lambda: disk(ASP) == TEXT.encode("utf-8"), "Datei jetzt UTF-8")
    check("UTF-8" in status() and "1252" not in status(), f"Statusleiste: {status()}")
    rpc("type_text", ["😀"]); settle(4)
    wait(lambda: "😀" in editor_text(), "Emoji eingetippt")
    check(rpc("save_file", [""]) == "ok", "als UTF-8 speichert auch das Emoji")


def step_project_replace():
    print("--- 6. Ersetzen im Projekt schreibt in der Kodierung der Datei")
    write_cp1252("ersetzen.asp", "qux Grösse\r\nzap\r\n")
    check(rpc("open_project", [FX]) == "ok", "Fixture als Projektordner"); settle(20)
    key("f", ctrl=True, shift=True)
    rpc("type_text", ["qux"])
    wait(lambda: result_json("search_state")["match_count"] == 1, "Treffer 'qux' in der 1252-Datei", timeout=10)
    key("h", ctrl=True, shift=True)
    replace_all("Übergrösse")
    path = os.path.join(FX, "ersetzen.asp")
    wait(lambda: disk(path) == "Übergrösse Grösse\r\nzap\r\n".encode("cp1252"), f"Ersatz in 1252 geschrieben: {disk(path)!r}")
    key("f", ctrl=True, shift=True); key("a", ctrl=True); rpc("type_text", ["zap"])
    wait(lambda: result_json("search_state")["match_count"] == 1, "Treffer 'zap'")
    key("h", ctrl=True, shift=True); key("a", ctrl=True)
    replace_all("😀")
    toast = result_json("ui_state")["toast"] or ""
    check(disk(path) == "Übergrösse Grösse\r\nzap\r\n".encode("cp1252"), "Emoji nicht darstellbar: Datei unverändert")
    check("Windows 1252" in toast, f"Hinweis nennt Windows 1252: {toast!r}")
    key("escape")


def replace_all(replacement):
    """Ersatztext ins fokussierte Ersetzen-Feld, Vorschau abwarten, alle ersetzen bestätigen."""
    rpc("type_text", [replacement]); settle(10)
    try:
        wait(lambda: any(r.get("replacement") == replacement for r in result_json("search_state")["rows"]), f"Vorschau zeigt {replacement!r}")
    except AssertionError:
        print("search_state:", result_json("search_state"))
        raise
    key("enter", ctrl=True, alt=True)
    check(result_json("ui_state")["dialog"] is not None, "Alle ersetzen fragt nach")
    key("enter"); settle(20)


def step_agent_tools():
    print("--- 7. Agent-Werkzeuge lesen und schreiben 1252")
    write_cp1252("agent.asp", "Grösse 5 €\r\n")
    path = os.path.join(FX, "agent.asp")
    text = rpc("agent_tool", ["read_file", json.dumps({"path": "agent.asp"})])
    check(text == "Grösse 5 €\r\n", f"read_file liefert UTF-8: {text!r}")
    res = rpc("agent_tool", ["replace_text", json.dumps({"path": "agent.asp", "old": "5 €", "new": "7 € – „neu“"})])
    check(disk(path) == "Grösse 7 € – „neu“\r\n".encode("cp1252"), f"replace_text schreibt 1252 ({res}): {disk(path)!r}")
    res = rpc("agent_tool", ["write_file", json.dumps({"path": "agent.asp", "content": "Übersicht\r\n"})])
    check(disk(path) == "Übersicht\r\n".encode("cp1252"), f"write_file behält 1252 ({res}): {disk(path)!r}")
    res = rpc("agent_tool", ["write_file", json.dumps({"path": "agent.asp", "content": "😀\r\n"})])
    check("Windows 1252" in res and disk(path) == "Übersicht\r\n".encode("cp1252"), f"Emoji abgelehnt, Datei unverändert ({res})")
    res = rpc("agent_tool", ["write_file", json.dumps({"path": "neu.txt", "content": "Grösse 😀\n"})])
    check(disk(os.path.join(FX, "neu.txt")) == "Grösse 😀\n".encode("utf-8"), f"neue Datei UTF-8 ({res})")


def main():
    setup_fixture()
    log = open(LOG, "w")
    proc = start_zid(["--headless", "--ai=off"], log)
    try:
        wait_port(proc)
        settle(10)
        for step in (step_display, step_save, step_unrepresentable, step_save_as_utf8, step_project_replace, step_agent_tools):
            step()
        log.flush()
        with open(LOG, encoding="utf-8", errors="replace") as f:
            bad = [l.strip() for l in f if "invalid UTF-8" in l]
        check(not bad, f"kein ungültiges UTF-8 an den Shaper, auch nicht in der Trefferliste ({bad[:1]})")
        print("ALL PASSED")
    finally:
        stop_zid(proc)
        log.close()


if __name__ == "__main__":
    main()
