#!/usr/bin/env python3
"""Headless-E2E für Source Control „Changes“ mit Commit-Eingabefeld (VS-Code-Stil).
Fixture tmp/e2e_scm_changes/: Repo mit a.txt und b.txt committet; dann a.txt geändert,
b.txt gelöscht, c.txt neu (untracked).
Prüft:
  1. Ctrl+Shift+G: Fokus im Eingabefeld, Platzhalter mit Branch, Gruppe Changes mit M/D/U,
     gelöscht durchgestrichen, Farben je Status
  2. Stage über die Aktion beim Überfahren: Staged Changes erscheint; Klick auf den Eintrag
     öffnet den Diff „a.txt (Index)“; Changes-Eintrag öffnet „c.txt (Working Tree)“
  3. Unstage über die Aktion; Discard mit Rückfrage löscht die untracked Datei
  4. Commit ohne Nachricht: Hinweis; Commit ohne Staged Changes: Rückfrage, Yes stagt alles
     und committet; Graph zeigt den Commit, Feld leer, Liste leer
  4b. Knopf „Publish Branch“ ohne Upstream (push -u origin main); mehrzeilige Nachricht (Enter =
     neue Zeile, Feld wächst, ↑/Pos1 bewegen in der Zeile); danach „Push 1↑“, Remote hat den Commit
  5. Tastatur: Tab wechselt Feld → Liste → Graph, ↓/Enter in der Liste, Escape gibt ab
Aufruf: python3 scripts/e2e_scm_changes.py
"""
import os, shutil, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e2e_open_folder import ROOT, rpc, result_json, wait_port, settle, bounds, click_center, check, shot, rmtree  # noqa: E402
from e2e_shortcuts import key  # noqa: E402

BASE = os.path.join(ROOT, "tmp", "e2e_scm_changes")
FX = os.path.join(BASE, "work")
REMOTE = os.path.join(BASE, "remote.git")
XDG = os.path.join(ROOT, "tmp", "xdg")
XDG_CONFIG = os.path.join(ROOT, "tmp", "xdg-config-scm-changes")
LOG = os.path.join(ROOT, "tmp", "e2e_scm_changes.log")

# RowAction-Reihenfolge aus scm_changes_view.zig: IDI("sc_act", zeile * 8 + aktion)
ACT_OPEN, ACT_STAGE, ACT_UNSTAGE, ACT_DISCARD, ACT_STAGE_ALL, ACT_UNSTAGE_ALL, ACT_DISCARD_ALL = range(7)


def git(*args):
    env = dict(os.environ, GIT_AUTHOR_NAME="Ada", GIT_AUTHOR_EMAIL="ada@example.com",
               GIT_COMMITTER_NAME="Ada", GIT_COMMITTER_EMAIL="ada@example.com")
    return subprocess.run(["git", *args], cwd=FX, check=True, env=env, capture_output=True, text=True).stdout.strip()


def write(name, text):
    with open(os.path.join(FX, name), "w") as f:
        f.write(text)


def setup_fixture():
    rmtree(BASE)
    shutil.rmtree(XDG_CONFIG, ignore_errors=True)
    os.makedirs(FX)
    git("init", "-q", "-b", "main")
    # zid committet selbst: Identität im Repo, nicht nur in der Umgebung des Skripts
    git("config", "user.name", "Ada")
    git("config", "user.email", "ada@example.com")
    write("a.txt", "eins\nzwei\n")
    write("b.txt", "weg\n")
    git("add", "a.txt", "b.txt"); git("commit", "-q", "-m", "init")
    # bares Remote neben dem Repo, ohne Upstream: erst „Publish Branch“, danach „Push“
    git("init", "-q", "--bare", REMOTE)
    git("remote", "add", "origin", REMOTE)
    write("a.txt", "eins\nzwei\ndrei\n")
    os.remove(os.path.join(FX, "b.txt"))
    write("c.txt", "frei\n")


def remote_git(*args):
    return subprocess.run(["git", *args], cwd=REMOTE, check=True, capture_output=True, text=True).stdout.strip()


def st():
    return result_json("scm_state")


def ch():
    return st()["changes"]


def wait(cond, what, timeout=15):
    t0 = time.time()
    s = st()
    while time.time() - t0 < timeout:
        s = st()
        if cond(s):
            check(True, what)
            return s
        time.sleep(0.05)
    print("letzter Zustand:", {k: (v if k not in ("commits", "rows") else v[:6]) for k, v in s.items()})
    check(False, what)


def row_center(c, i):
    b = c["body"]
    return b["x"] + b["w"] / 2, b["y"] + i * c["row_height"] + c["row_height"] / 2 - c["scroll"]


def row_index(c, path):
    return next(i for i, r in enumerate(c["rows"]) if r["path"] == path)


