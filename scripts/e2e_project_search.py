#!/usr/bin/env python3
"""Headless-E2E für die Suche im ganzen Projekt (Ctrl+Shift+F) wie VS Code: Panel in der
Seitenleiste, rg im Hintergrund, Treffer je Datei, Optionen Aa/ab/.*, Tastatur, Öffnen der
Stelle, Verwerfen, Ersetzen (einzeln, je Datei, alle) und ungespeicherte Buffer.
Aufruf: python3 scripts/e2e_project_search.py
"""
import os, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e2e_open_folder import ROOT, ZID, rpc, result_json, wait_port, settle, bounds, check, shot, rmtree, isolated_env  # noqa: E402

FX = os.path.join(ROOT, "tmp", "e2e_project_search")
LOG = os.path.join(ROOT, "tmp", "e2e_project_search.log")

# RowAction-Reihenfolge aus search_view.zig: IDI("ps_act", zeile * 4 + aktion)
ACT_REPLACE, ACT_DISMISS = range(2)


def write(name, text):
    path = os.path.join(FX, name)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(text)


def read(name):
    with open(os.path.join(FX, name), encoding="utf-8", newline="") as f:
        return f.read()


def setup_fixture():
    rmtree(FX)
    os.makedirs(FX)
    write("a.txt", "alpha foo\nbeta\n\tfoo foo gamma\n")
    write("src/b.zig", "const Foo = 1;\n// FOO\n")
    write(".gitignore", "ignored.txt\n")
    write("ignored.txt", "foo\n")
    write("äpfel.txt", "Äpfel und äpfel\n")


def key(name, ctrl=False, shift=False, alt=False):
    rpc("key_press_alt", [name, ctrl, shift, alt])
    settle()


def st():
    return result_json("search_state")


def wait(cond, what, timeout=10):
    t0 = time.time()
    s = st()
    while time.time() - t0 < timeout:
        s = st()
        if not s["searching"] and cond(s):
            check(True, what)
            return s
        time.sleep(0.05)
    print("letzter Zustand:", {k: (v[:8] if k == "rows" else v) for k, v in s.items()})
    check(False, what)


def files(s):
    return {r["path"]: r["count"] for r in s["rows"] if r["kind"] == "file"}


def clear_query():
    key("a", ctrl=True)
    key("backspace")


def row_index(s, kind, path=None, n=0):
    """Index der n-ten Zeile dieser Art (optional in Datei `path`)."""
    seen = 0
    for i, r in enumerate(s["rows"]):
        if r["kind"] == kind and (path is None or r["path"] == path):
            if seen == n:
                return i
            seen += 1
    raise AssertionError(f"keine {kind}-Zeile {n} für {path}")


def click_row(i):
    b = bounds("ps_row", i)
    rpc("click", [b["x"] + 40, b["y"] + b["h"] / 2])
    settle(10)


def row_action(i, action):
    b = bounds("ps_row", i)
    rpc("move_mouse", [b["x"] + b["w"] / 2, b["y"] + b["h"] / 2])
    settle(10)
    a = bounds("ps_act", i * 4 + action)
    rpc("click", [a["x"] + a["w"] / 2, a["y"] + a["h"] / 2])
    settle(10)


def step_open_and_search():
    print("--- Ctrl+Shift+F: Panel, Suche beim Tippen, .gitignore")
    key("f", ctrl=True, shift=True)
    s = st()
    check(s["visible"] and s["focus"] == "query", f"Panel sichtbar, Fokus im Suchfeld ({s['focus']})")
    rpc("type_text", ["foo"])
    s = wait(lambda s: s["match_count"] == 5, "5 Treffer für 'foo' (Groß/Klein egal)")
    check(files(s) == {"a.txt": 3, "src/b.zig": 2}, f"Treffer je Datei: {files(s)}")
    check(s["message"] == "5 results in 2 files", f"Meldung: {s['message']!r}")
    m = s["rows"][row_index(s, "match", "a.txt", 1)]
    check(m["row"] == 2 and m["match"] == "foo" and m["before"] == "", f"zweiter Treffer in a.txt: Zeile 3, Einrückung weg: {m}")
    shot("e2e_project_search.ppm")


