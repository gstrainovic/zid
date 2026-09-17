#!/usr/bin/env python3
"""Headless-E2E: eine offene, ungeänderte Datei folgt Änderungen von außen.

Vier Wege, wie ein anderes Programm die Datei auf der Platte ändert; in allen muss der
Editor-Buffer den neuen Inhalt zeigen, ohne Neustart und ohne Dialog (Buffer unverändert):
1. In-place-Schreiben (open/truncate/write/close) im Projektbaum
2. Atomares Ersetzen (Schreiben nach .tmp, dann rename) — so schreiben viele Editoren
   und Werkzeuge
3. Datei liegt hinter einem Symlink-Ordner im Projekt, das Ziel liegt ebenfalls im Projekt;
   geöffnet über den Link-Pfad, geändert über den echten Pfad
4. Symlink-Ordner im Projekt, Ziel außerhalb des Projektbaums
Screenshots: tmp/e2e_extern_<fall>.ppm
Aufruf: python3 scripts/e2e_external_change.py
"""
import os, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e2e_open_folder import ROOT, rpc, result_json, wait_port, settle, check, shot, start_zid, stop_zid, rmtree  # noqa: E402

BASE = os.path.join(ROOT, "tmp", "e2e_extern")
REAL = os.path.join(BASE, "real")
LINK = os.path.join(BASE, "link")
OUTSIDE = os.path.join(tempfile.gettempdir(), "zid_e2e_extern_out")
LINK_OUT = os.path.join(BASE, "link_out")

OLD = "# Alt\n\nZeile aus dem Editor.\n"
NEW = "# Neu\n\nVon außen geschrieben.\n"


def write_inplace(path, text):
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def write_atomic(path, text):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, path)


def buffer_text(path):
    ft = result_json("file_text", [path])
    return ft["text"] if ft["open"] else None


def wait_reload(path, expected, timeout=3.0):
    t0 = time.time()
    while time.time() - t0 < timeout:
        if buffer_text(path) == expected:
            return time.time() - t0
        time.sleep(0.1)
    return None


def open_and_verify(path):
    rpc("open_file", [path])
    settle(20)
    check(buffer_text(path) == OLD, f"Buffer zeigt den alten Inhalt: {os.path.relpath(path, ROOT)}")
    check(not result_json("ui_state")["tabs"][-1]["modified"], "Tab gilt als ungeändert")


def case(name, open_path, write_path, writer):
    print(f"--- {name}")
    write_inplace(write_path, OLD)
    settle(20)
    open_and_verify(open_path)
    writer(write_path, NEW)
    dt = wait_reload(open_path, NEW)
    shot(f"e2e_extern_{name}.ppm")
    got = buffer_text(open_path)
    check(dt is not None, f"Buffer folgt der Änderung ({'%.1fs' % dt if dt is not None else 'nie'}; Buffer: {got!r})")
    check(result_json("ui_state")["dialog"] is None, "Kein Dialog (Buffer war ungeändert)")


def run_case(failures, *args):
    try:
        case(*args)
    except AssertionError as e:
        failures.append(str(e))


def main():
    rmtree(BASE)
    rmtree(OUTSIDE)
    os.makedirs(REAL)
    os.makedirs(OUTSIDE)
    os.symlink("real", LINK)
    os.symlink(OUTSIDE, LINK_OUT)
    log = open(os.path.join(ROOT, "tmp", "e2e_external_change.log"), "w")
    proc = start_zid(["--headless", "--ai=off"], log)
    try:
        wait_port(proc)
        settle(30)
        failures = []
        run_case(failures, "inplace", os.path.join(REAL, "a.md"), os.path.join(REAL, "a.md"), write_inplace)
        run_case(failures, "atomic", os.path.join(REAL, "b.md"), os.path.join(REAL, "b.md"), write_atomic)
        run_case(failures, "symlink", os.path.join(LINK, "c.md"), os.path.join(REAL, "c.md"), write_inplace)
        run_case(failures, "symlink_out", os.path.join(LINK_OUT, "d.md"), os.path.join(OUTSIDE, "d.md"), write_inplace)
        if failures:
            sys.exit(f"{len(failures)} Fall/Fälle rot: " + "; ".join(failures))
        print("ALL PASSED")
    finally:
        stop_zid(proc)
        log.close()


if __name__ == "__main__":
    main()