def hover_action(c, i, act):
    """Zeile überfahren, dann die Aktion anklicken (nur in der überfahrenen Zeile im Layout)."""
    rpc("move_mouse", list(row_center(c, i))); settle(6)
    click_center("sc_act", i * 8 + act)
    settle(6)


def diff_state(pred, what):
    t0 = time.time()
    d = {}
    while time.time() - t0 < 10:
        d = result_json("git_diff_state")
        if d.get("view") == "diff" and d.get("loaded") and pred(d):
            check(True, what)
            return d
        time.sleep(0.05)
    print("letzter Diff-Zustand:", d)
    check(False, what)


def step_show():
    print("--- 1. Ctrl+Shift+G zeigt Changes")
    key("g", ctrl=True, shift=True)
    s = wait(lambda s: s["mode"] == "scm" and s["changes"]["branch"] == "main" and len(s["changes"]["groups"]["changes"]) == 3,
             "Source Control mit drei Änderungen")
    c = s["changes"]
    check(c["focus"] == "commit_input", "Fokus im Eingabefeld wie VS Code")
    check(c["message"] == "" and c["validation"] is None, "Feld leer, kein Hinweis")
    g = {e["path"]: e for e in c["groups"]["changes"]}
    check(g["a.txt"]["letter"] == "M" and g["a.txt"]["color"] == "modified", f"a.txt M gelb: {g['a.txt']}")
    check(g["b.txt"]["letter"] == "D" and g["b.txt"]["strike"] and g["b.txt"]["color"] == "deleted", f"b.txt D durchgestrichen rot: {g['b.txt']}")
    check(g["c.txt"]["letter"] == "U" and g["c.txt"]["color"] == "untracked", f"c.txt U grün: {g['c.txt']}")
    check(c["groups"]["staged"] == [] and c["groups"]["merge"] == [], "keine Staged/Merge Changes")
    check([r["kind"] for r in c["rows"]] == ["group", "entry", "entry", "entry"], "Zeilen: Kopf Changes + drei Einträge")
    check(bounds("sc_input_box")["h"] > 20, "Eingabefeld im Layout")
    shot("e2e_scm_changes.ppm")
    # Tooltip nach 700 ms über der Kopf-Aktion
    h = c["header"]
    rpc("move_mouse", [h["x"] + h["w"] / 2, h["y"] + h["h"] / 2]); settle(6)
    b = bounds("sc_btn_refresh")
    rpc("move_mouse", [b["x"] + b["w"] / 2, b["y"] + b["h"] / 2]); settle(4)
    check(result_json("ui_state")["tooltip"] is None, "sofort noch kein Tooltip")
    time.sleep(1.0); settle(4)
    check(result_json("ui_state")["tooltip"] == "Refresh", f"Tooltip „Refresh“: {result_json('ui_state')['tooltip']!r}")
    shot("e2e_scm_tooltip.ppm")


def step_stage_and_diffs():
    print("--- 2. Stage über Hover-Aktion, Diffs")
    c = ch()
    i = row_index(c, "a.txt")
    rpc("move_mouse", list(row_center(c, i))); settle(6)
    b = bounds("sc_act", i * 8 + ACT_STAGE)
    rpc("move_mouse", [b["x"] + b["w"] / 2, b["y"] + b["h"] / 2]); time.sleep(1.0); settle(4)
    check(result_json("ui_state")["tooltip"] == "Stage Changes", f"Tooltip der Zeilen-Aktion: {result_json('ui_state')['tooltip']!r}")
    hover_action(c, i, ACT_STAGE)
    s = wait(lambda s: [e["path"] for e in s["changes"]["groups"]["staged"]] == ["a.txt"] and len(s["changes"]["groups"]["changes"]) == 2,
             "a.txt gestagt: Staged Changes mit a.txt, Changes mit zwei")
    c = s["changes"]
    check(c["rows"][0]["group"] == "staged" and c["rows"][2]["group"] == "changes", "Staged-Gruppe vor Changes")
    check(c["groups"]["staged"][0]["kind"] == "index_modified", "Index Modified")
    # Klick auf den gestagten Eintrag: Diff Index gegen HEAD
    rpc("click", list(row_center(c, 1))); settle(6)
    diff_state(lambda d: d.get("title") == "a.txt (Index)" and d.get("added") == 1, "Diff „a.txt (Index)“ mit einer neuen Zeile")
    # zurück in die Sidebar: untracked gegen leeren Baum
    key("g", ctrl=True, shift=True)
    c = wait(lambda s: s["mode"] == "scm", "wieder Source Control")["changes"]
    rpc("click", list(row_center(c, row_index(c, "c.txt")))); settle(6)
    diff_state(lambda d: d.get("title") == "c.txt (Working Tree)" and d.get("added") == 1 and d.get("old_lines") == 0, "Diff „c.txt (Working Tree)“: eine Zeile neu, links leer")
    key("g", ctrl=True, shift=True)
    c = wait(lambda s: s["mode"] == "scm", "wieder Source Control")["changes"]
    rpc("click", list(row_center(c, row_index(c, "b.txt")))); settle(6)
    diff_state(lambda d: d.get("title") == "b.txt (Working Tree)" and d.get("removed") == 1, "Diff „b.txt (Working Tree)“: eine Zeile entfernt")


