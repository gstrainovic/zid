# Offene Punkte

## Linux: geänderte Suiten und Prompt gegenlaufen lassen

Seit 17.09.2026 auf Windows geändert, auf dem Fedora-Laptop (P1000) noch nicht nachgezogen:

- `scripts/e2e_open_folder.py` (`rmtree` mit `onexc`, braucht Python ≥ 3.12; stdout UTF-8),
  `scripts/e2e_ai_chat.py` (erstes Delta auf CPU 90 s), `scripts/e2e_ai_tools.py`
  (akzeptiert `toggle_explorer` als Werkzeugname und Ablehnung ohne Aufruf, `normpath`).
- `command`-Werkzeug ohne Kommandoliste im Text; llama-server mit
  `--chat-template-kwargs {"enable_thinking":false}`. Erwartung: erstes Delta auf der GPU
  deutlich unter 30 s, `e2e_ai_tools` weiter 7/7.

## Standardmodell: gemma4-E2B statt Qwen3-4B?

Auf dem i5-13500T (CPU) ist gemma4-E2B Q4_0 mit Thinking aus in allen drei Messungen
mindestens gleichauf (Werkzeugwahl 10/10, `e2e_ai_tools` 7/7) und durchweg schneller
(18.2 gegen 11.9 tok/s, Suite 62 gegen 132 s). Vor einem Wechsel auf dem Laptop messen, ob
das Modell in die 4 GB der P1000 passt. Entscheidung des Projektinhabers
(`llm-bench/CLAUDE.md` nennt Qwen3 als Pflicht).
