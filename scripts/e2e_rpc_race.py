#!/usr/bin/env python3
"""Headless-Stresstest: lesende RPCs gegen Buffer-Tausch im Main-Thread.

Eine große Datei wird immer wieder von außen neu geschrieben (der Watcher lädt sie per setText
neu), während ein zweiter Thread ohne Pause `editor_state` und `file_text` abfragt. Lasen diese
RPCs den Buffer im Server-Thread, stürzte zid mit „switch on corrupt value“ in
`Buffer.walk_const` ab (zufällig in e2e_editor.py).
Aufruf: python3 scripts/e2e_rpc_race.py
"""
import os, sys, threading, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e2e_open_folder import ROOT, rpc, result_json, wait_port, settle, check, start_zid, stop_zid  # noqa: E402

FIX = os.path.join(ROOT, "tmp", "e2e_rpc_race", "big.txt")
ROUNDS = 60


def write(i):
    with open(FIX, "w") as f:
        for n in range(4000):
            f.write(f"runde {i} zeile {n} " + "x" * 40 + "\n")


def main():
    os.makedirs(os.path.dirname(FIX), exist_ok=True)
    write(0)
    log = open(os.path.join(ROOT, "tmp", "e2e_rpc_race.log"), "w")
    proc = start_zid(["--headless", "--ai=off"], log)
    stop = threading.Event()
    errors = []

    def poll():
        while not stop.is_set():
            try:
                result_json("editor_state")
                result_json("file_text", [FIX])
            except Exception as e:  # Verbindung weg = zid abgestürzt
                errors.append(repr(e))
                return

    try:
        wait_port(proc); settle(20)
        rpc("open_file", [FIX]); settle(30)
        t = threading.Thread(target=poll)
        t.start()
        for i in range(1, ROUNDS + 1):
            write(i)
            time.sleep(0.12)
            if proc.poll() is not None:
                break
        stop.set()
        t.join(timeout=10)
        check(proc.poll() is None, f"zid läuft nach {ROUNDS} Neuladungen unter Dauerabfrage")
        check(not errors, f"keine abgebrochene Abfrage ({errors[:1]})")
        print("ALL PASSED")
    finally:
        stop.set()
        if proc.poll() is None:
            stop_zid(proc)
        log.close()


if __name__ == "__main__":
    main()
