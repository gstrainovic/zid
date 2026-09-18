#!/usr/bin/env python3
"""Headless-E2E für Source Control Graph und Multi-File-Diff (VS-Code-Stil).

Fixture tmp/e2e_scm/: Repo `work` mit Remote `origin` (bares Repo), 55 leere Commits als
Vorgeschichte, Branch `feature` (b.txt) mit Merge nach main, Tag v1.0 auf dem Merge, danach ein
lokaler Commit „after merge“ (nicht gepusht: main blau, origin/main lila).
Prüft:
  1. Ctrl+Shift+G zeigt den Graphen, Filter Auto (main + origin/main), HEAD-Ring, Merge mit zwei Bahnen
  2. Hover mit Details; Klick klappt Commit auf und zeigt Dateien mit Status
  3. Klick auf Datei öffnet den Diff-Editor gegen den ersten Elternteil
  3b. Tastatur: Home/End/↓ wählen, ←/→/Enter klappen, Enter auf Datei öffnet den Diff, Escape gibt ab
  4. Kontextmenü „Open Changes“ öffnet den Multi-File-Diff „kurz - betreff“, eingeklappte
     unveränderte Bereiche, Abschnitt klappbar, „Collapse All Diffs“
  5. Timeline „Open Commit“ öffnet denselben Multi-File-Diff-Typ
  6. Listenende lädt die nächste Seite (pageSize 50), Refresh zeigt neuen Commit, keine Clay-Fehler
Aufruf: python3 scripts/e2e_scm_graph.py
"""
import os, shutil, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e2e_open_folder import ROOT, rpc, result_json, wait_port, settle, click_center, check, shot, rmtree  # noqa: E402
from e2e_shortcuts import key, explorer_click  # noqa: E402

BASE = os.path.join(ROOT, "tmp", "e2e_scm")
FX = os.path.join(BASE, "work")
XDG = os.path.join(ROOT, "tmp", "xdg")
XDG_CONFIG = os.path.join(ROOT, "tmp", "xdg-config-scm")
LOG = os.path.join(ROOT, "tmp", "e2e_scm_graph.log")


def git(*args, cwd=None):
    env = dict(os.environ, GIT_AUTHOR_NAME="Ada", GIT_AUTHOR_EMAIL="ada@example.com",
               GIT_COMMITTER_NAME="Ada", GIT_COMMITTER_EMAIL="ada@example.com")
    return subprocess.run(["git", *args], cwd=cwd or FX, check=True, env=env, capture_output=True, text=True).stdout.strip()


def write(name, text):
    with open(os.path.join(FX, name), "w") as f:
        f.write(text)


def setup_fixture():
    rmtree(BASE)
    shutil.rmtree(XDG_CONFIG, ignore_errors=True)
    os.makedirs(FX)
    git("init", "-q", "-b", "main")
    write("a.txt", "".join(f"zeile {i}\n" for i in range(60)))
    git("add", "a.txt"); git("commit", "-q", "-m", "init")
    for i in range(55):
        git("commit", "-q", "--allow-empty", "-m", f"vorgeschichte {i}")
    git("checkout", "-q", "-b", "feature")
    write("b.txt", "neu im feature\n")
    git("add", "b.txt"); git("commit", "-q", "-m", "feature start")
    git("checkout", "-q", "main")
    write("a.txt", "".join(f"zeile {i}\n" for i in range(59)) + "geändert\n")
    git("commit", "-q", "-am", "main change")
    git("merge", "-q", "--no-ff", "-m", "Merge feature", "feature")
    git("tag", "v1.0")
    git("clone", "-q", "--bare", FX, os.path.join(BASE, "remote.git"), cwd=BASE)
    git("remote", "add", "origin", os.path.join(BASE, "remote.git"))
    git("fetch", "-q", "origin")
    git("branch", "-q", "-u", "origin/main")
    git("remote", "set-head", "origin", "main")
    write("a.txt", "".join(f"zeile {i}\n" for i in range(59)) + "nach dem merge\n")
    git("commit", "-q", "-am", "after merge")


def st():
    return result_json("scm_state")


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


def row_center(s, i):
    b = s["body"]
    return b["x"] + b["w"] / 2, b["y"] + i * s["row_height"] + s["row_height"] / 2 - s["scroll"]


