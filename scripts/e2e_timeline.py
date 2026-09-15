#!/usr/bin/env python3
"""Headless-E2E für die Timeline im Explorer (VS-Code-Stil).

Fixture tmp/e2e_timeline/ ist ein eigenes Repo mit festen Commit-Zeiten:
  lib.zig anlegen (20 Tage), ändern (2 Tage), lib.zig → app.zig umbenennen (2 Std.),
  app.zig ändern (2 Std.); other.txt ein Commit; new.txt nie committet.
Prüft:
  1. Timeline anfangs eingeklappt, Klick auf den Kopf klappt auf und wird gemerkt
  2. Einträge: Betreff, Autor, relative Zeit wie VS Code, gleiche Zeit darunter ausgeblendet
  3. Hover zeigt nach 700 ms die Commit-Details
  4. Klick öffnet den Diff-Editor gegen den vorigen Commit der Datei, Timeline bleibt stehen
  5. Rechtsklick-Menü: Copy Commit ID
  6. Timeline folgt der aktiven Datei; Pin hält sie fest; Datei ohne Commit zeigt den Hinweis
  7. Refresh lädt einen neuen Commit; keine Clay-Fehler
Aufruf: python3 scripts/e2e_timeline.py
"""
import os, shutil, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e2e_open_folder import ROOT, rpc, result_json, wait_port, settle, bounds, click_center, check, shot  # noqa: E402
from e2e_shortcuts import explorer_click  # noqa: E402

FX = os.path.join(ROOT, "tmp", "e2e_timeline")
XDG = os.path.join(ROOT, "tmp", "xdg")
XDG_CONFIG = os.path.join(ROOT, "tmp", "xdg-config-timeline")
LOG = os.path.join(ROOT, "tmp", "e2e_timeline.log")
NOW = int(time.time())


def git(*args, ago=0):
    date = f"@{NOW - ago} +0000"
    env = dict(os.environ, GIT_AUTHOR_NAME="Ada", GIT_AUTHOR_EMAIL="ada@example.com",
               GIT_COMMITTER_NAME="Ada", GIT_COMMITTER_EMAIL="ada@example.com",
               GIT_AUTHOR_DATE=date, GIT_COMMITTER_DATE=date)
    return subprocess.run(["git", *args], cwd=FX, check=True, env=env, capture_output=True, text=True).stdout.strip()


def write(name, text):
    with open(os.path.join(FX, name), "w") as f:
        f.write(text)


def setup_fixture():
    shutil.rmtree(FX, ignore_errors=True)
    shutil.rmtree(XDG_CONFIG, ignore_errors=True)
    os.makedirs(FX)
    git("init", "-q", "-b", "main")
    day, hour = 86400, 3600
    write("lib.zig", "".join(f"pub const c{i} = {i};\n" for i in range(40)))
    git("add", "lib.zig"); git("commit", "-q", "-m", "lib anlegen", ago=20 * day)
    write("other.txt", "anders\n")
    git("add", "other.txt"); git("commit", "-q", "-m", "other dazu", ago=10 * day)
    write("lib.zig", "".join(f"pub const c{i} = {i * 2};\n" for i in range(40)))
    git("commit", "-q", "-am", "lib verdoppeln\n\nAusführlicher Text.", ago=2 * day)
    git("mv", "lib.zig", "app.zig")
    git("commit", "-q", "-m", "lib nach app umbenennen", ago=2 * hour)
    text = open(os.path.join(FX, "app.zig")).read().replace("c39 = 78", "c39 = 0")
    write("app.zig", text)
    git("commit", "-q", "-am", "letzte Konstante", ago=2 * hour + 60)
    write("new.txt", "nie committet\n")


def tl():
    return result_json("timeline_state")


def wait(cond, what, timeout=10):
    t0 = time.time()
    s = tl()
    while time.time() - t0 < timeout:
        s = tl()
        if cond(s):
            check(True, what)
            return s
        time.sleep(0.05)
    print("letzter Zustand:", s)
    check(False, what)


def row_center(s, i):
    b = s["body"]
    return b["x"] + b["w"] / 2, b["y"] + i * s["row_height"] + s["row_height"] / 2 - s["scroll"]


