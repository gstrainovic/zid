# Offene Punkte

## Linux: geänderte Suiten gegenlaufen lassen

Seit 17.09.2026 auf Windows geändert, auf dem Fedora-Laptop (i7-8850H, P1000) noch nicht
nachgezogen:

- `scripts/e2e_open_folder.py` (`rmtree` mit `onexc`, braucht Python ≥ 3.12; stdout UTF-8),
  `scripts/e2e_ai_chat.py` (erstes Delta auf CPU 90 s), `scripts/e2e_ai_tools.py`
  (akzeptiert `toggle_explorer` als Werkzeugname und Ablehnung ohne Aufruf, `normpath`).
- `command`-Werkzeug ohne Kommandoliste im Text, llama-server mit
  `--chat-template-kwargs {"enable_thinking":false}`. Erwartung mit Qwen3 auf der P1000:
  erstes Delta deutlich unter 30 s, `e2e_ai_tools` weiter 7/7; `usage:`-Zeile im zid-Log
  sollte ~1360 Prompt-Token zeigen.

## Linux: gemma4-E2B gegen Qwen3-4B auf der P1000

Auf Windows/CPU ist gemma4-E2B Q4_0 Standard (`ai_paths.model_rel_windows_cpu`), gemessen
in `llm-bench/results/windows-i5-13500T-gemma4-vs-qwen3.md`. Auf dem Laptop fehlt alles;
nötig, bevor Linux umgestellt wird:

1. `models/gemma-4-E2B-it-Q4_0.gguf` holen (ggml-org, sha256
   `8e30dff3ac4c8434c49a7036fa15564bdbb6044e42bf04550bf1a096ad7e6a52`, 2 841 481 184 Bytes).
2. Passt es in die 4 GB der P1000? `llama-bench -m … -p 128 -n 64 -ngl 99 -dev Vulkan1 -r 3`,
   daneben Qwen3 mit denselben Argumenten (Referenz: 19.27 tg64 / 95.6 pp128). Wenn die
   Vulkan-Zuweisung scheitert oder tg64 unter Qwen3 liegt, bleibt Qwen3 auf Linux.
3. `bench/agent_eval.py` mit `--chat-template-kwargs {"enable_thinking":false}` auf GPU
   (Werkzeugwahl ist Modelleigenschaft, sollte 10/10 bleiben).
4. `LLAMA_MODEL_PATH=models/gemma-4-E2B-it-Q4_0.gguf python3 scripts/e2e_ai_tools.py` und
   `e2e_ai_chat.py` auf GPU: 7/7, erstes Delta unter 30 s.
5. `bench/probe.py` für die Stichproben (Deutsch, Codeblock, „exactly one word"): gemma4
   antwortete in den Windows-Suiten mehrfach Englisch auf deutsche Fragen; das prüft kein Test.
6. Fällt alles positiv aus: `model_rel` in `src/ai/paths.zig` auf gemma4 stellen und die
   Windows-Sonderregel (`windows_cpu` in `ui/mod.zig`) entfernen; `llm-bench/CLAUDE.md`
   („Qwen3 Pflicht") nachziehen.

Auf dem Windows-PC sind Qwen3-GGUF und Ollama seit 17.09.2026 gelöscht; ein erneuter
Vergleich dort braucht den Qwen3-Download (unsloth, sha256 `3605803b…`).
