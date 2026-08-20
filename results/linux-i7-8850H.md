# Lauf auf Linux, i7-8850H

Gemessen am 19./20.08.2026. Gegenstück zu [`windows-i5-13500T.md`](windows-i5-13500T.md).

Dieser Lauf widerspricht dem Referenzlauf in einem Punkt, und zwar im
wichtigsten: **BitNet ist für Werkzeugwahl nicht schlecht.** Die 4/10 des
Windows-Laufs entstehen durch ein fehlendes Metadatenfeld in der
GGUF-Datei. Wird es gesetzt, trifft BitNet 9/10 — gleichauf mit
Llama-3.2-3B, bei 1.6-fachem Durchsatz und halber Dateigrösse.

Ausserdem: `setup/linux.sh` baut in seiner jetzigen Fassung eine Engine, mit der
BitNet überhaupt nicht benutzbar ist. Beides steht unten mit Belegen.

## Maschine

| | |
|---|---|
| CPU | Intel Core i7-8850H — 6 Kerne / 12 Threads, 2.6 GHz Basis, 4.3 GHz Turbo, Coffee Lake |
| Befehlssätze | AVX2, FMA, F16C — **kein** AVX-VNNI, **kein** AVX512 |
| RAM | 46 GB |
| GPU | Intel UHD 630 + NVIDIA Quadro P1000 Mobile — **ungenutzt**, alles auf der CPU |
| Platte | 246 GB NVMe |
| OS | Fedora 43, Kernel 7.1.8-100.fc43.x86_64 |

Toolchain: clang 21.1.8, CMake 3.31.11, Ninja 1.13.1, Python 3.14.3.

**Engine: BitNet `01eb415` mit llama.cpp-Submodul `1f86f058` (b3639).** Das ist
*nicht*, was `setup/linux.sh` heute klont — siehe „Die Engine muss gepinnt
werden". Alle Zahlen unten stammen von dieser Engine.

## Ergebnis in drei Zeilen

| Modell | Generierung | richtiges Werkzeug (10 Aufgaben) |
|---|---|---|
| BitNet-b1.58-2B-4T i2_s, Pre-Tokenizer korrigiert | **22.4 tok/s** | **9/10** |
| Llama-3.2-3B Q4_K_M (gleiche Engine) | 13.6 tok/s | **9/10** |
| OLMoE-1B-7B int8 via colibri | 11.9 tok/s | 4/10 |

Auf dieser Maschine ist BitNet dem gewöhnlichen 4-Bit-Modell in jeder Hinsicht
überlegen: gleiche Trefferquote, 1.65-fache Generierung, 4.8-facher Prompt, halb
so grosse Datei. Der Schluss des Windows-Laufs — „wer lokal etwas
Agentenähnliches will, nimmt das gewöhnliche 4-Bit-Modell" — hält der Korrektur
nicht stand.

---

## Der Befund: ein fehlendes GGUF-Feld kostet BitNet fünf von zehn Aufgaben

Beim Laden meldet llama.cpp:

```
load: missing pre-tokenizer type, using: 'default'
```

`ggml-model-i2_s.gguf` enthält kein `tokenizer.ggml.pre`. llama.cpp nimmt
ersatzweise `default`; richtig wäre `llama-bpe`, denn BitNet-b1.58-2B-4T benutzt
den Llama-3-Tokenizer (BOS `<|begin_of_text|>`, EOT `<|eot_id|>`, 128k-Vokabular).

Die Folge ist eine andere Zerlegung, genau an den Bezeichnern, um die es geht:

| | `read_file` |
|---|---|
| `default` (Vorgabe) | `read` + `_` + `file` — `[888, 62, 1213]` |
| `llama-bpe` (richtig) | `read` + `_file` — `[888, 2517]` |

Das Modell wurde mit der zweiten Zerlegung trainiert. Bekommt es die erste, muss
es Werkzeugnamen aus Bruchstücken zusammensetzen — und verschreibt sich dabei.

### Messung

Gleiche Engine, gleiche Binärdatei, gleiche Modelldatei. Einziger Unterschied:
`--override-kv tokenizer.ggml.pre=str:llama-bpe`.

| | gültiges JSON | richtiges Werkzeug |
|---|---|---|
| ohne Override | 9/10 | 4/10 |
| **mit Override** | **10/10** | **9/10** |

Die 4/10 reproduzieren den Windows-Lauf exakt, samt Fehlerbildern:

