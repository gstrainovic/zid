#!/usr/bin/env python3
"""Headless-E2E für den Diff-Editor im VS-Code-Stil (Tab `git-diff://…`).

Fixture tmp/e2e_git_diff/ ist ein eigenes Repo:
  1. calc.zig anlegen (300 Zeilen)   2. drei Stellen ändern, eine Zeile einfügen
  3. calc.zig → rechner.zig umbenennen und eine Zeile ändern
Prüft:
  1. Titel wie VS Code „calc.zig (alt) ↔ calc.zig (neu)“, ganze Datei geladen, Highlighting an
  2. Automatic: nebeneinander bei breitem Pane, geänderte Zeilen paarweise
  3. Alt+F5 / Shift+Alt+F5 springen zyklisch zwischen Änderungen
  4. Collapse Unchanged Regions: Faltbalken, Klick deckt auf; Inline View umschaltbar
  5. Virtualisierung: nur sichtbare Zeilen gezeichnet
  6. Wurzel-Commit: linke Seite leer, alles hinzugefügt
  7. Umbenennung: Zeilen paarweise statt komplett neu
  8. Split: schmales Pane schaltet automatisch auf untereinander, keine Clay-Fehler
  9. UTF-16-Datei (BOM FF FE): Hinweis wie VS Code, kein ungültiges UTF-8 an den Shaper
 10. Windows-1252-Datei: Umlaute, € und typografische Zeichen korrekt als UTF-8
Aufruf: python3 scripts/e2e_git_diff.py
"""
import os, shutil, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e2e_open_folder import ROOT, rpc, result_json, wait_port, settle, check, shot, rmtree  # noqa: E402
from e2e_shortcuts import key  # noqa: E402

FX = os.path.join(ROOT, "tmp", "e2e_git_diff")
XDG = os.path.join(ROOT, "tmp", "xdg")
XDG_CONFIG = os.path.join(ROOT, "tmp", "xdg-config-git-diff")
LOG = os.path.join(ROOT, "tmp", "e2e_git_diff.log")


def git(*args):
    env = dict(os.environ, GIT_AUTHOR_NAME="Ada", GIT_AUTHOR_EMAIL="ada@example.com",
               GIT_COMMITTER_NAME="Ada", GIT_COMMITTER_EMAIL="ada@example.com")
    return subprocess.run(["git", *args], cwd=FX, check=True, env=env, capture_output=True, text=True).stdout.strip()


def source(changed=False):
    lines = [f"pub fn f{i}(x: i32) i32 {{ return x + {i}; }}" for i in range(300)]
    if changed:
        lines[40] = "pub fn f40(x: i32) i32 { return x * 40; }"
        lines[150] = "pub fn f150(y: i32) i32 { return y + 150; }"
        lines.insert(200, "// neu eingefügt")
        lines[280] = "pub fn f279(x: i32) i32 { return x - 279; }"
    return "\n".join(lines) + "\n"


def write(name, text):
    with open(os.path.join(FX, name), "w", encoding="utf-8") as f:
        f.write(text)


def write_utf16(name, text):
    """UTF-16LE mit BOM, wie Windows-Logdateien (PowerShell 5 `>`)."""
    with open(os.path.join(FX, name), "wb") as f:
        f.write(b"\xff\xfe" + text.encode("utf-16-le"))


def write_cp1252(name, text):
    """Windows-1252 wie ASP-Dateien unter Windows (Umlaute, €, typografische Zeichen)."""
    with open(os.path.join(FX, name), "wb") as f:
        f.write(text.encode("cp1252"))


def setup_fixture():
    rmtree(FX)
    shutil.rmtree(XDG_CONFIG, ignore_errors=True)
    os.makedirs(FX)
    git("init", "-q", "-b", "main")
    write("calc.zig", source())
    write_utf16("debug.log", "DEBUG 28.09.2026 08:00 start\r\n")
    write_cp1252("seite.asp", "<% ' Grösse prüfen %>\r\n<p>Übersicht</p>\r\n")
    git("add", "calc.zig", "debug.log", "seite.asp"); git("commit", "-q", "-m", "anlegen")
    write("calc.zig", source(changed=True))
    write_utf16("debug.log", "DEBUG 28.09.2026 08:00 start\r\nDEBUG 30.09.2026 08:00 weiter\r\n")
    write_cp1252("seite.asp", "<% ' Grösse prüfen %>\r\n<p>Übersicht – „neu“ 5 €</p>\r\n")
    git("commit", "-q", "-am", "ändern")
    git("mv", "calc.zig", "rechner.zig")
    text = source(changed=True).replace("return x + 0;", "return x;")
    write("rechner.zig", text)
    git("commit", "-q", "-am", "umbenennen")


