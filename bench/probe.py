#!/usr/bin/env python3
"""Fähigkeitsstichproben gegen einen laufenden llama-server.

    python3 bench/probe.py --port 8080 --label BitNet-2B-4T

Erwartet den OpenAI-kompatiblen Endpunkt, den llama-server mitbringt. Die
Antworten werden ausgegeben, nicht bewertet — ausser bei den zwei Aufgaben mit
eindeutiger Loesung (Hauptstadt, Wechselgeld).
"""

import argparse
import sys
import time

from common import chat, wait_for_server
from tasks import PROBE_EXPECTED, PROBES


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--label", default="model")
    ap.add_argument("--max-tokens", type=int, default=300)
    args = ap.parse_args()

    if not wait_for_server(args.port):
        sys.exit(f"kein llama-server auf Port {args.port}")

    for probe in PROBES:
        started = time.monotonic()
        try:
            text, prompt_tokens, gen_tokens = chat(
                args.port, probe["system"], probe["user"],
                max_tokens=args.max_tokens,
            )
        except Exception as exc:  # noqa: BLE001 - Diagnoseausgabe genuegt hier
            print(f"===== {args.label} :: {probe['name']} | FEHLER: {exc}\n")
            continue
        elapsed = time.monotonic() - started

        tps = gen_tokens / elapsed if elapsed > 0 else 0.0
        head = (f"===== {args.label} :: {probe['name']} | "
                f"prompt={prompt_tokens} gen={gen_tokens} | "
                f"{elapsed:.1f}s | {tps:.2f} tok/s")

        expected = PROBE_EXPECTED.get(probe["name"])
        if expected is not None:
            hit = expected in text
            head += f" | erwartet '{expected}': {'ja' if hit else 'NEIN'}"

        print(head)
        print(text.strip())
        print()


if __name__ == "__main__":
    main()