```
{"tool": "read__file",  ...}   erwartet read_file    — doppelter Unterstrich
{"tool": "write_ file", ...}   erwartet write_file   — Leerzeichen im Namen
{"tool": "list_dir", "args": {...}}                  — Platzhalter wörtlich
```

Mit Override verschwinden diese Fehler vollständig. Die 10/10 und 9/10 wurden
**dreimal wiederholt**, jedes Mal identisch. Bei `temperature=0` ist das zu
erwarten, aber bei einer Aussage dieser Tragweite nachgeprüft.

Die einzig verbleibende Fehlaufgabe ist dieselbe, an der auch Llama-3.2-3B
scheitert: „Where is the function parse_args defined in this repo?" → `read_file`
statt `search`.

### Was daraus folgt

Der Windows-Bericht deutet die Fehler als Modelleigenschaft: „BitNet scheitert an
der Syntax. Werkzeugnamen zerfallen beim Tokenisieren." Die Beobachtung stimmt,
die Ursache liegt aber nicht im Modell, sondern in der Auslieferung: Microsoft
hat beim Erzeugen des GGUF ein Tokenizer-Feld weggelassen.

Auch der dort dokumentierte Rechenfehler verschwindet. Aufgabe 5 (Wechselgeld):
Windows-Lauf `27.33` — falsch; hier mit Override eine korrekte Herleitung über
7 Packungen à 5 Franken zu `ANSWER: 15`.

### Die Leerzeilen-Empfindlichkeit verschwindet ebenfalls

Der Windows-Bericht widmet einen eigenen Abschnitt der Beobachtung, dass eine
einzige entfernte Leerzeile im System-Prompt BitNet von 4/10 auf 2/10 drückt, und
schliesst daraus: „eine Zahl wie 4/10 ist für BitNet keine Modelleigenschaft,
sondern gilt für genau diese Promptfassung."

Nachgemessen, beide Fassungen auf derselben Engine:

| System-Prompt | ohne Override | mit `llama-bpe` |
|---|---|---|
| mit Leerzeile | 4/10 | **9/10** |
| ohne Leerzeile (`--compact-system`) | 3/10 | **9/10** |

Ohne Override reproduziert sich die Empfindlichkeit (4 → 3; Windows sah 4 → 2).
Mit korrektem Tokenizer ist sie **vollständig weg** — 9/10 in beiden Fassungen.

Auch die Prompt-Fragilität war also kein Modellverhalten, sondern ein Symptom
derselben Ursache: Ein Modell, das Bezeichner aus Bruchstücken zusammensetzen
muss, hängt an jeder Formatierungskleinigkeit. Eines, das sie als Token sieht,
nicht.

---

## Die Engine muss gepinnt werden

`setup/linux.sh` klont `microsoft/BitNet` ohne Revisionsangabe. Was man heute
bekommt, ist nicht, worauf der Referenzlauf beruht:

| | Referenz (laut `patches/README.md`) | heutiger Klon |
|---|---|---|
| BitNet | `01eb415` (10.03.2026) | `0b341e5` (27.07.2026) |
| llama.cpp-Submodul | `1f86f058` (b3639) | `390c3077` (b9918) |
| Submodul-Branch | — | `release-bitnet-embedding-0.6b-270m` |

Der Zeiger steht auf einem Fork-Branch, der nach einem anderen Modell benannt ist.
Mit diesem Stand ist BitNet-b1.58-2B-4T unbenutzbar:

| | Engine `1f86f058` | Engine `390c3077` |
|---|---|---|
| „What is the capital of France?" | `'The capital of France is Paris.'`, `finish: stop` | korrekte Antwort, dann **Endlosschleife**, `finish: length` |
| nötige Eingriffe | keine, unverändertes GGUF | Template **und** Pre-Tokenizer überschrieben — half nicht |
| gültiges JSON / Werkzeug | 9/10 / 4/10 | 1/10 / 0/10 |

Auf der neuen Engine schlägt jeder Reparaturversuch fehl: das offizielle
Chat-Template aus Microsofts `tokenizer_config.json`, `chatml`, `llama3`, der
Pre-Tokenizer-Override — das Modell hört in keiner Variante auf zu schreiben.

**Bemerkenswert und gefährlich: Der Durchsatz bleibt dabei unauffällig.**
`llama-bench` meldet auf der kaputten Engine 21–24 tok/s, also plausible Werte.
Wer nur Geschwindigkeit misst, merkt nichts.

