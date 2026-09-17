# Nachtrag Windows i5-13500T — gemma4-E2B gegen Qwen3-4B auf b10524

Lauf vom 17.09.2026, gleiche Maschine wie `windows-i5-13500T.md`. Anlass: der
Windows-E2E-Lauf von zid lief gegen `gemma4:e2b` über Ollama und brauchte dort
drei Lockerungen (Thinking abschalten, Enum-Wert als Werkzeugname, Ablehnung ohne
Werkzeugaufruf). Auftrag des Projektinhabers: gemma4 auf derselben Engine wie
Qwen3 messen, statt aus dem Ollama-Verhalten zu schliessen.

## Das Ergebnis vorweg

| Modell | Server-Argumente | gültiges JSON | richtiges Werkzeug | tg64 | pp128 | Dauer 10 Aufgaben |
|---|---|---|---|---|---|---|
| Qwen3-4B-2507 Q4_K_M | — | 10/10 | **10/10** | 11.92 ± 0.30 | 81.8 ± 0.3 | 21.2 s |
| gemma4-E2B Q4_0 | `--chat-template-kwargs {"enable_thinking":false}` | 10/10 | **10/10** | **18.17 ± 0.27** | **120.3 ± 11.6** | **15.4 s** |
| gemma4-E2B Q4_0 | (Thinking an, Vorgabe) | 8/10 | 8/10 | | | 56.3 s |
| gemma4-E2B Q4_0 | `--reasoning-budget 0` | 0/10 | 0/10 | | | 50.9 s |

Drei Sätze Fazit:

1. **Mit abgeschaltetem Thinking ist gemma4-E2B auf dieser CPU gleichauf bei der
   Werkzeugwahl und rund die Hälfte schneller** als Qwen3-4B (18.2 gegen 11.9 tok/s
   Generierung, 120 gegen 82 tok/s Prompt). Die Q4_0-Datei ist mit 2.63 GiB etwas
   grösser, rechnet aber dank der Per-Layer-Embeddings von E2B wie ein 2B-Modell.
2. **Thinking kostet gemma4 die Punkte, nicht die Fähigkeit.** Mit Thinking an
   sind zwei Antworten leer: das Denken frisst die 120 Token des Tests auf. Die
   acht übrigen sind korrekt, sechs davon in Markdown-Zäunen (wie Gemma-3 in
   Runde 2 des Laptops).