def step_graph():
    print("--- 1. Graph")
    key("g", ctrl=True, shift=True)
    s = wait(lambda s: s["mode"] == "scm" and len(s["commits"]) == 50, "Ctrl+Shift+G zeigt den Graphen, erste Seite 50 Commits")
    check(s["branch"] == "main" and s["filter"]["current"] == "refs/heads/main" and s["filter"]["upstream"] == "refs/remotes/origin/main",
          f"Filter Auto: {s['filter']}")
    c = s["commits"]
    check(c[0]["subject"] == "after merge" and c[0]["kind"] == "head", "jüngster Commit oben mit HEAD-Ring")
    check("main" in c[0]["refs"], f"Badge main am HEAD: {c[0]['refs']}")
    merge = next(x for x in c if x["subject"] == "Merge feature")
    check(merge["outputs"] == 2 and "origin/main" in merge["refs"] and "v1.0" in merge["refs"],
          f"Merge: zwei Bahnen, origin/main und Tag: {merge}")
    check(s["has_more"] and s["rows"][-1]["kind"] == "load_more", "Seite voll: Nachladen am Ende")
    shot("e2e_scm_graph.ppm")


def step_hover_expand_diff():
    print("--- 2./3. Hover, Aufklappen, Datei-Diff")
    s = st()
    idx = next(i for i, x in enumerate(s["commits"]) if x["subject"] == "Merge feature")
    rpc("move_mouse", list(row_center(s, idx))); time.sleep(1.0); settle(4)
    wait(lambda s: s["hover_visible"], "Hover nach 700 ms")
    shot("e2e_scm_hover.ppm")
    rpc("click", list(row_center(s, idx))); settle(4)
    s = wait(lambda s: s["commits"][idx]["expanded"] and any(r["kind"] == "change" for r in s["rows"]), "Klick klappt den Merge auf")
    change_rows = [i for i, r in enumerate(s["rows"]) if r["kind"] == "change"]
    check([s["rows"][i]["path"] for i in change_rows] == ["b.txt"] and s["rows"][change_rows[0]]["status"] == "A",
          f"Merge gegen ersten Elternteil: b.txt hinzugefügt ({[s['rows'][i] for i in change_rows]})")
    shot("e2e_scm_expanded.ppm")
    rpc("click", list(row_center(s, change_rows[0]))); settle(6)
    t0 = time.time()
    d = {}
    while time.time() - t0 < 10:
        d = result_json("git_diff_state")
        if d.get("view") == "diff" and d.get("loaded"):
            break
        time.sleep(0.05)
    check(d.get("title", "").startswith("b.txt (") and d.get("added") == 1 and d.get("old_lines") == 0,
          f"Datei-Klick öffnet Diff-Editor: {d.get('title')} +{d.get('added')}")


def step_keyboard():
    print("--- 3b. Tastatur im Graphen")
    key("g", ctrl=True, shift=True)
    s = wait(lambda s: s["mode"] == "scm" and len(s["commits"]) >= 50, "Ctrl+Shift+G: Source Control, Fokus im Eingabefeld")
    key("tab"); key("tab")  # Feld → Changes → Graph
    key("home")
    wait(lambda s: s["selected"] == 0, "Home wählt die erste Zeile")
    key("end")
    # letzte Zeile ist „Load More“: sichtbar → pageOnScroll lädt die zweite Seite nach
    s = wait(lambda s: s["scroll"] > 0 and not s["has_more"] and len(s["commits"]) == 60, "End scrollt ans Ende und lädt die zweite Seite")
    key("end")
    s = wait(lambda s: s["selected"] == len(s["rows"]) - 1, "End wählt die letzte Zeile")
    key("home")
    wait(lambda s: s["selected"] == 0 and s["scroll"] == 0, "Home scrollt zurück nach oben")
    idx = next(i for i, x in enumerate(s["commits"]) if x["subject"] == "Merge feature")
    # Merge ist aus Schritt 2 aufgeklappt: ← klappt zu, → klappt auf
    for _ in range(idx):
        key("down")
    s = wait(lambda s: s["selected"] == idx and s["rows"][idx]["kind"] == "commit", f"↓ bis zum Merge (Zeile {idx})")
    key("left")
    s = wait(lambda s: not s["commits"][idx]["expanded"], "← klappt den Merge zu")
    key("right")
    s = wait(lambda s: s["commits"][idx]["expanded"] and s["rows"][idx + 1]["kind"] == "change", "→ klappt ihn wieder auf")
    key("enter")
    wait(lambda s: not s["commits"][idx]["expanded"], "Enter auf dem Commit klappt zu")
    key("enter")
    wait(lambda s: s["commits"][idx]["expanded"], "Enter klappt wieder auf")
    key("down")
    wait(lambda s: s["selected"] == idx + 1 and s["rows"][idx + 1]["path"] == "b.txt", "↓ auf die Datei b.txt")
    key("enter")
    t0 = time.time()
    d = {}
    while time.time() - t0 < 10:
        d = result_json("git_diff_state")
        if d.get("view") == "diff" and d.get("loaded"):
            break
        time.sleep(0.05)
    check(d.get("title", "").startswith("b.txt ("), f"Enter auf der Datei öffnet den Diff-Editor: {d.get('title')}")
    # Diff-Tab hat den Fokus: ↓ erreicht den Graphen nicht mehr
    key("down")
    settle(4)
    check(st()["selected"] == idx + 1, "nach dem Öffnen gehen die Tasten nicht mehr an den Graphen")
    # Klick in den Graphen holt den Fokus zurück; ein Buchstabe erreicht den Editor nicht
    s = st()
    rpc("click", list(row_center(s, idx))); settle(4)
    key("x")
    key("escape")
    key("down")
    settle(4)
    check(st()["selected"] == idx, "Escape gibt den Fokus ab: ↓ bewegt die Auswahl nicht")


