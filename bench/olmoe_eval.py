#!/usr/bin/env python3
"""Dieselben Tests gegen colibris OLMoE-Engine.

    python3 bench/olmoe_eval.py --engine ~/colibri/c/olmoe --snap ~/colibri/olmoe_merged

olmoe hat keinen OpenAI-Endpunkt, nur den stdin-Chat (CHAT=1) und ein eigenes
Zeilenprotokoll (SERVE=1). Hier wird der stdin-Weg benutzt: je Aufgabe ein
Prozess. Das kostet pro Aufruf das Laden der residenten Gewichte (gut eine
Sekunde), verfaelscht die Qualitaetsmessung aber nicht.

Newlines im Prompt loesen im Chat-Modus sofort das Absenden aus, deshalb wird
jeder Prompt auf eine Zeile geglaettet.

  --mode agent    nur die 10 Werkzeugaufgaben (zaehlt aus)
  --mode probe    nur die 6 Stichproben (gibt aus)
  --mode both     beides (Vorgabe)
"""

import argparse
import os
import subprocess
import sys
import time

from common import extract_tool, shorten
from tasks import AGENT_CASES, PROBE_EXPECTED, PROBES, TOOL_SYSTEM

BANNER_PREFIXES = (
    "[OMP]", "[stop]", "olmoe chat", "== Streaming",
    "  type a message", "type a message", "resident weights",
)


def flatten(text):
    return " ".join(text.split())


def run_once(engine, snap, prompt, cache, bits, max_new, temp, ctx, timeout=1800):
    """Startet die Engine einmal und gibt die bereinigte Antwort zurueck."""
    env = dict(os.environ)
    env.update({
        "SNAP": snap,
        "CHAT": "1",
        "CTX": str(ctx),
        "MAX_NEW": str(max_new),
        "TEMP": str(temp),
        "NUCLEUS": "0.95",
    })
    proc = subprocess.run(
        [engine, str(cache), str(bits)],
        input=flatten(prompt) + "\n",
        env=env,
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    merged = proc.stdout + proc.stderr
    kept = [
        line for line in merged.splitlines()
        if not any(line.startswith(p) or p in line[:24] for p in BANNER_PREFIXES)
    ]
    body = "\n".join(kept)
    # Die Chat-Eingabeaufforderung steht am Zeilenanfang und gehoert nicht zur Antwort.
    body = "\n".join(
        line[2:] if line.startswith("> ") else (line[1:] if line.startswith(">") else line)
        for line in body.splitlines()
    )
    return body.strip()


def run_agent(args):
    valid = correct = 0
    lines = []
    for index, (question, want) in enumerate(AGENT_CASES, start=1):
        prompt = f"{TOOL_SYSTEM} Task: {question}"
        try:
            text = run_once(args.engine, args.snap, prompt, args.cache, args.bits,
                            max_new=120, temp=0, ctx=args.ctx)
        except subprocess.TimeoutExpired:
            lines.append(f"  {index:2d}. TIMEOUT")
            continue

        is_json, tool = extract_tool(text)
        if is_json:
            valid += 1
        hit = is_json and tool == want
        if hit:
            correct += 1

        mark = "OK  " if hit else ("TOOL" if is_json else "JSON")
        lines.append(
            f"  {index:2d}. [{mark}] erwartet={want:<10} "
            f"bekommen={(tool or '-'):<14} | {shorten(text)}"
        )

    total = len(AGENT_CASES)
    print(f"===== {args.label} :: Agent-Tauglichkeit ({total} Aufgaben, TEMP=0)")
    for line in lines:
        print(line)
    print()
    print(f"  gueltiges JSON:        {valid} / {total}")
    print(f"  richtiges Werkzeug:    {correct} / {total}")
    print()


def run_probe(args):
    for probe in PROBES:
        prompt = f"{probe['system']} {probe['user']}"
        started = time.monotonic()
        try:
            text = run_once(args.engine, args.snap, prompt, args.cache, args.bits,
                            max_new=args.max_new, temp=0.2, ctx=args.ctx)
        except subprocess.TimeoutExpired:
            print(f"===== {args.label} :: {probe['name']} | TIMEOUT\n")
            continue
        elapsed = time.monotonic() - started

        head = (f"===== {args.label} :: {probe['name']} | "
                f"{elapsed:.1f}s Wanduhr (inkl. Laden)")
        expected = PROBE_EXPECTED.get(probe["name"])
        if expected is not None:
            head += f" | erwartet '{expected}': {'ja' if expected in text else 'NEIN'}"
        print(head)
        print(text)
        print()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--engine", required=True, help="Pfad zur olmoe-Binaerdatei")
    ap.add_argument("--snap", required=True, help="konvertiertes Modellverzeichnis")
    ap.add_argument("--label", default="OLMoE-1B-7B(colibri)")
    ap.add_argument("--cache", type=int, default=64, help="Expert-Cache je Layer")
    ap.add_argument("--bits", type=int, default=8)
    ap.add_argument("--ctx", type=int, default=2048)
    ap.add_argument("--max-new", type=int, default=220)
    ap.add_argument("--mode", choices=("agent", "probe", "both"), default="both")
    args = ap.parse_args()

    if not os.path.exists(args.engine):
        sys.exit(f"Engine nicht gefunden: {args.engine}")
    if not os.path.isdir(args.snap):
        sys.exit(f"Modellverzeichnis nicht gefunden: {args.snap}")

    if args.mode in ("agent", "both"):
        run_agent(args)
    if args.mode in ("probe", "both"):
        run_probe(args)


if __name__ == "__main__":
    main()
