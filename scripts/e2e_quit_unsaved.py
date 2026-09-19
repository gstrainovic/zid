#!/usr/bin/env python3
"""Headless-E2E: Fenster schließen mit ungespeicherten Änderungen fragt nach.

`request_quit` stellt den Schließen-Knopf des Fensters nach (wio `.close`).
1. Keine Änderung → zid beendet sich sofort.
2. Geänderte Datei → Dialog „Unsaved Changes“, zid läuft weiter; Cancel lässt alles, wie es ist.
3. Don't Save → zid beendet sich, Datei unverändert.
4. Save All → Datei gespeichert, zid beendet sich.
Aufruf: python3 scripts/e2e_quit_unsaved.py
"""
import os, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e2e_open_folder import ROOT, rpc, wait_port, settle, start_zid, stop_zid, check, click_center  # noqa: E402
from e2e_shortcuts import ui_state  # noqa: E402

FIX = os.path.join(ROOT, "tmp", "quit_e2e", "a.txt")
ORIGINAL = "original\n"


def fresh_fixture():
    os.makedirs(os.path.dirname(FIX), exist_ok=True)
    with open(FIX, "w") as f:
        f.write(ORIGINAL)


def start(name):
    log = open(os.path.join(ROOT, "tmp", f"e2e_quit_{name}.log"), "w")
    proc = start_zid(["--headless", "--ai=off"], log)
    wait_port(proc)
    settle(20)
    return proc, log


def open_and_edit():
    rpc("open_file", [FIX]); settle(30)
    rpc("type_text", ["X"]); settle(10)
    s = ui_state()
    check(any(t["path"] == FIX and t["modified"] for t in s["tabs"]), "Datei ist geändert")


def exited(proc, timeout=5):
    try:
        proc.wait(timeout=timeout)
        return True
    except subprocess.TimeoutExpired:
        return False


def content():
    with open(FIX) as f:
        return f.read()


def main():
    print("--- 1. Ohne Änderung beendet request_quit sofort")
    fresh_fixture()
    proc, log = start("clean")
    try:
        rpc("open_file", [FIX]); settle(30)
        rpc("request_quit")
        check(exited(proc), "zid hat sich beendet")
    finally:
        if proc.poll() is None:
            stop_zid(proc)
        log.close()

    print("--- 2./3. Geänderte Datei: Dialog, Cancel, dann Don't Save")
    fresh_fixture()
    proc, log = start("discard")
    try:
        open_and_edit()
        rpc("request_quit"); settle(10)
        check(ui_state()["dialog"] == "Unsaved Changes", f"Dialog offen: {ui_state()['dialog']!r}")
        check(not exited(proc, 1), "zid läuft weiter, solange der Dialog offen ist")
        click_center("Cancel"); settle(10)
        check(ui_state()["dialog"] is None, "Cancel schließt den Dialog")
        check(not exited(proc, 1), "zid läuft nach Cancel weiter")
        check(content() == ORIGINAL, "Datei unverändert nach Cancel")
        rpc("request_quit"); settle(10)
        click_center("Don't Save")
        check(exited(proc), "Don't Save beendet zid")
        check(content() == ORIGINAL, "Datei unverändert nach Don't Save")
    finally:
        if proc.poll() is None:
            stop_zid(proc)
        log.close()

    print("--- 4. Save All speichert und beendet")
    fresh_fixture()
    proc, log = start("save")
    try:
        open_and_edit()
        rpc("request_quit"); settle(10)
        click_center("Save All")
        check(exited(proc), "Save All beendet zid")
        check("X" in content(), f"Datei gespeichert: {content()!r}")
    finally:
        if proc.poll() is None:
            stop_zid(proc)
        log.close()
    print("ALL PASSED")


if __name__ == "__main__":
    main()
