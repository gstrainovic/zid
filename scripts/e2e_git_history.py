#!/usr/bin/env python3
"""Headless-E2E für die Git-History: Repo-Verlauf (View → Git History, Palette) und
Datei-Verlauf (Tab-, Editor- und Explorer-Kontextmenü) samt Diff des gewählten Commits.

Fixture tmp/e2e_git_history/ ist ein eigenes Repo mit vier Commits:
  1. a.txt anlegen   2. c.txt dazu   3. a.txt auf 250 Zeilen   4. a.txt → b.txt umbenennen
Prüft:
  1. Git History über die Palette: vier Commits, jüngster gewählt, Diff geladen
  2. ↓/End/Home und Klick wählen, der Diff folgt; Mausrad scrollt Liste und Diff getrennt
  3. Diff ist virtualisiert (250-Zeilen-Diff zeichnet nur den sichtbaren Teil)
  4. File History aus dem Tab-Menü: --follow über die Umbenennung, alter Commit zeigt a.txt
  5. File History aus dem Explorer- und dem Editor-Kontextmenü
  6. Datei ohne Commit: Fehlermeldung statt leerer Ansicht
  7. F5 lädt neu, die Auswahl bleibt über den Hash
  8. Split mit History-Tab: keine Clay-Fehler (duplicate_id) im Log
Aufruf: python3 scripts/e2e_git_history.py
"""
import os, shutil, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e2e_open_folder import ROOT, rpc, result_json, wait_port, settle, bounds, click_center, check, shot, rmtree  # noqa: E402
from e2e_shortcuts import key, explorer_click  # noqa: E402

FX = os.path.join(ROOT, "tmp", "e2e_git_history")
XDG = os.path.join(ROOT, "tmp", "xdg")
XDG_CONFIG = os.path.join(ROOT, "tmp", "xdg-config-git-history")
LOG = os.path.join(ROOT, "tmp", "e2e_git_history.log")


def git(*args):
    env = dict(os.environ, GIT_AUTHOR_NAME="Ada", GIT_AUTHOR_EMAIL="ada@example.com",
               GIT_COMMITTER_NAME="Ada", GIT_COMMITTER_EMAIL="ada@example.com")
    subprocess.run(["git", *args], cwd=FX, check=True, env=env, stdout=subprocess.DEVNULL)


def write(name, text):
    with open(os.path.join(FX, name), "w") as f:
        f.write(text)


def setup_fixture():
    rmtree(FX)
    shutil.rmtree(XDG_CONFIG, ignore_errors=True)
    os.makedirs(FX)
    git("init", "-q", "-b", "main")
    write("a.txt", "eins\nzwei\ndrei\n")
    git("add", "a.txt"); git("commit", "-q", "-m", "a.txt anlegen")
    write("c.txt", "c\n")
    git("add", "c.txt"); git("commit", "-q", "-m", "c.txt dazu")
    write("a.txt", "".join(f"zeile {i}\n" for i in range(250)))
    git("commit", "-q", "-am", "a.txt auf 250 Zeilen")
    git("mv", "a.txt", "b.txt")
    write("b.txt", "".join(f"zeile {i}\n" for i in range(249)) + "geändert\n")
    git("commit", "-q", "-am", "a nach b umbenennen")
    write("neu.txt", "nie committet\n")
    time.sleep(0.3)


def hist():
    return result_json("git_history_state")


def wait_hist(cond, what, timeout=10):
    t0 = time.time()
    st = hist()
    while time.time() - t0 < timeout:
        st = hist()
        if st["active"] and cond(st):
            check(True, what)
            return st
        time.sleep(0.05)
    print("letzter Zustand:", {k: v for k, v in st.items() if k != "diff_head"})
    check(False, what)


def diff_ready(st):
    return (not st["loading_log"] and st["selected"] is not None
            and st["diff_hash"] == st["commits"][st["selected"]]["hash"])


def subjects(st):
    return [c["subject"] for c in st["commits"]]


