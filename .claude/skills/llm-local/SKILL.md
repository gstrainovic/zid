---
name: llm-local
description: >
  Lokales LLM in zid: KI-Chat über llama-server/Ollama, Engine- und Modellwahl,
  gepinnte Engines unter engines/, Messregeln aus llm-bench/.
  Use when working on the AI chat, `src/ai/*`, llama-server startup, model or device
  selection, streaming replies, `engines/`, `models/`, `llm-bench/`, or when
  benchmarking or comparing local models.
---

# Lokales LLM in zid

## Backend-Wahl beim Start

`UI.init`, sofern nicht `--ai=off`. Standard ist der llama.cpp-Vulkan-Build
`engines/llama.cpp-vulkan/build/bin/llama-server` mit
`models/gemma-4-E2B-it-Q4_0.gguf` (ggml-org, sha256 `8e30dff3…`), beides relativ zur
Repo-Wurzel (`src/ai/paths.zig`, unit-getestet: Wurzel aus `<repo>/zig-out/bin` der
ausführbaren Datei, sonst das Arbeitsverzeichnis; nichts über `$HOME`). Fehlt der Build,
Fallback auf Ollama mit `gemma4:e2b`. `LLAMA_SERVER_PATH` (Pfad oder `ollama`) und
`LLAMA_MODEL_PATH` überschreiben.

**Warum gemma4-E2B Q4_0:** gleiche Werkzeugwahl wie Qwen3-4B-Instruct-2507 (10/10 in
`bench/agent_eval.py`, `e2e_ai_tools` grün), aber auf beiden Referenzmaschinen schneller:
27.6 gegen 19.3 tok/s auf der P1000 des Laptops (i7-8850H, 4 GB VRAM, Modell passt ganz
hinein), 18.2 gegen 11.9 tok/s auf der CPU des i5-13500T. Erstes Delta im Chat 8 s auf der
P1000 (Qwen3: 15 s). Antwortet auf deutsche Fragen deutsch (`bench/probe.py`, Chat-Suite).
Messreihen: `llm-bench/results/windows-i5-13500T-gemma4-vs-qwen3.md`,
`llm-bench/results/linux-p1000-gemma4-vs-qwen3.md`. Das Ollama-Modell `gemma4:e2b`
(5,2 GB, 4,4 tok/s auf dem Laptop) ist eine andere Datei und nur Fallback.

## llama-server starten

`agent.zig` prüft Engine- und Modelldatei, fragt `--list-devices` ab und wählt per
`device_select.zig` (unit-getestet) eine diskrete GPU mit mindestens 3 GB, sonst CPU
(`-dev none -t N`). **iGPUs werden übersprungen**, sie liefern laut Bench ein Drittel
der CPU-Leistung.

Argumente: `--jinja -c 8192 --log-disable --chat-template-kwargs {"enable_thinking":false}`,
auf GPU zusätzlich `-dev VulkanN -ngl 99`. Port 8080 (`default_llama_port`), Ollama bleibt
auf 11434. Ohne `-dev` landet das Modell womöglich auf der iGPU, ohne `--jinja` stimmt das
Qwen3-Chat-Template nicht. `enable_thinking=false` ist für Qwen3-Instruct wirkungslos,
schaltet aber bei gemma4 das Denken ab; `--reasoning-budget 0` tut das nicht (gemma4 denkt
dann im Antwortkanal weiter, 0/10 Werkzeugwahl). Über Ollama entspricht dem
`reasoning_effort: "none"` im Request (`buildPayload`); `think: false` wirkt dort nicht.

Unter Windows heisst die Engine `llama-server.exe` (`paths.exe_suffix`); ohne Endung schlug
der Existenztest fehl und zid nahm still Ollama.

**Werkzeug-Prompt klein halten.** Das `command`-Werkzeug trägt die 106 Kommandos nur als
Enum; eine Liste mit Label und Kürzel im Text kostete 1000 Token und auf CPU 20 s vor dem
ersten Delta (2392 → 1362 Token, 45 → 22 s auf dem i5-13500T) und liess gemma4
`open_folder` statt `command` wählen. Jeder Stream fordert `stream_options.include_usage`
an und loggt `usage: prompt_tokens=… prompt_ms=…`; vor Prompt-Änderungen vorher/nachher
ablesen. Messreihe: `llm-bench/results/windows-i5-13500T-gemma4-vs-qwen3.md`.

## Streaming und Zustand

`streamChatCompletion` (SSE, `stream: true`) schiebt jedes Delta per
`Scheduler.pushResult` als `ai_chat_delta`; der Chat zeigt die wachsende Antwort
(`stream_text`, Markdown wird bei neuem Text neu gebaut). Die finale Antwort kommt als
`ai_chat_reply`. **Escape** setzt `cancel_flag`, der Worker beendet den Stream
(`ai_chat_cancelled`), der Teiltext bleibt mit „(abgebrochen)".

`AgentStatus` (`none`, `model_missing`, `initializing`, `ready`, `failed`) ist der echte
Verbindungszustand: Statuspunkt, Kopfzeile (`agentTitle`: Modell · Gerät) und
`sendMessage` hängen daran. Warmup schickt „ping" mit `max_tokens = 1`, ohne Limit
dauert der Start minutenlang.

Fehlt das Ollama-Modell, wird **nicht** synchron gepullt; der Chat zeigt „Pull model
with Ollama". Lokales GGUF registrieren:

