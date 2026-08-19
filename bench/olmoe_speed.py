#!/usr/bin/env python3
"""Dekodier-Durchsatz der colibri-Engine im eingeschwungenen Zustand.

    python3 bench/olmoe_speed.py --engine ~/colibri/c/olmoe --snap ~/colibri/olmoe_merged

olmoe gibt im Chat-Modus keine tok/s aus, und der Referenzlauf misst nur zwoelf
Token bei kaltem Expert-Cache — beides taugt nicht zum Vergleich zwischen
Maschinen. Deshalb die Steigung: derselbe Prompt zweimal mit unterschiedlichem
MAX_NEW, die Differenz durch die Tokendifferenz. Der konstante Anteil (Laden,
Prefill, Cache-Aufwaermen) faellt dabei heraus.
"""

import argparse
import sys
import time

from olmoe_eval import run_once

PROMPT = ("Write a long detailed essay about the history of the Rhine river, "
          "at least 600 words.")


def measure(args, max_new):
    times = []
    for _ in range(args.repeats):
        started = time.monotonic()
        run_once(args.engine, args.snap, PROMPT, args.cache, args.bits,
                 max_new=max_new, temp=0.7, ctx=args.ctx)
        times.append(time.monotonic() - started)
    return min(times), times


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--engine", required=True)
    ap.add_argument("--snap", required=True)
    ap.add_argument("--cache", type=int, default=64)
    ap.add_argument("--bits", type=int, default=8)
    ap.add_argument("--ctx", type=int, default=2048)
    ap.add_argument("--low", type=int, default=40)
    ap.add_argument("--high", type=int, default=240)
    ap.add_argument("--repeats", type=int, default=2)
    args = ap.parse_args()

    if args.high <= args.low:
        sys.exit("--high muss groesser als --low sein")

    best_low, all_low = measure(args, args.low)
    print(f"MAX_NEW={args.low:<4}: {best_low:6.2f} s  "
          f"(bester von {args.repeats}: {[round(t, 2) for t in all_low]})")

    best_high, all_high = measure(args, args.high)
    print(f"MAX_NEW={args.high:<4}: {best_high:6.2f} s  "
          f"(bester von {args.repeats}: {[round(t, 2) for t in all_high]})")

    delta_tokens = args.high - args.low
    slope = (best_high - best_low) / delta_tokens
    if slope <= 0:
        sys.exit("negative Steigung — Modell hat vermutlich vor MAX_NEW gestoppt; "
                 "laengeren Prompt oder groesseres --high nehmen")

    print()
    print(f"Steady-State-Dekodierung: {1.0 / slope:.2f} tok/s "
          f"({slope * 1000:.1f} ms/Token)")


if __name__ == "__main__":
    main()