def center(b):
    return b["x"] + b["w"] / 2, b["y"] + b["h"] / 2


def step_expand():
    print("--- 1. Kopf klappt auf, gemerkt")
    s = tl()
    check(not s["expanded"], "anfangs eingeklappt wie VS Code")
    explorer_click("app.zig")
    settle(6)
    s = wait(lambda s: s["file"] == os.path.join(FX, "app.zig"), "folgt app.zig auch eingeklappt")
    check(not s["loading"] and not s["loaded"], "eingeklappt wird nichts geladen")
    rpc("click", list(center(s["header"]))); settle(4)
    s = wait(lambda s: s["expanded"] and s["loaded"], "Klick auf TIMELINE klappt auf und lädt")
    state_file = os.path.join(XDG_CONFIG, "zid", "state")
    check("timeline_expanded=true" in open(state_file).read(), "Auf-Zustand in user_state gemerkt")


def step_items():
    print("--- 2. Einträge wie VS Code")
    s = tl()
    labels = [i["label"] for i in s["items"]]
    check(labels == ["letzte Konstante", "lib nach app umbenennen", "lib verdoppeln", "lib anlegen"],
          f"--follow über die Umbenennung, Betreff = erste Zeile: {labels}")
    check(all(i["author"] == "Ada" for i in s["items"]), "Autor als Beschreibung")
    times = [(i["time"], i["time_hidden"]) for i in s["items"]]
    check(times[0] == ("2 hrs", False) and times[1] == ("2 hrs", True), f"gleiche Zeit darunter ausgeblendet: {times[:2]}")
    check(times[2] == ("2 days", False) and times[3] == ("3 wks", False), f"Kurzformen days/wks: {times[2:]}")
    check(s["items"][1]["path"] == "app.zig" and s["items"][2]["path"] == "lib.zig", "Pfad je Commit folgt der Umbenennung")
    shot("e2e_timeline_list.ppm")


def step_hover():
    print("--- 3. Hover")
    s = tl()
    rpc("move_mouse", list(row_center(s, 2))); time.sleep(1.0); settle(4)
    wait(lambda s: s["hover_index"] == 2 and s["hover_visible"], "Hover nach 700 ms sichtbar")
    shot("e2e_timeline_hover.ppm")


def step_open_changes():
    print("--- 4. Klick öffnet den Diff-Editor")
    s = tl()
    items = s["items"]
    rpc("click", list(row_center(s, 1))); settle(6)
    d = None
    t0 = time.time()
    while time.time() - t0 < 10:
        d = result_json("git_history_state")
        if d.get("view") == "diff" and d.get("loaded"):
            break
        time.sleep(0.05)
    expected = f"app.zig ({items[2]['hash'][:7]}) ↔ app.zig ({items[1]['hash'][:7]})"
    check(d and d.get("title") == expected, f"Titel wie VS Code (vorher = voriger Datei-Commit): {d and d.get('title')}")
    check(d["old_lines"] == 40 and d["changes"] == 0, f"Umbenennung ohne Inhaltsänderung: keine Änderung ({d['changes']})")
    s = wait(lambda s: s["file"] == os.path.join(FX, "app.zig") and s["selected"] == 1 and len(s["items"]) == 4,
             "Timeline bleibt bei app.zig, Eintrag markiert")
    rpc("click", list(row_center(s, 2))); settle(6)
    t0 = time.time()
    while time.time() - t0 < 10:
        d = result_json("git_history_state")
        if d.get("view") == "diff" and d.get("loaded") and d.get("title", "").startswith("lib.zig"):
            break
        time.sleep(0.05)
    # c0 = 0 bleibt beim Verdoppeln gleich: 39 geänderte Zeilen
    check(d["changes"] == 1 and d["modified_rows"] == 39, f"„lib verdoppeln“: 39 geänderte Zeilen paarweise ({d['modified_rows']})")
    # Diff zeigt den alten Namen lib.zig, die Timeline bleibt trotzdem bei app.zig (VS Code: gleiche Datei-URI)
    wait(lambda s: s["file"] == os.path.join(FX, "app.zig") and len(s["items"]) == 4 and s["selected"] == 2,
         "Timeline bleibt nach Diff mit altem Namen bei app.zig")
    shot("e2e_timeline_diff.ppm")


