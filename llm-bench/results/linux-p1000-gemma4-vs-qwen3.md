# Nachtrag Linux i7-8850H / Quadro P1000 — gemma4-E2B gegen Qwen3-4B auf b10524

Lauf vom 17.09.2026, gleiche Maschine wie `linux-i7-8850H-gpu-und-neue-modelle.md`.
Anlass: die Windows-Messung (`windows-i5-13500T-gemma4-vs-qwen3.md`) hatte gemma4-E2B
auf CPU als schneller bei gleicher Werkzeugwahl gezeigt; offen war, ob das Q4_0-Modell
in die 4 GB der P1000 passt und dort ebenfalls vorn liegt. Beides ja.

## Das Ergebnis vorweg

| Modell | gültiges JSON | richtiges Werkzeug | tg64 | pp128 | erstes Delta (Chat) | `e2e_ai_tools` |
|---|---|---|---|---|---|---|
| Qwen3-4B-2507 Q4_K_M | 10/10 (Runde 2) | **10/10** | 19.28 ± 0.00 | 95.60 ± 0.01 | 14.9 s | grün |
| gemma4-E2B Q4_0 | 10/10 | **10/10** | **27.55 ± 0.02** | **211.41 ± 0.04** | **8.1 s** | grün |

Damit ist gemma4-E2B Q4_0 auf beiden Referenzmaschinen mindestens gleichauf und
durchweg schneller; seit diesem Lauf ist es das Standardmodell von zid auf allen
Plattformen (`src/ai/paths.zig`), die Windows-Sonderregel in `ui/mod.zig` ist weg.

## Engine und Modelle — die exakten Kennungen

| | |
|---|---|
| Engine | llama.cpp `engines/llama.cpp-vulkan`, Commit `9ee9fc04c136ef2ae729bfc60d18961b23c13ddf` (b10524) |
| Versionszeile | `version: 0.1.2-dev (build 19, commit 9ee9fc0)`, `built with GNU 15.3.1 for Linux x86_64`, `GGML_VULKAN=ON` |
| Gerät | `Vulkan1: Quadro P1000 (4342 MiB, 4264 MiB free)`, `-dev Vulkan1 -ngl 99`; Vulkan0 ist die Intel UHD 630 |
| Qwen3-4B-Instruct-2507-Q4_K_M | unsloth, 2 497 281 120 Bytes, sha256 `3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597` (bytegleich mit Windows) |
| gemma-4-E2B-it-Q4_0 | ggml-org, 2 841 481 184 Bytes, sha256 `8e30dff3ac4c8434c49a7036fa15564bdbb6044e42bf04550bf1a096ad7e6a52` (bytegleich mit Windows) |

`models/gemma-4-E2B-it-Q4_K_M.gguf` (3.1 GB, andere Quelle) lag schon auf dem Laptop,
wurde aber nicht gemessen: Standard ist die ggml-org-Datei, die auch Windows benutzt.

## Durchsatz (`llama-bench -p 128 -n 64 -ngl 99 -dev Vulkan1 -r 3`)

| Modell | llama-bench-Zeile | tg64 | pp128 |
|---|---|---|---|
| Qwen3-4B-2507 | `qwen3 4B Q4_K - Medium, 2.32 GiB, 4.02 B` | 19.28 ± 0.00 | 95.60 ± 0.01 |
| gemma4-E2B | `gemma4 E2B Q4_0, 2.63 GiB, 4.63 B` | 27.55 ± 0.02 | 211.41 ± 0.04 |

Qwen3 reproduziert die Runde-2-Zahl (19.27 / 95.6) exakt. gemma4 passt mit `-ngl 99`
vollständig in den VRAM; keine Vulkan-Zuweisungsfehler, kein Teil-Offload.

## Werkzeugwahl (`bench/agent_eval.py`)

Server: `llama-server --jinja -c 8192 --log-disable --chat-template-kwargs
{"enable_thinking":false} -dev Vulkan1 -ngl 99` (die zid-Argumente), `temperature=0`,
Prompt `TOOL_SYSTEM` aus `bench/tasks.py`.

**gemma4-E2B:** 10/10 gültig, 10/10 richtig, alle Antworten nacktes JSON. Aufgabe 10
liefert `"args": "npm install"` (String statt Objekt), zählt wie auf Windows als Treffer.
Qwen3 wurde hier nicht erneut gemessen (10/10 in Runde 2, gleiche Engine).

## Stichproben (`bench/probe.py`, gemma4-E2B, 20–25 tok/s)

- `1-tool-call-json`: sauberes JSON.
- `2-code-python`: Quicksort ohne Zaun, korrekt.
- `3-instruction-strict`: `BERN` (erwartet, 3 Token).
- `4-german`: **deutsche Antwort** auf die deutsche Frage (ein Satz zum DB-Index).
  Der Verdacht aus den Windows-Suiten (gemma4 antworte Englisch) bestätigte sich auf
  dieser Engine nicht; auch die Chat-Suite („Erkläre … Vulkan-Grafik-API") kam deutsch.
- `5-reasoning`: 15 (erwartet), Rechenweg in Markdown mit LaTeX-Inline.
- `6-agent-multistep`: drei Schritte read/edit/run, plausibel.

## zid-Suiten auf der P1000 (`LLAMA_MODEL_PATH=models/gemma-4-E2B-it-Q4_0.gguf`)

Beide Suiten grün, `usage:`-Zeilen aus dem zid-Log:

| | Qwen3-4B | gemma4-E2B |
|---|---|---|
| `e2e_ai_chat` erstes Delta (400-Wörter-Frage) | 14.9 s | 8.1 s (drei Läufe: 8.1 / 20.7 s; der lange Wert kam direkt nach Qwen3-Läufen, Modell nicht im Page-Cache) |
| `e2e_ai_chat` Warmup-Prompt | 1392 Token, 586 ms | 1474 Token, 6.3 s (kalt) / 421 ms (zweiter Lauf) |
| `e2e_ai_tools` Schritt 1 (toggle_explorer) | grün | 1.8 s, Antwort „Der Datei-Explorer wurde wieder geschlossen." |
| `e2e_ai_tools` Werkzeug-Prompt | 1297 Token | 1351 Token |
| `e2e_ai_tools` read_file / replace_text / Dialog / Ablehnung | 3.0 / 4.8 / 2.8 / 5.6 s | 2.5 / 3.8 / 1.8 / 2.5 s |

Nebenbefund: gemma4 nennt beim Wieder-Einblenden des Explorers die Aktion „geschlossen";
der Explorer war korrekt wieder da (Schritt prüft den UI-Zustand, nicht den Wortlaut).

## Vorher auf dieser Maschine nachgezogen (Änderungen vom 17.09.2026 auf Windows)

Mit Qwen3 als Standard, alle grün: `e2e_open_folder` (Python 3.14, `rmtree` mit `onexc`),
`e2e_ai_chat` (erstes Delta 14.9 s, unter dem 30-s-Limit), `e2e_ai_tools` (ruft
`command` mit `toggle_explorer`, `read_file` bei Aufgabe 6). Prompt-Token nach dem
Kürzen der Kommandoliste: 1297–1418 (Windows: 1362).