def palette(label):
    key("p", ctrl=True, shift=True)
    rpc("type_text", [label])
    settle(4)
    check(result_json("picker_state")["selected_label"] == label, f"Palette wählt {label}")
    key("enter")


def row_center(st, index):
    lb, rh = st["list"], st["row_height"]
    return lb["x"] + lb["w"] / 2, lb["y"] + index * rh + rh / 2 - st["list_scroll"]


def active_tab_index():
    return result_json("get_active_tab")["active_index"]


def step_repo_history():
    print("--- 1. Git History über die Palette")
    palette("Git History")
    st = wait_hist(diff_ready, "Repo-Log geladen und Diff des jüngsten Commits da")
    check(st["kind"] == "repo" and st["target"] == FX, f"Ziel ist das Fixture-Repo: {st['target']}")
    check(subjects(st) == ["a nach b umbenennen", "a.txt auf 250 Zeilen", "c.txt dazu", "a.txt anlegen"],
          f"vier Commits, jüngster zuerst: {subjects(st)}")
    check(st["selected"] == 0, "jüngster Commit gewählt")
    check(st["diff_files"] == 1 and "rename" in st["diff_head"], "Diff zeigt die Umbenennung")
    shot("e2e_git_history_repo.ppm")

    print("--- 2. Auswahl per Tastatur und Klick, Diff folgt")
    key("down")
    st = wait_hist(lambda s: s["selected"] == 1 and diff_ready(s), "↓ wählt Commit 2, Diff folgt")
    check(st["diff_added"] >= 247, f"250-Zeilen-Commit hat viele + Zeilen ({st['diff_added']})")
    key("end")
    wait_hist(lambda s: s["selected"] == 3 and diff_ready(s), "End wählt den ältesten Commit")
    key("home")
    st = wait_hist(lambda s: s["selected"] == 0 and diff_ready(s), "Home wählt den jüngsten Commit")
    x, y = row_center(st, 2)
    rpc("click", [x, y]); settle()
    st = wait_hist(lambda s: s["selected"] == 2 and diff_ready(s), "Klick auf Zeile 3 wählt c.txt dazu")
    check(st["commits"][2]["subject"] == "c.txt dazu", "gewählter Commit ist c.txt dazu")

    print("--- 3. Diff scrollt und ist virtualisiert")
    x, y = row_center(st, 1)
    rpc("click", [x, y]); settle()
    st = wait_hist(lambda s: s["selected"] == 1 and diff_ready(s), "250-Zeilen-Commit gewählt")
    db = st["diff"]
    rpc("scroll", [db["x"] + db["w"] / 2, db["y"] + db["h"] / 2, -10]); settle(6)
    st = wait_hist(lambda s: s["diff_scroll"] > 0, "Mausrad über dem Diff scrollt den Diff")
    check(st["list_scroll"] == 0, "Liste bleibt stehen")
    check(st["diff_lines"] > 250 and st["rendered_diff_rows"] < 120,
          f"nur sichtbare Diff-Zeilen gezeichnet ({st['rendered_diff_rows']} von {st['diff_lines']})")
    shot("e2e_git_history_diff.ppm")


def open_b_txt():
    explorer_click("b.txt")
    settle(6)
    tabs = result_json("get_active_tab")["tabs"]
    check(any(t["name"] == "b.txt" for t in tabs), "b.txt als Tab geöffnet")


