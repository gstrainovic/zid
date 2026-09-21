---
name: llm-local
description: >
  Lokales LLM in zid: KI-Chat über llama-server, Selbsteinrichtung von Engine und
  Modell, Engine- und Modellwahl, gepinnte Engines unter engines/, Messregeln aus
  llm-bench/.
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
kommen Engine und Modell aus dem Datenverzeichnis, das zid sich selbst einrichtet
(`src/ai/selfsetup.zig`: Knopf im Chat, llama.cpp `b11062` und das Modell von ggml-org
nach `<AppData>/zid` bzw. `~/.local/share/zid`). `LLAMA_SERVER_PATH` und
`LLAMA_MODEL_PATH` überschreiben beides.

**Warum gemma4-E2B Q4_0:** gleiche Werkzeugwahl wie Qwen3-4B-Instruct-2507 (10/10 in
`bench/agent_eval.py`, `e2e_ai_tools` grün), aber auf beiden Referenzmaschinen schneller:
27.6 gegen 19.3 tok/s auf der P1000 des Laptops (i7-8850H, 4 GB VRAM, Modell passt ganz
hinein), 18.2 gegen 11.9 tok/s auf der CPU des i5-13500T. Erstes Delta im Chat 8 s auf der
P1000 (Qwen3: 15 s). Antwortet auf deutsche Fragen deutsch (`bench/probe.py`, Chat-Suite).
Messreihen: `llm-bench/results/windows-i5-13500T-gemma4-vs-qwen3.md`,
`llm-bench/results/linux-p1000-gemma4-vs-qwen3.md`.

## llama-server starten

`agent.zig` prüft Engine- und Modelldatei, fragt `--list-devices` ab und wählt per
`device_select.zig` (unit-getestet) eine diskrete GPU mit mindestens 3 GB, sonst CPU
(`-dev none -t N`). **iGPUs werden übersprungen**, sie liefern laut Bench ein Drittel
der CPU-Leistung.

Argumente: `--jinja -c 8192 --log-disable --chat-template-kwargs {"enable_thinking":false}`,
auf GPU zusätzlich `-dev VulkanN -ngl 99`. Port 8080 (`default_llama_port`).
Ohne `-dev` landet das Modell womöglich auf der iGPU, ohne `--jinja` stimmt das
Qwen3-Chat-Template nicht. `enable_thinking=false` ist für Qwen3-Instruct wirkungslos,
schaltet aber bei gemma4 das Denken ab; `--reasoning-budget 0` tut das nicht (gemma4 denkt
dann im Antwortkanal weiter, 0/10 Werkzeugwahl).

Unter Windows heisst die Engine `llama-server.exe` (`paths.exe_suffix`); ohne Endung schlägt
der Existenztest fehl und zid hält die Engine für nicht vorhanden.

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

**Kontextfenster voll:** Prompt und Antwort teilen sich `-c 8192`. Läuft die Antwort ans
Ende, meldet llama-server `finish_reason: "length"` (`agent.finishReason`); `endStream`
liefert dann `error.ReplyTruncated`. Der Worker zeigt den Teiltext mit „*(Antwort
abgeschnitten: Kontextfenster voll.)*“, ein abgeschnittener Werkzeugaufruf wird nie
ausgeführt (unvollständiges JSON), ohne Text erscheint eine Fehlermeldung. Kein
`max_tokens`: das würde lange `write_file`-Inhalte kappen. E2E
`python3 scripts/e2e_ai_truncated.py` (12 KB wiedergeben lassen, ~3 min).

`AgentStatus` (`none`, `initializing`, `ready`, `failed`) ist der echte
Verbindungszustand: Statuspunkt, Kopfzeile (`agentTitle`: Modell · Gerät) und
`sendMessage` hängen daran. Warmup schickt „ping" mit `max_tokens = 1`, ohne Limit
dauert der Start minutenlang.

Fehlen Engine oder Modell, lädt der Chat sie auf Knopfdruck selbst nach; synchron wird
nie geladen, das blockierte den Start minutenlang (`selfsetup.zig` arbeitet im eigenen
Thread, der Fortschritt kommt aus der Grösse der `.part`-Datei).

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
python3 scripts/e2e_ai_read_limits.py       # read_file 4–40 KB: richtig?, Dauer, Prompt-Token (JSON in tmp/)
python3 scripts/e2e_ai_read_limits.py 12000:last 12000:last   # einzelne Fälle wiederholen
```

Antworten streuen (Temperatur 0.7): Vorher/Nachher nie an einem Lauf entscheiden, sondern
denselben Fall mehrmals wiederholen und die Prompt-Token vergleichen. Gleiche Token heißen
gleiche Eingabe, dann ist ein anderer Ausgang Zufall.

RPC `chat_state`: Status, Detail, Titel, loading/initializing/downloading,
`streaming_len`, alle Nachrichten.

## Engines und Modelle

**Layout:** `engines/` ist ignoriert, kein Submodul mehr (seit 20.09.2026). Ein lokaler
Build unter `engines/llama.cpp-vulkan/build/` (bisher b10524 = `9ee9fc0`, `GGML_VULKAN=ON`,
derselbe Build für GPU und CPU) hat Vorrang; fehlt er, lädt die Selbsteinrichtung das
Release `b11062`. Wer lokal baut, klont llama.cpp selbst dorthin. `models/` hält alle GGUFs flach
(per `*.gguf` ignoriert, **nie committen**).

**BitNet ist nicht im Repo.** zid nutzt es nicht (braucht eine eigene gepinnte Engine ohne
Vulkan und einen Tokenizer-Override). Für Nachmessungen holt `llm-bench/setup/linux.sh`
die Engine gepinnt auf `01eb415` (Submodul `3rdparty/llama.cpp` auf `1f86f05` = b3962)
nach `engines/BitNet`, spielt `llm-bench/patches/bitnet-mad-const-y_col.patch` ein und lädt
`models/bitnet-b1.58-2B-4T/`.

**cmake brennt absolute Pfade ein.** Nach einem Umzug finden `llama-server` und
`llama-bench` ihre `libllama.so` nicht. `llm-bench/setup/fix-rpath.sh` schreibt die
RUNPATHs der Builds per patchelf auf `$ORIGIN`-relative Pfade um (Kopie patchen und
darüberschieben, weil ein laufender llama-server die Datei gemappt hält: „Text file
busy"). Nach jedem Neubau oder Verschieben erneut ausführen. Die Build-Verzeichnisse
selbst kann cmake nach einem Umzug nicht neu konfigurieren, ein Neubau muss von vorn
beginnen.

**`llm-bench/`** ist das frühere Repo `bitnet-colibri-bench` als `git subtree`.
`results/*.md` sind historische Protokolle und werden nicht angefasst.

## Messregeln

Die drei BitNet-Regeln gelten nur, wenn BitNet per `llm-bench/setup/linux.sh` wieder
aufgebaut ist.

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
- **`models/` hält nur das Standardmodell** gemma-4-E2B-it Q4_0 (ggml-org). Alle anderen
  Modelle der Messreihen sind gelöscht; ein erneuter Vergleich braucht den Download, Quelle und
  sha256 stehen in `llm-bench/results/` (Qwen3-4B-Instruct-2507: unsloth,
  `3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597`).
