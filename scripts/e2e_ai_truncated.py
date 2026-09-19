#!/usr/bin/env python3
"""Headless-E2E: eine Antwort, die ans Ende des Kontextfensters läuft, wird als abgeschnitten
markiert (llama-server `finish_reason: "length"`), statt still aufzuhören.

Das Modell soll eine 12-KB-Datei vollständig wiedergeben: Prompt (~5000 Token) plus Antwort
füllen die 8192 Token. Braucht das KI-Backend (llama-server + gemma4-E2B), dauert ~3–4 min.
Aufruf: python3 scripts/e2e_ai_truncated.py
"""
import os, re, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e2e_open_folder import ROOT, rpc, settle, check  # noqa: E402
from e2e_ai_chat import wait_for, start, stop, send  # noqa: E402
from e2e_ai_read_limits import make_fixture  # noqa: E402


def main():
    rel, _, _, _ = make_fixture(12000)
    proc, log = start([], "e2e_ai_truncated.log")
    try:
        st, _ = wait_for(lambda s: s["status"] in ("ready", "failed", "model_missing", "none"), 120, "Agent-Warmup")
        check(st["status"] == "ready", f"Agent bereit ({st['title']})")
        rpc("open_chat"); settle(10)
        send(f"Lies {rel} und gib den Inhalt vollständig und unverändert wieder, Zeile für Zeile.")
        st, dt = wait_for(lambda s: not s["loading"] and not s["pending_tools"], 900, "Antwort")
        answer = st["messages"][-1]["content"]
        with open(os.path.join(ROOT, "tmp", "e2e_ai_truncated.log"), encoding="utf-8", errors="replace") as f:
            usage = [(int(p), int(c)) for p, c in re.findall(r"usage: prompt_tokens=(\d+) completion_tokens=(\d+)", f.read())]
        full = [u for u in usage if u[0] + u[1] >= 8192]
        check(full, f"eine Antwort hat das Kontextfenster gefüllt ({usage})")
        check("abgeschnitten" in answer[-200:], f"Antwort ist als abgeschnitten markiert: …{answer[-120:]!r}")
        print(f"ALL PASSED ({dt:.0f}s)")
    finally:
        stop(proc, log)


if __name__ == "__main__":
    main()