def diff_path(rev, path, previous):
    commit = git("rev-parse", rev)
    parents = git("show", "-s", "--format=%P", commit)
    parent = parents.split(" ")[0] if parents else ""
    return f"git-diff://{commit}\x1f{parent}\x1f{FX}\x1f{path}\x1f{previous}", commit, parent


def st():
    return result_json("git_diff_state")


def wait(cond, what, timeout=10):
    t0 = time.time()
    s = st()
    while time.time() - t0 < timeout:
        s = st()
        if s.get("active") and s.get("view") == "diff" and cond(s):
            check(True, what)
            return s
        time.sleep(0.05)
    print("letzter Zustand:", s)
    check(False, what)


def click(b):
    rpc("click", [b["x"] + b["w"] / 2, b["y"] + b["h"] / 2])
    settle(4)


def open_diff(rev, path, previous):
    tab, commit, parent = diff_path(rev, path, previous)
    check(rpc("open_file", [tab]) == "ok", f"Diff-Tab {rev} {path} geöffnet")
    return commit, parent


def step_side_by_side():
    print("--- 1./2. Diff-Editor nebeneinander")
    commit, parent = open_diff("HEAD~1", "calc.zig", "calc.zig")
    s = wait(lambda s: s["loaded"], "Diff geladen")
    check(s["title"] == f"calc.zig ({parent[:7]}) ↔ calc.zig ({commit[:7]})", f"Titel wie VS Code: {s['title']}")
    tabs = result_json("get_active_tab")["tabs"]
    check(any(t["name"] == s["title"] for t in tabs), "Tab trägt den Titel")
    check(s["old_lines"] == 300 and s["new_lines"] == 301, f"ganze Datei alt/neu ({s['old_lines']}/{s['new_lines']})")
    check(s["layout"] == "side_by_side" and s["mode"] == "auto", f"Automatic → nebeneinander bei {s['body']['w']} px")
    check(s["changes"] == 4 and s["modified_rows"] == 3 and s["added"] == 4 and s["removed"] == 3,
          f"4 Änderungen, 3 paarweise, +4 −3 (+{s['added']} −{s['removed']}, {s['modified_rows']} paarweise)")
    check(s["old_highlight"] and s["new_highlight"], "Syntax-Highlighting für beide Seiten")
    check(s["rendered_rows"] < 80 and s["rows"] == 301, f"virtualisiert: {s['rendered_rows']} von {s['rows']} Zeilen gezeichnet")
    shot("e2e_git_diff_side.ppm")


def step_navigation():
    print("--- 3. Alt+F5 / Shift+Alt+F5")
    rpc("key_press_alt", ["f5", False, False, True]); settle(4)
    s = wait(lambda s: s["current_row"] == 40, "Alt+F5 springt zur ersten Änderung (Zeile 41)")
    check(s["scroll_y"] > 0, "Diff scrollt dorthin")
    rpc("key_press_alt", ["f5", False, False, True]); settle(4)
    wait(lambda s: s["current_row"] == 150, "Alt+F5 zur zweiten Änderung")
    rpc("key_press_alt", ["f5", False, True, True]); settle(4)
    wait(lambda s: s["current_row"] == 40, "Shift+Alt+F5 zurück")
    rpc("key_press_alt", ["f5", False, True, True]); settle(4)
    wait(lambda s: s["current_row"] == 280, "Shift+Alt+F5 am Anfang springt ans Ende")
    shot("e2e_git_diff_nav.ppm")


def step_collapse_inline():
    print("--- 4. Collapse Unchanged Regions und Inline View")
    s = st()
    click(s["buttons"]["collapse"])
    s = wait(lambda s: s["collapse"] and s["folds"] > 0, "Knopf klappt unveränderte Bereiche ein")
    check(s["items"] < 40, f"nur Änderungen mit Kontext sichtbar ({s['items']} Einträge)")
    rpc("key_press", ["home", False]); settle(4)
    shot("e2e_git_diff_collapsed.ppm")
    before = st()
    fold_y = before["body"]["y"] + before["first_fold_item"] * before["row_height"] + before["row_height"] / 2 - before["scroll_y"]
    rpc("click", [before["body"]["x"] + before["body"]["w"] / 2, fold_y]); settle(4)
    s = wait(lambda s: s["items"] > before["items"], "Klick auf Faltbalken deckt den Bereich auf")
    click(s["buttons"]["collapse"])
    wait(lambda s: not s["collapse"] and s["folds"] == 0, "zweiter Klick zeigt wieder alles")

    click(st()["buttons"]["inline"])
    s = wait(lambda s: s["layout"] == "inline_", "Inline View umgeschaltet")
    check(s["rows"] == 304, f"untereinander: geänderte Zeilen doppelt ({s['rows']} Zeilen)")
    rpc("key_press_alt", ["f5", False, False, True]); settle(4)
    shot("e2e_git_diff_inline.ppm")
    click(st()["buttons"]["inline"])
    wait(lambda s: s["layout"] == "side_by_side", "zurück nebeneinander")