Q4_K_M ist nicht betroffen — Llama-3.2-3B liefert auf beiden Engines dieselbe
Perplexity (8.8596 gegen 8.8599). Der Defekt trifft ausschliesslich den
i2_s-Pfad.

### Prüfung vor jeder Messung

```bash
./build/bin/llama-bench -m <i2_s.gguf> -p 8 -n 8 -r 1
```

Steht in der Modellspalte `I2_S - 2 bpw ternary`, ist die Engine brauchbar. Steht
dort `Q1_0`, ist sie es nicht.

*(Die in derselben Zeile abweichenden Grössen- und Parameterangaben — 1.71 GiB /
2.74 B gegen 1.10 GiB / 2.41 B — sind kein Beleg für falsch gelesene Gewichte:
`llama-server` und `llama-perplexity` melden auf beiden Engines übereinstimmend
1.10 GiB / 2.41 B. Das ist ein Anzeigefehler von `llama-bench`. Die Ursache der
Degeneration im Ladepfad ist **nicht ermittelt**.)*

---

## Durchsatz

`llama-bench -p 128 -n 64 -r 2`, Engine `1f86f058`, ohne `--no-mmap` (auf Linux
unnötig).

### BitNet-b1.58-2B-4T i2_s

| Threads | Prompt (pp128) | Generierung (tg64) |
|---|---|---|
| 4 | 133.04 ± 0.72 | **22.44 ± 0.02** |
| 8 | 147.60 ± 1.05 | 22.09 ± 0.19 |
| 12 | **175.38 ± 1.17** | 22.25 ± 0.01 |

### Llama-3.2-3B-Instruct Q4_K_M

| Threads | Prompt (pp128) | Generierung (tg64) |
|---|---|---|
| 4 | 34.73 ± 0.33 | 13.52 ± 0.01 |
| 8 | 33.10 ± 0.13 | **13.64 ± 0.10** |
| 12 | **36.73 ± 1.73** | 13.29 ± 0.03 |

### OLMoE-1B-7B int8 über colibri

`olmoe_speed.py`, Steigungsmessung. Zwei Läufe: **11.94** und **11.66 tok/s**
(83.8 bzw. 85.7 ms/Token). Der zweite lief auf nachweislich unbelasteter
Maschine; die 2.3 % Abweichung ist Messrauschen.

Ladezeit 2.2 s, RSS nach dem Laden 1.79 GB. colibri wählt selbstständig 6
physische Kerne statt 12 logischer und begründet das mit SMT-Nachteilen beim
Dekodieren.

### Vergleich mit dem Windows-Lauf

| | i5-13500T (35 W) | i7-8850H | Faktor |
|---|---|---|---|
| BitNet tg64 | 8.93 | 22.44 | **2.5×** |
| BitNet pp128 | 95.5 | 175.38 | 1.8× |
| Llama-3B tg64 | 6.68 | 13.64 | 2.0× |
| Llama-3B pp128 | 28.4 | 36.73 | 1.3× |
| OLMoE (colibri) | 4.21 | 11.94 | 2.8× |

**Mehr Threads schaden hier nicht.** Der Windows-Lauf sah BitNets Generierung von
4 auf 20 Threads um ein Drittel einbrechen; hier bleibt sie von 4 bis 12 Threads
flach bei ~22 tok/s. Der i5-13500T ist eine Hybrid-CPU mit P- und E-Cores, der
i7-8850H hat sechs gleichartige Kerne — die Lastverteilung, die dort stört, gibt
es hier nicht. Nur die Prompt-Verarbeitung skaliert, und die bis 12.

**BitNet gegen 4-Bit, gleiche Engine, gleicher Build:** 1.65× Generierung
(22.44 gegen 13.64), 4.8× Prompt (175.4 gegen 36.7). Auf Windows waren es 1.34×
und 3.4×. Der Vorteil fällt auf dieser CPU also deutlicher aus. Zu beachten:
2.4 B gegen 3.6 B Parameter, kein reiner Kernel-Vergleich.

## Werkzeugwahl

Zehn Aufgaben, fünf Werkzeuge, `temperature=0`, Engine `1f86f058`.