def step_unstage_discard():
    print("--- 3. Unstage und Discard mit Rückfrage")
    key("g", ctrl=True, shift=True)
    c = wait(lambda s: s["mode"] == "scm", "Source Control")["changes"]
    hover_action(c, row_index(c, "a.txt"), ACT_UNSTAGE)
    c = wait(lambda s: s["changes"]["groups"]["staged"] == [] and len(s["changes"]["groups"]["changes"]) == 3, "a.txt wieder unter Changes")["changes"]
    hover_action(c, row_index(c, "c.txt"), ACT_DISCARD)
    s = wait(lambda s: s["changes"]["dialog"] is not None, "Rückfrage erscheint")
    d = s["changes"]["dialog"]
    check(d["message"] == "Are you sure you want to DELETE the following untracked file: 'c.txt'?" and d["button"] == "Delete File", f"Text und Knopf wie VS Code: {d}")
    shot("e2e_scm_discard.ppm")
    key("enter")  # erster Knopf = Delete File
    wait(lambda s: s["changes"]["dialog"] is None and len(s["changes"]["groups"]["changes"]) == 2, "c.txt aus der Liste")
    check(not os.path.exists(os.path.join(FX, "c.txt")), "c.txt von der Platte gelöscht")
    # Discard der gelöschten Datei stellt sie wieder her
    c = ch()
    hover_action(c, row_index(c, "b.txt"), ACT_DISCARD)
    s = wait(lambda s: s["changes"]["dialog"] is not None, "Rückfrage für die gelöschte Datei")
    check(s["changes"]["dialog"]["button"] == "Restore File", "Knopf „Restore File“")
    key("enter")
    wait(lambda s: s["changes"]["dialog"] is None and [e["path"] for e in s["changes"]["groups"]["changes"]] == ["a.txt"], "b.txt wiederhergestellt")
    check(os.path.exists(os.path.join(FX, "b.txt")), "b.txt wieder auf der Platte")


def step_commit():
    print("--- 4. Commit: leere Nachricht, ohne Staged Changes, Erfolg")
    c = ch()
    click_center("sc_btn_commit_big")
    s = wait(lambda s: s["changes"]["validation"] == "Please provide a commit message", "leere Nachricht: Hinweis unter dem Feld")
    check(s["changes"]["focus"] == "commit_input", "Fokus im Feld")
    rpc("type_text", ["feat: drei"]); settle(4)
    s = wait(lambda s: s["changes"]["message"] == "feat: drei" and s["changes"]["validation"] is None, "Tippen füllt das Feld, Hinweis weg")
    key("enter", ctrl=True)
    s = wait(lambda s: s["changes"]["dialog"] is not None, "ohne Staged Changes: Rückfrage")
    check("no staged changes" in s["changes"]["dialog"]["message"] and s["changes"]["dialog"]["button"] == "Yes", f"Text wie VS Code smartCommit: {s['changes']['dialog']}")
    key("enter")
    s = wait(lambda s: s["changes"]["dialog"] is None and s["changes"]["groups"]["changes"] == [] and s["changes"]["message"] == "" and not s["changes"]["busy"],
             "Yes stagt alles und committet: Liste leer, Feld leer")
    wait(lambda s: len(s["commits"]) >= 2 and s["commits"][0]["subject"] == "feat: drei", "Graph zeigt den neuen Commit oben")
    check(git("log", "-1", "--format=%s") == "feat: drei", "git log bestätigt den Commit")
    check(git("status", "--porcelain") == "", "Arbeitsbaum sauber")
    # Nichts mehr zu committen: Hinweis, kein Dialog
    rpc("type_text", ["nochmal"]); settle(4)
    key("enter", ctrl=True)
    settle(6)
    check(ch()["dialog"] is None, "ohne Änderungen kein Dialog")
    ui = result_json("ui_state")
    check("no changes to commit" in ui.get("toast", ""), f"Toast: {ui.get('toast')!r}")
    shot("e2e_scm_committed.ppm")
    for _ in range(len("nochmal")):
        key("backspace")
    wait(lambda s: s["changes"]["message"] == "", "Backspace leert das Feld")