def step_root_and_rename():
    print("--- 6. Wurzel-Commit")
    open_diff("HEAD~2", "calc.zig", "calc.zig")
    s = wait(lambda s: s["loaded"] and s["new_lines"] == 300 and s["old_lines"] == 0, "Wurzel-Commit: alt leer, neu 300 Zeilen")
    check(s["title"].startswith("calc.zig (4b825dc)"), f"Vergleich mit leerem Baum wie VS Code: {s['title']}")
    check(s["added"] == 300 and s["removed"] == 0, "alles hinzugefügt")

    print("--- 7. Umbenennung")
    open_diff("HEAD", "rechner.zig", "calc.zig")
    s = wait(lambda s: s["loaded"] and s["old_lines"] == 301, "Umbenennung: alte Datei calc.zig geladen")
    check(s["changes"] == 1 and s["modified_rows"] == 1, f"nur die geänderte Zeile ({s['changes']} Änderung, +{s['added']} −{s['removed']})")
    shot("e2e_git_diff_rename.ppm")


def step_utf16():
    print("--- 9. UTF-16-Datei: Hinweis statt Zeilen")
    open_diff("HEAD~1", "debug.log", "debug.log")
    s = wait(lambda s: s["loaded"] and s["binary"], "UTF-16 gilt als binär")
    check(s["rendered_rows"] == 0, f"keine Zeilen gezeichnet ({s['rendered_rows']})")
    settle(4)
    with open(LOG, errors="replace") as f:
        bad = [l for l in f if "invalid UTF-8" in l]
    check(not bad, f"kein ungültiges UTF-8 an den Shaper ({bad[:1]})")
    shot("e2e_git_diff_utf16.ppm")

    print("--- 10. Windows-1252 (ASP): als UTF-8 angezeigt")
    open_diff("HEAD~1", "seite.asp", "seite.asp")
    s = wait(lambda s: s["loaded"] and s["new_lines"] == 2, "cp1252-Datei geladen")
    check(not s["binary"], "kein Binär-Hinweis")
    check(s["new_head"] == ["<% ' Grösse prüfen %>", "<p>Übersicht – „neu“ 5 €</p>"], f"Umlaute, €, typografische Zeichen: {s['new_head']}")
    check(s["changes"] == 1 and s["modified_rows"] == 1, f"eine geänderte Zeile ({s['changes']})")
    settle(4)
    with open(LOG, errors="replace") as f:
        bad = [l for l in f if "invalid UTF-8" in l]
    check(not bad, f"kein ungültiges UTF-8 an den Shaper ({bad[:1]})")
    shot("e2e_git_diff_cp1252.ppm")


def step_split_auto_inline():
    print("--- 8. Split: schmales Pane → untereinander")
    before = st()["body"]["w"]
    rpc("split_pane", ["h"])
    settle(20)
    check(result_json("ui_state")["pane_count"] == 2, "zwei Panes nebeneinander")
    wait(lambda s: s["layout"] == "inline_" and s["body"]["w"] < 900, "Automatic schaltet unter 900 px auf untereinander")
    shot("e2e_git_diff_split.ppm")
    with open(LOG, errors="replace") as f:
        clay_errors = [l for l in f if "error(ui): Clay:" in l]
    check(not clay_errors, f"keine Clay-Fehler im Log ({clay_errors[:2]})")


def main():
    setup_fixture()
    log = open(LOG, "w")
    env = dict(os.environ, XDG_DATA_HOME=XDG, XDG_CONFIG_HOME=XDG_CONFIG)
    proc = subprocess.Popen(
        [os.path.join(ROOT, "zig-out", "bin", "zid"), "--headless", "--ai=off"],
        cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, env=env, start_new_session=True,
    )
    try:
        wait_port(proc)
        settle(20)
        for step in (step_side_by_side, step_navigation, step_collapse_inline, step_root_and_rename, step_utf16, step_split_auto_inline):
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
            os.killpg(proc.pid, 9)
        log.close()


if __name__ == "__main__":
    main()