| Modell | gültiges JSON | richtiges Werkzeug |
|---|---|---|
| **BitNet-2B-4T + `llama-bpe`** | **10/10** | **9/10** |
| Llama-3.2-3B Q4_K_M | 10/10 | 9/10 |
| BitNet-2B-4T ohne Override | 9/10 | 4/10 |
| OLMoE-1B-7B int8 (colibri) | 10/10 | 4/10 |

Llama verfehlt nur Aufgabe 9 (`parse_args` → `list_dir` statt `search`), BitNet
mit Override dieselbe Aufgabe (→ `read_file`). Beide Werte decken sich mit dem
Windows-Lauf (dort Llama 9/10).

**OLMoE scheitert wie dokumentiert an der Auswahl, nicht an der Syntax.** 10/10
sauberes JSON, und dann achtmal `read_file`, egal was gefragt war:

```
"List everything in the current directory"  -> read_file(".")
"Run the unit tests with pytest."           -> read_file("example.txt")
"Save the text 'build ok' into status.log." -> read_file("status.log")
"Install the dependencies with npm install" -> npm(path=".", save=true)   erfunden
```

### Die anfänglichen 2/10 waren ein Fehler im Testgeschirr

Der erste Lauf ergab 2/10 gegen die 4/10 des Windows-Berichts — stabil
reproduzierbar, also kein Rauschen. Ursache war die Python-Portierung selbst.

`olmoe` sendet im Chat-Modus bei jedem Zeilenumbruch sofort ab, der Prompt muss
also einzeilig sein. `olmoe_eval.py` erledigte das mit
`" ".join(text.split())` — und löschte die Umbrüche der Werkzeugliste dabei
**ersatzlos**:

```
… and no others: read_file(path) - read a file write_file(path, text) - write a
file list_dir(path) - list a directory run_shell(cmd) - …
```

Das PowerShell-Original trennt die Werkzeuge dagegen von Hand mit Semikola. Mit
dessen Wortlaut liefert dieselbe Engine, dasselbe Modell, dieselbe Maschine
**4/10** — der Windows-Wert, exakt getroffen.

`bench/tasks.py` stellt jetzt beide Fassungen aus einer Quelle bereit:
`TOOL_SYSTEM` (mehrzeilig, unverändert) und `TOOL_SYSTEM_ONELINE` (mit
Semikola, wortgleich mit dem PowerShell-Original). `bench/test_prompts.py`
sichert beides ab, samt Byte-Gleichheit von `TOOL_SYSTEM` — denn an dem Text
hängt BitNets Leerzeilen-Verhalten.

Die Zahl in der Tabelle oben ist die korrigierte: **4/10**.

Bemerkenswert daran: Der README begründet die gemeinsame `tasks.py` damit, dass
man sonst „Promptfassungen statt Modelle" vergleiche. Genau das ist beim
Portieren trotzdem passiert — nur eine Ebene tiefer, in der Glättung.

Der praktische Unterschied bleibt der aus dem Windows-Bericht: Ein kaputter
Werkzeugname fällt dem Parser auf. Ein sauberer Aufruf des falschen Werkzeugs
läuft durch. Nur trifft dieser Unterschied nach der Tokenizer-Korrektur nicht
mehr BitNet gegen OLMoE, sondern nur noch OLMoE.

## Stichproben

| Aufgabe | BitNet + `llama-bpe` | Llama-3.2-3B Q4 | OLMoE (colibri) |
|---|---|---|---|
| Quicksort in Python | korrekt | korrekt | korrekt |
| Hauptstadt CH, ein Wort GROSS | `ZURICH` — falsch | `BERN` | `GENEVA` — falsch |
| Wechselgeld (21 Stifte, 3 für 5, aus 50) | **`15` — richtig** | `15` — richtig | keine Antwort, brach vor dem Ergebnis ab |
| Deutsch, zwei Sätze zu DB-Index | verständlich, aber redundant | sauber | geschwätzig, halb richtig |
| Mehrschritt-Plan (Tippfehler beheben) | ein sauberer Schritt | zwei saubere Schritte | drei Schritte, Pfad erfunden |

BitNets Rechenweg ist jetzt der richtige: 21/3 = 7 Packungen à 5 Franken = 35,
50 − 35 = 15. Im Windows-Lauf rundete es 5/3 auf 1.67 und kam auf 27.33. Es
rundet auch hier auf 1.67, multipliziert aber richtig zu 35.

