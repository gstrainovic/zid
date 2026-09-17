# Offene Punkte

## Linux: geänderte E2E-Suiten gegenlaufen lassen

Der Windows-Lauf vom 17.09.2026 ist komplett grün (22 Suiten). Seit dem `.exe`-Fix in
`src/ai/paths.zig` läuft zid dort wie auf dem Laptop mit llama-server + Qwen3 (CPU).
Auf Linux noch nicht nachgezogen:

- `scripts/e2e_open_folder.py`: `rmtree` mit `onexc` (braucht Python ≥ 3.12), stdout auf UTF-8.
- `scripts/e2e_ai_chat.py`: erstes Delta darf auf CPU 90 s dauern (GPU weiter 30 s).
- `scripts/e2e_ai_tools.py`: Schritt 1 akzeptiert `toggle_explorer` als Werkzeugname,
  Schritt 6 akzeptiert eine Ablehnung ohne Werkzeugaufruf, Fixture-Pfad per `normpath`.
- `src/ai/agent.zig`: `reasoning_effort: "none"` nur für Ollama; llama-server bekommt es nicht.

## Werkzeug-Prompt verkleinern

Das `command`-Werkzeug listet alle 106 Kommandos mit Label und Kürzel; auf CPU kostet
die Prompt-Auswertung ~45 s vor dem ersten Delta (~2200 Token bei ~50 tok/s). Die
Kürzel braucht das Modell nicht. Vorher `bench/agent_eval.py` und `e2e_ai_tools` als
Massstab, siehe `llm-bench/results/windows-i5-13500T-gemma4-vs-qwen3.md`.

## gemma4 als Alternative (Entscheidung des Projektinhabers)

Auf b10524 mit `enable_thinking=false` trifft gemma4-E2B 10/10 wie Qwen3 und ist auf
dieser CPU rund die Hälfte schneller (18.2 gegen 11.9 tok/s). Offen: Verhalten mit
nativen `tools` über llama-server (im E2E über Ollama rief es Enum-Werte als Werkzeug auf).
