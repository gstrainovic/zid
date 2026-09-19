#!/usr/bin/env python3
"""Headless-E2E: lange Textstücke werden gezeichnet, nicht still verworfen.

Markdown-Vorschau mit einem Codeblock, dessen JSON-String 3000 Zeichen hat (ein Token).
`shapeTextInto` lieferte über 2048 Bytes leer zurück: gemessen, aber nicht gezeichnet.
`ui_state` zählt verworfene Textstücke (`text_runs_dropped`) und Clay-Fehler (`clay_errors`).
Aufruf: python3 scripts/e2e_long_runs.py
"""
import json, os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e2e_open_folder import ROOT, rpc, wait_port, settle, check, start_zid, stop_zid, shot  # noqa: E402
from e2e_shortcuts import ui_state  # noqa: E402
from e2e_md_preview import open_preview  # noqa: E402

REL = "tmp/e2e_long_runs/long.md"


def main():
    path = os.path.join(ROOT, REL)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    # Ein einziger JSON-String: der Highlighter liefert ihn als ein Token, also ein Textstück
    line = json.dumps({"blob": "a" * 3000})
    with open(path, "w") as f:
        f.write("# Lange Zeile\n\n```json\n" + line + "\n```\n\nText danach.\n")
    log = open(os.path.join(ROOT, "tmp", "e2e_long_runs.log"), "w")
    proc = start_zid(["--headless", "--ai=off"], log)
    try:
        wait_port(proc); settle(20)
        open_preview(REL)
        shot("e2e_long_runs.ppm")  # headless zeichnet nur beim Screenshot
        s = ui_state()
        check("text_runs_dropped" in s, "ui_state meldet verworfene Textstücke")
        check(s["text_runs_dropped"] == 0, f"kein Textstück verworfen (ist {s['text_runs_dropped']})")
        check(s["clay_errors"] == 0, f"keine Clay-Fehler (ist {s['clay_errors']})")
        print("ALL PASSED")
    finally:
        if proc.poll() is None:
            stop_zid(proc)
        log.close()


if __name__ == "__main__":
    main()