Bei der Formatvorgabe („exactly one word, uppercase") versagt BitNet weiterhin,
nun mit einer inhaltlich falschen Hauptstadt. Ohne Override lieferte es `Bern` —
inhaltlich richtig, Format ignoriert. Das ist die einzige Stichprobe, die sich
durch die Korrektur **verschlechtert**.

Markdown-Zäune ignorieren alle drei Modelle trotz ausdrücklichen Verbots. Der
Auswerter entfernt sie vor dem Parsen.

## Perplexity

Kein wikitext, sondern ein eigenes Korpus: 115 KB englischer Fliesstext aus den
`.md`-Dateien von llama.cpp und BitNet, Markdown-Zeilen entfernt. Die Datei liegt
im Repo unter `bench/ppl-corpus.txt` (sha256
`e38278b03fa41f75d843cea8125ab5819ff685304ab13b6feb62a1abc848f2f5`, 115031
Bytes) und muss für jeden Vergleich identisch wiederverwendet werden. Absolutwerte sind **nicht** mit
veröffentlichten wikitext-Zahlen vergleichbar. `-c 512`, `-t 8`.

| Modell | Engine | Tokenizer | Chunks | PPL |
|---|---|---|---|---|
| Llama-3.2-3B Q4_K_M | `1f86f058` | — | 61 | **8.8596 ± 0.211** |
| Llama-3.2-3B Q4_K_M | `390c3077` | — | 61 | 8.8599 ± 0.211 |
| **BitNet-2B-4T i2_s** | **`1f86f058`** | **`llama-bpe`** | **61** | **11.1905 ± 0.282** |
| BitNet-2B-4T i2_s | `390c3077` | `llama-bpe` | 61 | 41.7541 ± 1.261 |
| BitNet-2B-4T i2_s | `1f86f058` | `default` | 74 | 32.7866 ± 1.030 |

> **Nur Zeilen mit gleicher Chunk-Zahl sind vergleichbar.** Verschiedene
> Tokenisierung heisst verschiedenes Chunking heisst verschiedene Perplexity.
> Die letzte Zeile steht deshalb für sich.

Drei Dinge fallen auf:

1. **Die kaputte Engine zerstört die Perplexity.** 41.75 gegen 11.19 — bei
   gleichem Tokenizer und gleicher Chunk-Zahl, also direkt vergleichbar. Ein
   Faktor **3.7**. Das i2_s-Problem ist damit auch quantitativ belegt und nicht
   nur am Generierungsverhalten ablesbar.
2. **BitNet liegt nahe bei Llama.** 11.19 gegen 8.86, Faktor 1.26 — für 2.4 B
   ternäre gegen 3.6 B 4-Bit-Parameter ein sehr gutes Ergebnis, und im Einklang
   mit der gleichen Werkzeugquote.
3. **Der fehlende Tokenizer-Eintrag kostet auch hier.** 32.79 mit `default`
   gegen 11.19 mit `llama-bpe`. Die beiden Zeilen sind wegen 74 gegen 61 Chunks
   nicht streng vergleichbar, aber ein Unterschied dieser Grösse lässt sich
   damit nicht erklären — er bestätigt den Befund aus dem Agententest an einer
   völlig anderen Metrik.

**Korrektur an einer früheren Fassung dieser Datei:** Dort stand, die kaputte
Engine zeige sich in der Perplexity kaum. Das beruhte auf dem Vergleich zweier
Zeilen mit verschiedener Chunk-Zahl und war falsch.

## Nachbauen

```bash
# Engine, die i2_s korrekt lädt
git clone --recursive https://github.com/microsoft/BitNet.git ~/ki/BitNet-ref
cd ~/ki/BitNet-ref && git checkout 01eb415
git submodule update --init --recursive     # llama.cpp 1f86f058
git apply ~/projects/bitnet-colibri-bench/patches/bitnet-mad-const-y_col.patch
python3 utils/codegen_tl2.py --model bitnet_b1_58-3B \
    --BM 160,320,320 --BK 96,96,96 --bm 32,32,32
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DBITNET_X86_TL2=OFF \
    -DLLAMA_CURL=OFF -DLLAMA_BUILD_COMMON=ON -DLLAMA_BUILD_TOOLS=ON \
    -DLLAMA_BUILD_EXAMPLES=ON -DLLAMA_BUILD_SERVER=ON
cmake --build build -j 6

# BitNet — der Override ist der Punkt
./build/bin/llama-server -m <i2_s.gguf> -t 4 -c 4096 --port 8080 \
    --override-kv tokenizer.ggml.pre=str:llama-bpe
python3 bench/agent_eval.py --port 8080 --label BitNet-2B-4T
```

Die drei `LLAMA_BUILD_*`-Optionen sind nötig, sonst entstehen nur die
Bibliotheken. Die aktuelle llama.cpp setzt sie als Submodul auf `OFF`; BitNets
`CMakeLists.txt` erzwingt nur `LLAMA_BUILD_SERVER`.

Modelldatei geprüft — identisch mit dem, was Hugging Face ausliefert:

```
sha256  4221b252fdd5fd25e15847adfeb5ee88886506ba50b8a34548374492884c2162
size    1187801280
```

## Weitere Beobachtungen

- **Das GGUF trägt zusätzlich ein kaputtes Chat-Template.** Eingebacken ist
  `Human: …\n\nBITNETAssistant: <|end_of_text|>`; Microsofts eigenes
  `tokenizer_config.json` definiert `System: …<|eot_id|>User: …<|eot_id|>Assistant: `.
  Falsche Rollennamen, falscher Separator, und ein EOS-Token genau dort, wo die
  Antwort beginnen soll. Auf der Referenz-Engine folgenlos — die ist älter als
  llama.cpps Jinja-Pfad und benutzt ihre eingebaute Behandlung. Auf neueren
  Engines schlägt es voll durch.
- **BitNets CMake kompiliert seinen eigenen Kernel nie.** `src/CMakeLists.txt`
  Zeile 2–3 setzt `GGML_SOURCES_BITNET` zweimal statt anzuhängen, das zweite
  `set` überschreibt das erste. `ggml-bitnet-mad.cpp` landet in keinem Build
  (geprüft über `compile_commands.json`); der i2_s-Pfad läuft über llama.cpps
  `ggml-cpu-i2s.c`. Der Fehler steckt in `01eb415` und in `0b341e5`.
  Nebenfolge: `patches/bitnet-mad-const-y_col.patch` korrigiert eine Datei, die
  gar nicht übersetzt wird. Die Begründung in `patches/README.md` — ohne ihn
  breche die Übersetzung ab — trifft für `BITNET_X86_TL2=OFF` nicht zu.
- **Der Kernel-Header wird nicht mehr erzeugt.** `include/bitnet-lut-kernels.h`
  ist seit `3b04140` eingecheckt; `setup/linux.sh` erzeugt ihn nur, wenn er
  fehlt, und überspringt den Codegen-Schritt darum stillschweigend. Hier
  folgenlos, weil der Header komplett in `#if defined(GGML_BITNET_X86_TL2)`
  steht und mit `-DBITNET_X86_TL2=OFF` inert ist. Bei einem TL2-Build wäre es
  eine Falle.
- **`llama-cli` hängt ohne Argumente im Chat-Modus.** Für Einzelabfragen
  `--single-turn` oder gleich den Server benutzen.
- **colibri ist auch hier nicht plattengebunden.** 1.79 GB RSS bei 46 GB RAM —
  die Streaming-Idee, für die colibri existiert, greift bei einem 7-B-Modell auf
  dieser Maschine noch weniger als auf den 16 GB der Windows-Kiste.
- **Der Determinismus ist geprüft.** `-t 1`, `-t 2` und `-t 4` liefern bei
  `temperature=0` zeichengleiche Ausgabe. Qualitätsunterschiede zwischen
  Maschinen können also nicht von der Thread-Zahl kommen.

## Offen

1. **Warum die neue Engine i2_s zerlegt** — der Ladepfad ist nicht untersucht.
   Reizvoll aus Neugier; praktisch nicht nötig, solange die Engine gepinnt ist.

> **Nachtrag vom 20.08.2026.** Dieser Abschnitt führte ursprünglich als zweiten
> Punkt, das fehlende `tokenizer.ggml.pre` an microsoft/BitNet zu melden.
> Fehlerberichte an fremde Projekte sind ausdrücklich ausserhalb des Rahmens
> dieses Repos — siehe `CLAUDE.md`, „Ausserhalb des Rahmens". Der Befund selbst
> bleibt vollständig dokumentiert, weil man ihn zum Messen kennen muss.

Das Projekt ist abgeschlossen; offene Punkte gibt es keine mehr. Betriebswissen
und die Liste der Entscheidungen stehen in `CLAUDE.md`.