def step_options():
    print("--- Aa / ab / .* über Alt+C/W/R")
    key("c", alt=True)
    s = wait(lambda s: s["match_count"] == 3, "Alt+C: Groß/Klein beachten → 3 Treffer")
    check(s["case_sensitive"], "Umschalter Aa an")
    key("c", alt=True)
    wait(lambda s: s["match_count"] == 5, "Alt+C aus → wieder 5")
    clear_query()
    rpc("type_text", ["f.o"])
    wait(lambda s: s["match_count"] == 0 and s["message"] == "No results found.", "'f.o' wörtlich: keine Treffer")
    key("r", alt=True)
    wait(lambda s: s["match_count"] == 5, "Alt+R: 'f.o' als Regex → 5 Treffer")
    clear_query()
    rpc("type_text", ["(("])
    wait(lambda s: s["error"] is not None and "regex" in s["error"].lower(), "ungültige Regex meldet den Fehler")
    key("r", alt=True)
    clear_query()
    rpc("type_text", ["äpfel"])
    wait(lambda s: s["match_count"] == 2, "Unicode: 'äpfel' findet auch 'Äpfel'")
    key("w", alt=True)
    clear_query()
    rpc("type_text", ["fo"])
    wait(lambda s: s["match_count"] == 0, "Alt+W: 'fo' als ganzes Wort → keine Treffer")
    key("w", alt=True)
    clear_query()
    rpc("type_text", ["foo"])
    wait(lambda s: s["match_count"] == 5, "wieder 'foo'")


def step_keyboard_and_open():
    print("--- Tastatur in der Liste, Enter öffnet die Stelle")
    key("down")
    s = st()
    check(s["focus"] == "list" and s["selected"] == 1, f"↓ springt in die Liste auf den ersten Treffer ({s['focus']}, {s['selected']})")
    key("down")
    key("enter"); settle(20)
    tab = result_json("get_active_tab")
    check(tab["editor_file"].endswith("a.txt"), f"Enter öffnet a.txt ({tab['editor_file']})")
    ed = result_json("editor_state")
    check(ed["selection"] == {"begin": [2, 4], "end": [2, 7]}, f"Treffer markiert, Tab zählt 4 Spalten: {ed['selection']}")
    check(st()["focus"] == "list", "Fokus bleibt in der Liste (weiter mit ↓)")
    # Links klappt die Datei des Treffers zu, Rechts wieder auf
    key("left")
    s = st()
    check(s["rows"][s["selected"]]["kind"] == "file" and s["rows"][s["selected"]]["collapsed"], "← klappt die Datei zu und wählt sie")
    key("right")
    check(not st()["rows"][st()["selected"]]["collapsed"], "→ klappt wieder auf")


def step_mouse():
    print("--- Maus: Dateikopf klappt, Treffer öffnet")
    s = st()
    n = len(s["rows"])
    click_row(row_index(s, "file", "a.txt"))
    check(len(st()["rows"]) == n - 3, "Klick auf den Dateikopf klappt zu")
    click_row(row_index(st(), "file", "a.txt"))
    check(len(st()["rows"]) == n, "zweiter Klick klappt auf")
    click_row(row_index(st(), "match", "src/b.zig", 1))
    tab = result_json("get_active_tab")
    check(tab["editor_file"].endswith("b.zig"), "Klick öffnet src/b.zig")
    ed = result_json("editor_state")
    check(ed["selection"] == {"begin": [1, 3], "end": [1, 6]}, f"'FOO' in Zeile 2 markiert: {ed['selection']}")


def step_dismiss():
    print("--- Verwerfen (x beim Überfahren)")
    s = st()
    row_action(row_index(s, "match", "src/b.zig", 0), ACT_DISMISS)
    s = st()
    check(s["match_count"] == 4 and files(s)["src/b.zig"] == 1, f"ein Treffer verworfen: {files(s)}")
    check(read("src/b.zig") == "const Foo = 1;\n// FOO\n", "Verwerfen ändert die Datei nicht")
    # Neu suchen bringt ihn zurück
    key("f", ctrl=True, shift=True)
    key("enter")
    wait(lambda s: s["match_count"] == 5, "Enter im Suchfeld sucht neu: wieder 5")


def step_replace():
    print("--- Ersetzen: Vorschau, einzeln, alle mit Rückfrage")
    key("h", ctrl=True, shift=True)
    s = st()
    check(s["replace_open"] and s["focus"] == "replace", "Ctrl+Shift+H öffnet das Ersetzen-Feld")
    rpc("type_text", ["bar"])
    s = wait(lambda s: all(r.get("replacement") == "bar" for r in s["rows"] if r["kind"] == "match") and s["match_count"] == 5,
             "Vorschau zeigt den Ersatz je Treffer")
    shot("e2e_project_search_replace.ppm")
    row_action(row_index(s, "match", "a.txt", 0), ACT_REPLACE)
    s = wait(lambda s: s["match_count"] == 4, "Ersetzen eines Treffers: 4 übrig")
    check(read("a.txt") == "alpha bar\nbeta\n\tfoo foo gamma\n", f"nur der erste Treffer ersetzt: {read('a.txt')!r}")
    # a.txt ist offen und unverändert: der Tab lädt nach, ohne als geändert zu gelten
    key("enter", ctrl=True, alt=True)
    check(result_json("ui_state")["dialog"] is not None, "Alle ersetzen fragt nach")
    key("enter"); settle(20)
    s = wait(lambda s: s["match_count"] == 0, "nach Alle ersetzen keine Treffer mehr")
    check(read("a.txt") == "alpha bar\nbeta\n\tbar bar gamma\n", f"a.txt ersetzt: {read('a.txt')!r}")
    check(read("src/b.zig") == "const bar = 1;\n// bar\n", f"src/b.zig ersetzt: {read('src/b.zig')!r}")
    check(read("ignored.txt") == "foo\n", "ignorierte Datei bleibt")
    rpc("open_file", [os.path.join(FX, "a.txt")]); settle(20)
    tab = result_json("get_active_tab")
    check(not tab["editor_modified"] and "bar bar" in result_json("editor_state")["text"], "offener Tab zeigt den neuen Inhalt, ungeändert")


