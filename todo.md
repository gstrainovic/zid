# Offene Punkte

## Linux: geänderte E2E-Suiten gegenlaufen lassen

Der Windows-Lauf vom 17.09.2026 ist komplett grün (22 Suiten, KI-Suiten gegen
`gemma4:e2b` über Ollama). Dabei geändert, auf Linux noch nicht nachgezogen:

- `scripts/e2e_open_folder.py`: `rmtree` mit `onexc` (braucht Python ≥ 3.12), stdout auf UTF-8.
- `scripts/e2e_ai_tools.py`: Schritt 1 akzeptiert `toggle_explorer` als Werkzeugname,
  Schritt 6 akzeptiert eine Ablehnung ohne Werkzeugaufruf, Fixture-Pfad per `normpath`.
- `src/ai/agent.zig`: `reasoning_effort: "none"` nur für Ollama — prüfen, dass llama-server
  mit Qwen3 unverändert läuft (Feld wird dort nicht gesendet).
