#!/usr/bin/env python3
"""Headless-E2E: Beenden bricht einen laufenden, langsamen git-Aufruf ab.
Fixture tmp/e2e_git_shutdown/: Repo mit `core.fsmonitor = sleep 30`. git status startet den
Hook über die Shell und hängt dann 30 s, wie ein git auf einem langsamen Netzlaufwerk; der
Hook ist ein Kindprozess von git, wie der echte git unter dem Windows-Launcher `bin\\git.exe`.
Prüft:
  1. zid beendet sich in unter 2 s (der Scheduler wartet höchstens 2 s auf seine Worker)
  2. kein Worker zurückgelassen („workers stuck“), keine Leck-Liste des Allocators
Vorher lief der git weiter, der Worker wurde zurückgelassen und der Allocator meldete dessen
Speicher als Leck (22.09.2026).
Aufruf: python3 scripts/e2e_git_shutdown.py (startet zig-out/bin/zid, vorher `zig build`)
"""
import os, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e2e_open_folder import ROOT, rpc, wait_port, settle, check, rmtree  # noqa: E402

FX = os.path.join(ROOT, "tmp", "e2e_git_shutdown")
XDG = os.path.join(ROOT, "tmp", "xdg")
XDG_CONFIG = os.path.join(ROOT, "tmp", "xdg-config-git-shutdown")
LOG = os.path.join(ROOT, "tmp", "e2e_git_shutdown.log")


def git(*args):
    subprocess.run(["git", *args], cwd=FX, check=True, capture_output=True)


def setup_fixture():
    rmtree(FX)
    os.makedirs(FX)
    git("init", "-q", "-b", "main")
    with open(os.path.join(FX, "a.txt"), "w") as f:
        f.write("eins\n")
    git("config", "core.fsmonitor", "sleep 30; exit 1")


def main():
    setup_fixture()
    log = open(LOG, "w")
    env = dict(os.environ, XDG_DATA_HOME=XDG, XDG_CONFIG_HOME=XDG_CONFIG)
    exe = os.path.join(ROOT, "zig-out", "bin", "zid.exe" if os.name == "nt" else "zid")
    proc = subprocess.Popen([exe, "--headless", "--ai=off"], cwd=ROOT, stdout=log,
                            stderr=subprocess.STDOUT, env=env)
    try:
        wait_port(proc)
        settle(10)
        check(rpc("open_project", [FX]) == "ok", "Fixture-Repo als Projektordner")
        # git status hängt jetzt im Hook
        time.sleep(1.5)
        t0 = time.time()
        try:
            rpc("shutdown")  # die Verbindung endet ohne Antwort
        except Exception:
            pass
        proc.wait(timeout=40)
        took = time.time() - t0
    finally:
        if proc.poll() is None:
            proc.kill()
        log.close()
    text = open(LOG, encoding="utf-8", errors="replace").read()
    check(took < 2.0, f"Beenden in unter 2 s ({took:.1f} s)")
    check("workers stuck" not in text, "kein Worker zurückgelassen")
    check("leaked" not in text, "keine Leck-Liste")
    check(proc.returncode == 0, f"Exit-Code 0 ({proc.returncode})")
    print("ALL PASSED")


if __name__ == "__main__":
    main()
