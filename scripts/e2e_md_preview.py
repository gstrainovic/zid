#!/usr/bin/env python3
"""Headless-E2E für die Markdown-Vorschau grosser Dateien.

Deckt ab: die Vorschau legt nur die sichtbaren Bloecke als Clay-Elemente an
(Virtualisierung), Scrollen zeigt andere Bloecke, und Clay meldet waehrend der
ganzen Sitzung keinen Fehler — weder `duplicate_id` noch die gesprengte
Elementgrenze, an der die Vorschau von AGENTS.md im Fenster abbrach.

Aufruf: python3 scripts/e2e_md_preview.py
"""
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e2e_open_folder import ROOT, rpc, result_json, wait_port, settle, check, shot  # noqa: E402
from e2e_shortcuts import ui_state  # noqa: E402

TARGET = "AGENTS.md"
LOG = os.path.join(ROOT, "tmp", "e2e_md_preview.log")


def open_preview(name):
    rpc("open_file", [os.path.join(ROOT, name)])
    settle(20)
    tabs = ui_state()["tabs"]
    idx = next(i for i, t in enumerate(tabs) if t["path"].endswith(name))
    b = result_json("tab_bounds", [idx])
    rpc("right_click", [b["x"] + b["w"] / 2, b["y"] + b["h"] / 2])
    settle(4)
    e = result_json("element_bounds", ["tab_menu_md_preview"])
    rpc("click", [e["x"] + e["w"] / 2, e["y"] + e["h"] / 2])
    settle(30)


def visible_blocks(limit=400):
    """Bloecke, die gerade eine Flaeche haben. element_bounds behaelt Daten
    verschwundener Elemente, deshalb zaehlt nur die Hoehe > 0 direkt nach dem
    ersten Aufbau als verlaesslich."""
    return [i for i in range(limit)
            if result_json("element_bounds_i", ["md_block", i])["found"]]


def step_virtualized():
    print("--- Vorschau legt nur den sichtbaren Ausschnitt an")
    open_preview(TARGET)
    hits = visible_blocks()
    check(len(hits) > 0, f"Bloecke im Layout: {len(hits)}")
    check(hits[0] == 0, "beginnt beim ersten Block")
    check(len(hits) < 60, f"nicht das ganze Dokument ({len(hits)} Bloecke)")
    top_last = hits[-1]
    shot("e2e_md_preview_top.ppm")

    for _ in range(30):
        rpc("scroll", [600, 400, -3])
    settle(30)
    after = visible_blocks()
    check(after[-1] > top_last, f"Scrollen erschliesst weitere Bloecke ({top_last} -> {after[-1]})")
    shot("e2e_md_preview_scrolled.ppm")


def step_no_clay_errors():
    print("--- Clay meldet keine Fehler")
    time.sleep(0.5)
    with open(LOG) as f:
        errors = [line.strip() for line in f if "Clay:" in line and "error" in line]
    for line in errors[:5]:
        print("   ", line)
    check(not errors, f"{len(errors)} Clay-Fehler im Log")


STEPS = [step_virtualized, step_no_clay_errors]


def main():
    log = open(LOG, "w")
    proc = subprocess.Popen(
        [os.path.join(ROOT, "zig-out", "bin", "zid"), "--headless", "--ai=off"],
        cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, bufsize=0,
    )
    try:
        wait_port(proc)
        settle(20)
        for step in STEPS:
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