def step_file_history_tab_menu():
    print("--- 4. File History aus dem Tab-Menü (über die Umbenennung)")
    open_b_txt()
    b = result_json("tab_bounds", [active_tab_index()])
    rpc("right_click", [b["x"] + b["w"] / 2, b["y"] + b["h"] / 2]); settle()
    click_center("tab_menu_file_history")
    st = wait_hist(lambda s: s["kind"] == "file" and diff_ready(s), "Datei-History von b.txt geladen")
    check(st["target"] == os.path.join(FX, "b.txt"), f"Ziel b.txt: {st['target']}")
    check(subjects(st) == ["a nach b umbenennen", "a.txt auf 250 Zeilen", "a.txt anlegen"],
          f"--follow findet drei Commits: {subjects(st)}")
    check([c["path"] for c in st["commits"]] == ["b.txt", "a.txt", "a.txt"], "Pfad je Commit folgt der Umbenennung")
    check("rename from a.txt" in st["diff_head"] and st["diff_added"] < 5,
          f"Umbenennungs-Commit zeigt die Umbenennung statt einer neuen Datei (+{st['diff_added']})")
    key("end")
    st = wait_hist(lambda s: s["selected"] == 2 and diff_ready(s), "ältester Commit gewählt")
    check(st["diff_files"] == 1 and "a/a.txt" in st["diff_head"], "Diff zeigt a.txt, nur diese Datei")
    shot("e2e_git_history_file.ppm")


def step_file_history_explorer_and_editor():
    print("--- 5. File History aus Explorer- und Editor-Menü")
    explorer_click("c.txt", right=True)
    click_center("fx_menu_file_history_entry")
    st = wait_hist(lambda s: s["target"] == os.path.join(FX, "c.txt") and diff_ready(s), "Explorer-Menü öffnet c.txt-History")
    check(subjects(st) == ["c.txt dazu"], f"ein Commit: {subjects(st)}")

    open_b_txt()
    rpc("right_click", [700, 400]); settle()  # Mitte des Editors (Screenshot 1200x800, Explorer links)
    click_center("editor_menu_file_history")
    st = wait_hist(lambda s: s["target"] == os.path.join(FX, "b.txt") and diff_ready(s), "Editor-Menü öffnet b.txt-History")
    check(len(st["commits"]) == 3, "wieder drei Commits (vorhandener Tab wurde aktiviert)")


def step_error_untracked():
    print("--- 6. Datei ohne Commit")
    explorer_click("neu.txt", right=True)
    click_center("fx_menu_file_history_entry")
    st = wait_hist(lambda s: s["target"] == os.path.join(FX, "neu.txt") and not s["loading_log"], "History von neu.txt geladen")
    check(len(st["commits"]) == 0, "keine Commits")
    check(st["error"] is None and st["empty_text"] != "", f"Hinweis statt leerer Fläche: {st['empty_text']!r}")
    shot("e2e_git_history_empty.ppm")


def step_reload_keeps_selection():
    print("--- 7. F5 lädt neu, Auswahl bleibt")
    palette("Git History")
    st = wait_hist(lambda s: s["kind"] == "repo" and diff_ready(s), "Repo-History wieder aktiv")
    check(st["selected"] == 1, f"vorhandener Tab behält seine Auswahl ({st['selected']})")
    key("home")
    key("down")
    st = wait_hist(lambda s: s["selected"] == 1 and diff_ready(s), "Commit 2 gewählt")
    chosen = st["commits"][1]["hash"]
    write("c.txt", "c\nneu\n")
    git("commit", "-q", "-am", "c.txt erweitert")
    key("f5")
    st = wait_hist(lambda s: len(s["commits"]) == 5 and not s["loading_log"], "F5 lädt fünf Commits")
    check(st["commits"][st["selected"]]["hash"] == chosen and st["selected"] == 2, "Auswahl folgt dem Hash nach unten")


def step_split_no_clay_errors():
    print("--- 8. Split mit History-Tab")
    key("backslash", ctrl=True)
    settle(20)
    check(result_json("ui_state")["pane_count"] == 2, "zwei Panes")
    wait_hist(lambda s: s["kind"] == "repo" and diff_ready(s), "History auch im neuen Pane")
    shot("e2e_git_history_split.ppm")
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
        for step in (step_repo_history, step_file_history_tab_menu, step_file_history_explorer_and_editor,
                     step_error_untracked, step_reload_keeps_selection, step_split_no_clay_errors):
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