3. **`--reasoning-budget 0` ist für gemma4 der falsche Schalter.** Das Modell
   narrativiert dann im Antwortkanal („The user wants to … I should use the
   `read_file` tool …") und kommt in 120 Token nie beim JSON an. Wirksam ist nur
   `enable_thinking=false` im Chat-Template.

## Engine und Modelle — die exakten Kennungen

| | |
|---|---|
| Engine | llama.cpp `engines/llama.cpp-vulkan`, Commit `9ee9fc04c136ef2ae729bfc60d18961b23c13ddf` (b10524) |
| Versionszeile | `version: 0.1.2-dev (build 10524, commit 9ee9fc04c)`, `built with Clang 22.1.7 for Windows AMD64` |
| CMake | Ninja, Release, clang/clang++ (`mingw-mstorsjo-llvm-msvcrt`), `-DGGML_VULKAN=OFF -DLLAMA_CURL=OFF -DLLAMA_BUILD_SERVER=ON -DLLAMA_BUILD_TOOLS=ON`, dazu `-D_WIN32_WINNT=0x0A00` in C- und CXX-Flags (siehe unten) |
| Qwen3-4B-Instruct-2507-Q4_K_M | unsloth, 2 497 281 120 Bytes, sha256 `3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597` — **bytegleich** mit dem Laptop-Lauf |
| gemma-4-E2B-it-Q4_0 | ggml-org, 2 841 481 184 Bytes, sha256 `8e30dff3ac4c8434c49a7036fa15564bdbb6044e42bf04550bf1a096ad7e6a52` |

ggml-org bietet für gemma-4-E2B nur Q4_0, Q8_0 und BF16 an, kein Q4_K_M; die
Quantisierung ist damit nicht identisch mit Qwen3. Das Ollama-Modell `gemma4:e2b`
(7.2 GB laut `ollama list`) ist eine andere Datei und war nicht Gegenstand
dieser Messung.

## Maschine

Wie in `windows-i5-13500T.md`: i5-13500T (6P+8E, 20 Threads), 16 GB RAM, Intel
UHD 770 (nicht benutzt, CPU-Build ohne Vulkan). Windows 11 Pro 10.0.26200.

## Durchsatz

`llama-bench -p 128 -n 64 -t 12 -r 3`, mmap an (der `PrefetchVirtualMemory`-Fehler
der b3962-Engine trat mit b10524 und Clang 22 nicht auf).

| Modell | llama-bench-Zeile | tg64 | pp128 |
|---|---|---|---|
| Qwen3-4B-2507 | `qwen3 4B Q4_K - Medium, 2.32 GiB, 4.02 B` | 11.92 ± 0.30 | 81.77 ± 0.32 |
| gemma4-E2B | `gemma4 E2B Q4_0, 2.63 GiB, 4.63 B` | 18.17 ± 0.27 | 120.29 ± 11.56 |

Zum Vergleich der Laptop (i7-8850H, CPU, `-t 8`): Qwen3 9.86 / 30.8.

## Werkzeugwahl (`bench/agent_eval.py`)

Server: `llama-server --jinja -c 4096 -t 12 --log-disable`, `temperature=0`,
`max_tokens=120`, Prompt `TOOL_SYSTEM` aus `bench/tasks.py` (unverändert).

**Qwen3-4B:** 10/10, alle Antworten nacktes JSON ohne Zaun, wie auf dem Laptop.

**gemma4-E2B, `enable_thinking=false`:** 10/10, ebenfalls nacktes JSON. Einziger
inhaltlicher Unterschied zu Qwen3: bei Aufgabe 9 sucht gemma4 nach
`parse_args`, Qwen3 nach `def parse_args`; beides zählt.

**gemma4-E2B, Thinking an:** Aufgaben 4 und 9 (beide `search`) enden mit leerem
Inhalt — das Denken verbraucht das Token-Budget, die Antwort kommt nicht mehr.
Die acht anderen Antworten stehen in ```` ```json ```` -Zäunen (6/8), der
Auswerter entfernt sie.

**gemma4-E2B, `--reasoning-budget 0`:** alle zehn Antworten beginnen mit „The
user wants to …", kein JSON innerhalb von 120 Token. Der Schalter beendet das
Thinking-Segment, das Modell setzt dieselbe Überlegung im Antwortkanal fort.

### Was das für zid heisst

- Über **Ollama** ist das Äquivalent `reasoning_effort: "none"` im Request; zid
  sendet es seit 17.09.2026 (`src/ai/agent.zig`). `think: false` wirkt auf Ollamas
  OpenAI-Endpunkt nicht.
- Über **llama-server** müsste zid `--chat-template-kwargs {"enable_thinking":false}`
  beim Start mitgeben oder `chat_template_kwargs` im Request senden, sobald ein
  Thinking-Modell als Standard gewählt wird. Für Qwen3-4B-Instruct ist beides
  wirkungslos, aber harmlos.
- Dieser Test misst Werkzeugwahl über einen JSON-Prompt, nicht über native
  `tools`. Im E2E-Lauf von zid mit nativen Tool-Calls (über Ollama) rief gemma4
  den Enum-Wert `toggle_explorer` direkt als Werkzeug auf statt `command` mit
  `name`; zid fängt das seither ab (`ai_tools.commandFromToolName`). Ob das an
  Ollamas Tool-Template oder am Modell liegt, ist offen — mit llama-server und
  nativen `tools` nicht gemessen.

### Nebenbefunde beim Umstellen von zid auf diesen Build

- **zid fand die Engine unter Windows nie.** `ai_paths.engine_rel` endete auf
  `llama-server`, die Datei heisst `llama-server.exe`; der Existenztest schlug
  fehl und zid fiel still auf Ollama zurück. Seit 17.09.2026 hängt `paths.zig`
  unter Windows `.exe` an. Damit läuft zid hier wie auf dem Laptop mit
  llama-server + Qwen3, und `e2e_ai_tools` besteht ohne die gemma4-Lockerungen
  (ruft `command`, `read_file` bei Aufgabe 6).
- **Das erste Streaming-Delta kommt auf CPU nach 45 s.** Vorher steht die
  Prompt-Auswertung: System-Prompt plus Werkzeug-JSON mit allen 106 Kommandos
  samt Label und Kürzel, geschätzt ~2200 Token bei ~50 tok/s (pp2048, Threads
  8/12/14 ohne Unterschied: 48.3 / 51.3 / 49.5). `e2e_ai_chat` wartet auf CPU
  jetzt 90 s statt 30. Der Prompt selbst ist der Hebel: die Kürzel im
  Werkzeugtext braucht das Modell nicht.

## Windows-Eigenheiten dieses Laufs

- **cpp-httplib verlangt Windows 10** (`#error … Please use Windows 10 or later`,
  dazu `CreateFile2` unbekannt). MinGW setzt `_WIN32_WINNT` auf einen älteren
  Wert. Abhilfe: `-DCMAKE_C_FLAGS=-D_WIN32_WINNT=0x0A00
  -DCMAKE_CXX_FLAGS=-D_WIN32_WINNT=0x0A00` beim Konfigurieren.
- Downloads von huggingface.co und `ollama pull` scheitern in der
  Claude-Code-Sandbox mit DNS-Fehlern (`no such host`); ausserhalb der Sandbox
  laufen sie.
- Der Bench-Läufer war ein Wegwerf-Skript (Server starten, `/health` abwarten,
  `agent_eval.py`, Server beenden); der Ablauf entspricht `setup/serve-coding-agent.sh`
  ohne dessen GPU-Zweig.