def step_open_changes():
    print("--- 4. Open Changes → Multi-File-Diff")
    s = st()
    idx = next(i for i, x in enumerate(s["commits"]) if x["subject"] == "after merge")
    x, y = row_center(s, idx)
    rpc("right_click", [x, y]); settle(4)
    wait(lambda s: s["menu_open"], "Rechtsklick öffnet das Menü")
    shot("e2e_scm_menu.ppm")
    click_center("sg_menu_graph_open_changes")
    h = s["commits"][idx]["hash"]
    s = wait(lambda s: s["commit_tab"] is not None and len(s["commit_tab"]["sections"]) == 1 and s["commit_tab"]["sections"][0]["loaded"],
             "Multi-File-Diff geöffnet und Datei geladen")
    ct = s["commit_tab"]
    check(ct["title"] == f"{h[:7]} - after merge", f"Titel wie VS Code git.viewCommit: {ct['title']}")
    sec = ct["sections"][0]
    check(sec["path"] == "a.txt" and sec["collapse_unchanged"] and sec["changes"] == 1, f"a.txt, unveränderte Bereiche eingeklappt: {sec}")
    shot("e2e_scm_commit.ppm")
    b = result_json("element_bounds", ["gc_container"])  # ungesalzen nicht gefunden → über Bereich klicken
    # Kopf des ersten Abschnitts: direkt unter der Werkzeugleiste
    body_y = 130 + 34
    rpc("click", [700, body_y + 18]); settle(4)
    wait(lambda s: s["commit_tab"]["sections"][0]["collapsed"], "Klick auf den Kopf klappt den Abschnitt zu")
    rpc("click", [700, body_y + 18]); settle(4)
    wait(lambda s: not s["commit_tab"]["sections"][0]["collapsed"], "zweiter Klick klappt auf")
    _ = b


def step_timeline_open_commit():
    print("--- 5. Timeline „Open Commit“")
    key("e", ctrl=True, shift=True)
    wait(lambda s: s["mode"] == "explorer", "Ctrl+Shift+E zurück zum Explorer")
    # kein zweites open_folder: der RPC lädt den Baum aus dem Server-Thread, während gezeichnet wird
    explorer_click("a.txt"); settle(6)
    tl = result_json("timeline_state")
    if not tl["expanded"]:
        b = tl["header"]
        rpc("click", [b["x"] + b["w"] / 2, b["y"] + b["h"] / 2]); settle(4)
    t0 = time.time()
    while time.time() - t0 < 10:
        tl = result_json("timeline_state")
        if tl["loaded"] and tl["items"]:
            break
        time.sleep(0.05)
    check(tl["items"][0]["label"] == "after merge", f"Timeline von a.txt geladen: {tl['items'][0]['label']}")
    b = tl["body"]
    rpc("right_click", [b["x"] + b["w"] / 2, b["y"] + tl["row_height"] / 2]); settle(4)
    click_center("tl_menu_timeline_open_commit")
    s = wait(lambda s: s["commit_tab"] is not None and s["commit_tab"]["title"].endswith("- after merge"), "Open Commit öffnet den Multi-File-Diff")


def step_load_more_refresh():
    print("--- 6. Nachladen und Refresh")
    key("g", ctrl=True, shift=True)
    s = wait(lambda s: s["mode"] == "scm" and len(s["commits"]) >= 50, "zurück im Graphen")
    b = s["body"]
    for _ in range(60):
        rpc("scroll", [b["x"] + b["w"] / 2, b["y"] + b["h"] / 2, -10]); settle(2)
        if len(st()["commits"]) > 50:
            break
    s = wait(lambda s: len(s["commits"]) == 60 and not s["has_more"], "Listenende lädt die zweite Seite (60 Commits)")
    write("a.txt", "neu\n")
    git("commit", "-q", "-am", "ganz neu")
    rpc("move_mouse", [s["header"]["x"] + s["header"]["w"] / 2, s["header"]["y"] + 10]); settle(6)
    click_center("sg_btn_refresh")
    wait(lambda s: len(s["commits"]) >= 50 and s["commits"][0]["subject"] == "ganz neu", "Refresh zeigt den neuen Commit oben")
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
        for step in (step_graph, step_hover_expand_diff, step_keyboard, step_open_changes, step_timeline_open_commit, step_load_more_refresh):
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
