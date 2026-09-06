#!/usr/bin/env python3
"""Werkzeugwahl-Test gegen einen laufenden llama-server.

    python3 bench/agent_eval.py --port 8080 --label BitNet-2B-4T

Zehn Aufgaben, fuenf definierte Werkzeuge, temperature=0. Gezaehlt werden zwei
Dinge getrennt:

  gueltiges JSON     - laesst sich die Antwort ueberhaupt parsen?
  richtiges Werkzeug - ist es das Werkzeug, das die Aufgabe verlangt?

Die Trennung ist der Punkt: ein Modell kann perfektes JSON schreiben und trotzdem
immer dasselbe falsche Werkzeug waehlen. Der erste Fehler faellt einem Parser
auf, der zweite laeuft still weiter.
"""

import argparse
import sys

from common import chat, extract_tool, shorten, wait_for_server
from tasks import AGENT_CASES, TOOL_SYSTEM


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--label", default="model")
    ap.add_argument(
        "--compact-system", action="store_true",
        help="Leerzeile nach der Einleitung im System-Prompt weglassen — "
             "sonst identischer Text. Auf BitNet halbiert das die Trefferquote, "
             "auf Llama-3.2-3B aendert es nichts.",
    )
    args = ap.parse_args()

    system = TOOL_SYSTEM
    if args.compact_system:
        system = system.replace("and no others:\n\nread_file", "and no others:\nread_file")

    if not wait_for_server(args.port):
        sys.exit(f"kein llama-server auf Port {args.port}")

    valid = correct = 0
    lines = []

    for index, (question, want) in enumerate(AGENT_CASES, start=1):
        try:
            text, _, _ = chat(
                args.port, system, question,
                max_tokens=120, temperature=0.0,
            )
        except Exception as exc:  # noqa: BLE001
            lines.append(f"  {index:2d}. REQUEST-FEHLER: {exc}")
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
    print(f"===== {args.label} :: Agent-Tauglichkeit ({total} Aufgaben, temp=0)")
    for line in lines:
        print(line)
    print()
    print(f"  gueltiges JSON:        {valid} / {total}")
    print(f"  richtiges Werkzeug:    {correct} / {total}")
    print()


if __name__ == "__main__":
    main()