def step_menu():
    print("--- 5. Kontextmenü")
    s = tl()
    x, y = row_center(s, 0)
    rpc("right_click", [x, y]); settle(4)
    wait(lambda s: s["menu_open"], "Rechtsklick öffnet das Menü")
    shot("e2e_timeline_menu.ppm")
    click_center("tl_menu_timeline_copy_commit_id")
    ui = result_json("ui_state")
    check(ui["clipboard_text"] == s["items"][0]["hash"], "Copy Commit ID legt den Hash in die Zwischenablage")


def step_follow_pin():
    print("--- 6. Folgen, Pin, Datei ohne Commit")
    explorer_click("other.txt"); settle(6)
    wait(lambda s: s["file"] == os.path.join(FX, "other.txt") and s["loaded"] and len(s["items"]) == 1, "folgt other.txt (1 Commit)")
    s = tl()
    rpc("move_mouse", list(center(s["header"]))); settle(6)
    click_center("tl_btn_pin")
    wait(lambda s: s["pinned"], "Pin hält die Timeline fest")
    explorer_click("app.zig"); settle(6)
    check(tl()["file"] == os.path.join(FX, "other.txt"), "angepinnt: bleibt bei other.txt")
    rpc("move_mouse", list(center(tl()["header"]))); settle(6)
    click_center("tl_btn_pin")
    # Lösen: beim nächsten Tab-Wechsel folgt sie wieder
    explorer_click("new.txt"); settle(6)
    wait(lambda s: s["file"] == os.path.join(FX, "new.txt") and s["loaded"], "gelöst: folgt new.txt")
    wait(lambda s: s["message"] == "No timeline information was provided.", "Datei ohne Commit: Hinweis wie VS Code")
    shot("e2e_timeline_empty.ppm")


def step_staged():
    print("--- 6b. Staged Changes wie VS Code")
    explorer_click("other.txt"); settle(6)
    wait(lambda s: s["file"] == os.path.join(FX, "other.txt") and s["loaded"], "other.txt aktiv")
    write("other.txt", "anders\ngestagt\n")
    git("add", "other.txt")
    rpc("move_mouse", list(center(tl()["header"]))); settle(6)
    click_center("tl_btn_refresh")
    s = wait(lambda s: len(s["items"]) == 2 and s["items"][0]["label"] == "Staged Changes", "gestagte Datei: „Staged Changes“ oben")
    check(s["items"][0]["author"] == "" and s["items"][0]["time"] == "now", "ohne Beschreibung, Zeit „now“")
    rpc("click", list(row_center(s, 0))); settle(6)
    t0 = time.time()
    d = {}
    while time.time() - t0 < 10:
        d = result_json("git_history_state")
        if d.get("view") == "diff" and d.get("loaded") and d.get("title") == "other.txt (Index)":
            break
        time.sleep(0.05)
    check(d.get("title") == "other.txt (Index)", f"Titel wie VS Code: {d.get('title')}")
    check(d.get("changes") == 1 and d.get("added") == 1, f"Index gegen HEAD: eine hinzugefügte Zeile (+{d.get('added')})")
    shot("e2e_timeline_staged.ppm")
    # zurücksetzen, damit Refresh unten nur den Commit sieht
    git("reset", "-q", "other.txt")
    write("other.txt", "anders\n")


def step_refresh():
    print("--- 7. Refresh")
    explorer_click("other.txt"); settle(6)
    wait(lambda s: s["file"] == os.path.join(FX, "other.txt") and len(s["items"]) == 1, "wieder other.txt")
    write("other.txt", "anders\nmehr\n")
    git("commit", "-q", "-am", "other erweitert")
    rpc("move_mouse", list(center(tl()["header"]))); settle(6)
    click_center("tl_btn_refresh")
    wait(lambda s: len(s["items"]) == 2 and s["items"][0]["label"] == "other erweitert", "Refresh zeigt den neuen Commit")
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
        check(rpc("open_folder", [FX]) == "ok", "Fixture-Repo als Explorer-Root")
        settle(10)
        for step in (step_expand, step_items, step_hover, step_open_changes, step_menu, step_follow_pin, step_staged, step_refresh):
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