```bash
printf 'FROM /abs/pfad/model.gguf\n' > Modelfile && ollama create NAME -f Modelfile
```

## Chat-Eingabe ist der CodeEditor

`AIChatState.input_editor` mit `show_gutter = false`, `show_minimap = false`,
`compact_menu = true` und `word_wrap = true`. Enter sendet, Shift+Enter fügt eine Zeile
ein (`dispatchAction(.InsertNewline)`; die Keymap kennt Enter nur ohne Modifier). Das UI
reicht Shift/Ctrl/Alt an den Chat-Editor weiter, `applyThemeToEditors` färbt ihn mit.
Editor-Neuerungen gelten damit automatisch auch im Chat.

**Keine Unit-Tests für `ai_chat.zig`:** die Datei importiert CodeEditor und UI, also
kein eigenes Test-Root möglich. Logik dort klein halten.

**Codeblock-Antworten und zigdown:** endet der Text genau mit ``` ohne Zeilenumbruch,
erzeugt `handleLineCode` einen leeren Tag und greift auf `tag[0]` zu (Absturz, Submodul
nicht gepatcht). `chat_markdown.finishForParser` hängt deshalb immer einen Zeilenumbruch
an und schließt einen offenen Zaun.

## Prüfen

```bash
python3 scripts/e2e_ai_chat.py              # Warmup, erstes Delta, Escape, kurze Antwort
python3 scripts/e2e_ai_chat.py --only-off   # nur der --ai=off-Pfad
```

RPC `chat_state`: Status, Detail, Titel, loading/initializing/downloading,
`streaming_len`, alle Nachrichten.

## Engines und Modelle

**Layout:** `engines/BitNet` (Submodul, gepinnt `01eb415`; dessen Submodul
`3rdparty/llama.cpp` auf `1f86f05` = b3962, `.gitmodules` mit `ignore = dirty`, weil
`src/ggml-bitnet-mad.cpp` den Patch `llm-bench/patches/bitnet-mad-const-y_col.patch`
trägt) und `engines/llama.cpp-vulkan` (Submodul `9ee9fc0` = b10524, Build mit
`GGML_VULKAN=ON`). Builds liegen unbeobachtet in `engines/*/build/`. `models/` hält alle
GGUFs flach (per `*.gguf` ignoriert, **nie committen**). In `engines/BitNet/models/`
zeigen zwei Symlinks auf `models/`, damit BitNets eigene Skripte laufen.

**cmake brennt absolute Pfade ein.** Nach einem Umzug finden `llama-server` und
`llama-bench` ihre `libllama.so` nicht. `llm-bench/setup/fix-rpath.sh` schreibt die
RUNPATHs beider Builds per patchelf auf `$ORIGIN`-relative Pfade um (Kopie patchen und
darüberschieben, weil ein laufender llama-server die Datei gemappt hält: „Text file
busy"). Nach jedem Neubau oder Verschieben erneut ausführen. Die Build-Verzeichnisse
selbst kann cmake nach einem Umzug nicht neu konfigurieren, ein Neubau muss von vorn
beginnen.

**`llm-bench/`** ist das frühere Repo `bitnet-colibri-bench` als `git subtree`.
`results/*.md` sind historische Protokolle und werden nicht angefasst.

## Messregeln

- **Die BitNet-Engine ist gepinnt, und das ist keine Vorsicht.** Der aktuelle Stand von
  microsoft/BitNet zeigt auf einen Fork-Branch, mit dem BitNet-b1.58-2B-4T unbrauchbar
  ist (Endlosschleife, Perplexity ×3,7, Werkzeugwahl 0/10) — bei unauffälligem
  Durchsatz. Vor jeder Messung:
  ```bash
  ./engines/BitNet/build/bin/llama-bench -m <i2_s.gguf> -p 8 -n 8 -r 1
  ```
  `I2_S - 2 bpw ternary` in der Modellspalte heißt brauchbar, `Q1_0` heißt nicht messen.
- **BitNet braucht `--override-kv tokenizer.ggml.pre=str:llama-bpe`** (dem GGUF fehlt
  das Feld; ohne Override zerfallen Werkzeugnamen, 8–9/10 wird zu 4/10). Nur für BitNet.
- **Feste Engine-Zuordnung:** BitNet i2_s nur auf der gepinnten BitNet-Engine (auf
  b10524 ist i2_s kaputt); Qwen3, Phi-4 und Gemma-3 nur auf b10524 (b3962 kennt die
  Architekturen nicht und hat kein taugliches Vulkan); Llama-3.2-3B läuft auf beiden und
  ist die Brücke. Zahlen nie ohne diese Verschiebung über die Engine-Grenze vergleichen.
- **Jede Zahl braucht drei Kennungen:** Engine-Commit, Submodul-Commit, Modell-sha256.
  Perplexity nur mit `llm-bench/bench/ppl-corpus.txt` bei `-c 512`.
- Entscheidungen des Projektinhabers und die Liste „nicht erneut aufrollen" stehen in
  `llm-bench/CLAUDE.md`.
- **Standardmodell des Chats** ist gemma-4-E2B-it Q4_0 (ggml-org). Qwen3-4B-Instruct-2507
  bleibt als Vergleichsmodell im Repo (gleiche Werkzeugwahl, langsamer); Llama-3.2-3B und
  das BitNet-Referenzmodell sind sinnvoll; die fünf reinen Bench-Modelle bleiben, bis
  der Projektinhaber entscheidet.
