#!/usr/bin/env python3
"""Headless-E2E: Repo eines anderen Benutzers („detected dubious ownership“).

git verweigert seit 2.35.2 Repos, die nicht dem aktuellen Benutzer gehören (Netzlaufwerk,
anderes Konto). zid fragt dann wie VS Code nach und trägt bei Ja den von git vorgeschlagenen
Wert in `safe.directory` ein.

Ohne fremden Besitzer nachgestellt: GIT_TEST_ASSUME_DIFFERENT_OWNER=1 lässt git jedes Repo
als fremd behandeln, safe.directory gilt trotzdem. GIT_CONFIG_GLOBAL zeigt auf eine Datei
im Fixture, die globale git-Config des Benutzers bleibt unberührt.
Prüft:
  1. Start im Fixture: Dialog „Unsafe Git Repository“, Branch leer
  2. Enter (Trust Repository): safe.directory steht in der Fixture-Config, Branch und
     Changes kommen, Toast bestätigt
  3. Neues fremdes Repo per open_project, Escape: kein zweiter Dialog nach einer
     Dateiänderung (die Rückfrage kommt je Repo einmal)
Aufruf: python3 scripts/e2e_unsafe_repo.py
"""
import os, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e2e_open_folder import ROOT, ZID, rpc, result_json, wait_port, settle, check, rmtree, isolated_env, stop_zid  # noqa: E402
from e2e_shortcuts import key  # noqa: E402

BASE = os.path.join(ROOT, "tmp", "e2e_unsafe_repo")
FX = os.path.join(BASE, "work")
OTHER = os.path.join(BASE, "other")
GLOBAL = os.path.join(BASE, "gitconfig")
LOG = os.path.join(ROOT, "tmp", "e2e_unsafe_repo.log")


def make_repo(path):
    os.makedirs(path)
    env = dict(os.environ, GIT_CONFIG_GLOBAL=GLOBAL, GIT_AUTHOR_NAME="Ada", GIT_AUTHOR_EMAIL="ada@example.com",
               GIT_COMMITTER_NAME="Ada", GIT_COMMITTER_EMAIL="ada@example.com")
    for args in (["init", "-q", "-b", "main"], ["commit", "-q", "--allow-empty", "-m", "init"]):
        subprocess.run(["git", *args], cwd=path, check=True, env=env, capture_output=True)
    with open(os.path.join(path, "neu.txt"), "w") as f:
        f.write("neu\n")


def wait(cond, what, timeout=15):
    t0 = time.time()
    while time.time() - t0 < timeout:
        if cond():
            return True
        time.sleep(0.2)
    check(False, what)


def ui():
    return result_json("ui_state")


def changes():
    return result_json("scm_state")["changes"]


def safe_dirs():
    if not os.path.exists(GLOBAL):
        return []
    r = subprocess.run(["git", "config", "--file", GLOBAL, "--get-all", "safe.directory"], capture_output=True, text=True)
    return r.stdout.split()


def main():
    rmtree(BASE)
    make_repo(FX)
    make_repo(OTHER)
    env = isolated_env("e2e_unsafe_repo")
    env.update(GIT_TEST_ASSUME_DIFFERENT_OWNER="1", GIT_CONFIG_GLOBAL=GLOBAL)
    log = open(LOG, "w")
    build = subprocess.run(["zig", "build"], cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
    check(build.returncode == 0, "zig build")
    # cwd = Fixture: zid nimmt das Arbeitsverzeichnis als Projekt, wie `zid` im Terminal
    proc = subprocess.Popen([ZID, "--headless", "--ai=off"], cwd=FX, stdout=log, stderr=subprocess.STDOUT, env=env)
    try:
        wait_port(proc)
        wait(lambda: ui()["dialog"] == "Unsafe Git Repository", "Dialog „Unsafe Git Repository“ beim Start")
        # zid läuft im Fixture und schreibt den Screenshot nach <cwd>/tmp (legt es nicht an)
        os.makedirs(os.path.join(FX, "tmp"), exist_ok=True)
        for _ in range(2):
            rpc("screenshot")
            settle(10)
        os.replace(os.path.join(FX, "tmp", "vulkan-screenshot.ppm"), os.path.join(ROOT, "tmp", "e2e_unsafe_repo_dialog.ppm"))
        check(changes()["branch"] == "", "Branch leer, solange das Repo nicht freigegeben ist")
        check(safe_dirs() == [], "safe.directory noch leer")

        key("enter")
        wait(lambda: len(safe_dirs()) == 1, "safe.directory eingetragen")
        print("     safe.directory =", safe_dirs()[0])
        wait(lambda: ui()["dialog"] is None, "Dialog geschlossen")
        wait(lambda: changes()["branch"] == "main", "Branch nach dem Freigeben geladen")
        wait(lambda: any(r.get("path", "").endswith("neu.txt") for r in changes().get("rows", [])) or "neu.txt" in str(changes()),
             "Changes zeigen neu.txt")

        check(rpc("open_project", [OTHER]) == "ok", "zweites fremdes Repo öffnen")
        wait(lambda: ui()["dialog"] == "Unsafe Git Repository", "Dialog für das zweite Repo")
        key("escape")
        wait(lambda: ui()["dialog"] is None, "Escape schließt den Dialog")
        with open(os.path.join(OTHER, "noch.txt"), "w") as f:
            f.write("x\n")
        time.sleep(2)  # Watcher + git-status-Debounce
        check(ui()["dialog"] is None, "nach einer Dateiänderung keine zweite Rückfrage")
        check(len(safe_dirs()) == 1, "abgelehntes Repo nicht eingetragen")
        print("ALL PASSED")
    finally:
        stop_zid(proc)
        log.close()


if __name__ == "__main__":
    main()