def step_publish_push_multiline():
    print("--- 4b. Publish Branch, mehrzeilige Nachricht, Push")
    s = wait(lambda s: s["changes"]["button"] == "Publish Branch" and s["changes"]["upstream"] == "", "sauber ohne Upstream: Knopf „Publish Branch“")
    click_center("sc_btn_commit_big")
    wait(lambda s: s["changes"]["upstream"] == "origin/main" and s["changes"]["ahead"] == 0 and s["changes"]["button"] == "Commit" and not s["changes"]["busy"],
         "Publish: push -u origin main, Upstream gesetzt, Knopf wieder Commit")
    check(remote_git("log", "-1", "--format=%s", "main") == "feat: drei", "Remote hat den Commit")
    # neue Änderung, mehrzeilige Nachricht: Enter = neue Zeile, Feld wächst
    write("a.txt", "eins\nzwei\ndrei\nvier\n")
    wait(lambda s: len(s["changes"]["groups"]["changes"]) == 1, "Änderung erkannt")
    click_center("sc_input_box")
    wait(lambda s: s["changes"]["focus"] == "commit_input", "Klick ins Feld")
    h1 = bounds("sc_input_box")["h"]
    rpc("type_text", ["feat: vier"]); key("enter"); rpc("type_text", ["Zweite Zeile"]); key("enter"); rpc("type_text", ["Dritte"]); settle(4)
    s = wait(lambda s: s["changes"]["message"] == "feat: vier\nZweite Zeile\nDritte" and s["changes"]["lines"] == 3, "drei Zeilen im Feld")
    h3 = bounds("sc_input_box")["h"]
    check(h3 > h1 + 30, f"Feld wächst mit den Zeilen ({h1:.0f} → {h3:.0f})")
    key("up"); key("home"); rpc("type_text", ["> "]); settle(4)
    wait(lambda s: s["changes"]["message"] == "feat: vier\n> Zweite Zeile\nDritte", "↑ und Pos1 bewegen in der Zeile, Tippen fügt dort ein")
    key("enter", ctrl=True)
    wait(lambda s: s["changes"]["dialog"] is not None, "Ctrl+Enter: Rückfrage ohne Staged Changes")
    key("enter")
    s = wait(lambda s: s["changes"]["dialog"] is None and s["changes"]["message"] == "" and s["changes"]["button"] == "Push 1↑", "committet: Knopf „Push 1↑“")
    check(git("log", "-1", "--format=%B").strip() == "feat: vier\n> Zweite Zeile\nDritte", "mehrzeilige Nachricht im Commit")
    click_center("sc_btn_commit_big")
    wait(lambda s: s["changes"]["ahead"] == 0 and s["changes"]["button"] == "Commit" and not s["changes"]["busy"], "Push: nichts mehr voraus")
    check(remote_git("log", "-1", "--format=%B", "main").strip() == "feat: vier\n> Zweite Zeile\nDritte", "Remote hat den Push mit der ganzen Nachricht")
    ui = result_json("ui_state")
    check("Pushed to origin/main" in ui.get("toast", ""), f"Toast: {ui.get('toast')!r}")
    shot("e2e_scm_pushed.ppm")


def step_keyboard():
    print("--- 5. Tastatur")
    write("a.txt", "eins\nzwei\ndrei\nvier\nfünf\n")
    write("d.txt", "neu\n")
    wait(lambda s: len(s["changes"]["groups"]["changes"]) == 2, "Dateiänderung lädt den Status nach")
    key("g", ctrl=True, shift=True)
    wait(lambda s: s["changes"]["focus"] == "commit_input", "Ctrl+Shift+G: Feld")
    key("tab")
    wait(lambda s: s["changes"]["focus"] == "changes", "Tab: Liste")
    key("down"); key("down")
    s = wait(lambda s: s["changes"]["selected"] == 1, "↓↓ wählt den ersten Eintrag")
    key("enter")
    diff_state(lambda d: d.get("title") == "a.txt (Working Tree)", "Enter öffnet den Diff des Eintrags")
    key("g", ctrl=True, shift=True)
    key("tab"); key("tab")
    wait(lambda s: s["changes"]["focus"] == "scm", "Tab Tab: Graph")
    key("home")
    wait(lambda s: s["selected"] == 0, "Home wählt im Graphen")
    key("escape")
    wait(lambda s: s["changes"]["focus"] == "none", "Escape gibt den Fokus ab")
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
        # open_project wie der Dialog: Explorer, Watcher, Branch und git status folgen dem Repo
        check(rpc("open_project", [FX]) == "ok", "Fixture-Repo als Projektordner")
        settle(20)
        for step in (step_show, step_stage_and_diffs, step_unstage_discard, step_commit, step_publish_push_multiline, step_keyboard):
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