def step_dirty_buffer():
    print("--- Ungespeicherter Buffer: Suche sieht ihn, Ersetzen lässt ihn aus")
    rpc("open_file", [os.path.join(FX, "äpfel.txt")]); settle(20)
    key("escape")  # Fokus vom Panel zurück in den Editor
    key("end", ctrl=True)
    rpc("type_text", ["zzz"]); settle(10)
    check(result_json("get_active_tab")["editor_modified"], "Buffer geändert, nicht gespeichert")
    key("f", ctrl=True, shift=True)
    clear_query()
    rpc("type_text", ["zzz"])
    s = wait(lambda s: s["match_count"] == 1, "Treffer nur im ungespeicherten Buffer")
    check(files(s) == {"äpfel.txt": 1}, f"gefunden in äpfel.txt: {files(s)}")
    key("tab")
    check(st()["focus"] == "replace", "Tab springt ins Ersetzen-Feld")
    key("a", ctrl=True)
    rpc("type_text", ["y"])
    key("enter", ctrl=True, alt=True)
    key("enter"); settle(20)
    check("zzz" not in read("äpfel.txt"), "Datei auf der Platte unberührt")
    check(result_json("ui_state")["toast"] is not None, "Hinweis, dass die ungespeicherte Datei übersprungen wurde")


def step_escape():
    print("--- Escape verlässt das Panel")
    key("f", ctrl=True, shift=True)
    key("escape")
    check(st()["focus"] == "none", "Escape gibt den Fokus an den Editor zurück")


def step_large():
    """Großes Projekt: das zid-Repo selbst. Trefferlimit, Liste virtualisiert (keine Clay-
    Fehler, Frame-Zeit klein), Scrollbalken und Ende der Liste erreichbar."""
    print("--- Großes Projekt: zid-Repo, Limit und Virtualisierung")
    check(rpc("open_project", [ROOT]) == "ok", "zid-Repo als Projektordner")
    settle(20)
    key("f", ctrl=True, shift=True)
    clear_query()
    t0 = time.time()
    rpc("type_text", ["e"])
    s = wait(lambda s: s["match_count"] > 0, "Suche nach 'e' liefert Treffer", timeout=30)
    took = time.time() - t0
    check(s["limit_hit"] and s["match_count"] >= 20000, f"Limit greift: {s['match_count']} Treffer in {s['file_count']} Dateien, {took:.1f}s")
    check("subset" in s["message"], f"Meldung nennt das Limit: {s['message']!r}")
    rpc("screenshot"); settle(10)
    u = result_json("ui_state")
    check(u["clay_errors"] == 0, f"keine Clay-Fehler ({u['clay_errors']})")
    check(u["last_frame_ms"] < 50, f"Layout-Zeit mit 20000 Treffern: {u['last_frame_ms']:.1f} ms")
    check(bounds("ps_scrollbar_track")["found"], "Scrollbalken an der Liste")
    key("down")
    key("end")
    s = st()
    check(s["selected"] is not None and s["selected"] > 20000, f"Ende erreichbar: Zeile {s['selected']}")
    rpc("screenshot"); settle(10)
    check(result_json("ui_state")["clay_errors"] == 0, "auch am Ende keine Clay-Fehler")
    shot("e2e_project_search_large.ppm")


STEPS = [step_open_and_search, step_options, step_keyboard_and_open, step_mouse, step_dismiss, step_replace, step_dirty_buffer, step_escape, step_large]


def main():
    setup_fixture()
    log = open(LOG, "w")
    proc = subprocess.Popen([ZID, "--headless", "--ai=off"], cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
                            env=isolated_env("e2e_project_search"))
    try:
        wait_port(proc)
        settle(20)
        check(rpc("open_project", [FX]) == "ok", "Fixture als Projektordner")
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
