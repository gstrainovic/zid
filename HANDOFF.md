# Handoff — Linux-Lauf auf i7-8850H (Fedora 43)

Stand: 19.08.2026. Geschrieben zur Übergabe an den nächsten Agenten.

Der Lauf ist **nicht abgeschlossen**. Er hat aber einen Befund ergeben, der
wichtiger ist als die Zahlen: `setup/linux.sh` baut in seiner jetzigen Fassung
eine Engine, die BitNet-Gewichte falsch liest. Wer die Messung fortsetzt, muss
das zuerst verstehen, sonst misst er Unsinn.

---

## 1. Kernbefund: die Engine ist nicht gepinnt, und der aktuelle Stand ist kaputt

`setup/linux.sh` klont `microsoft/BitNet` ohne Revisionsangabe. Heute liefert das
einen anderen Stand als zur Zeit des Windows-Referenzlaufs:

| | Windows-Referenz (laut `patches/README.md`) | heutiger Klon |
|---|---|---|
| BitNet-Commit | `01eb415` (10.03.2026) | `0b341e5` (27.07.2026) |
| llama.cpp-Submodul | `1f86f058` (b3639) | `390c3077` (b9918) |
| Submodul-Branch | — | `release-bitnet-embedding-0.6b-270m` |

Der Submodul-Zeiger steht heute auf einem Fork-Branch, der nach einem **anderen
Modell** benannt ist (0.6B-Embedding).

### Der Beweis

Entscheidend ist das **Verhalten**, gemessen mit derselben Modelldatei, demselben
Testgeschirr, auf derselben Maschine:

| | Engine `390c3077` (heute) | Engine `1f86f058` (Referenz) |
|---|---|---|
| „What is the capital of France?" | korrekte Antwort, dann **Endlosschleife**, `finish: length` | `'The capital of France is Paris.'`, `finish: stop` |
| Korrekturen nötig? | Template **und** Pre-Tokenizer überschrieben — half nicht | **keine**, unverändertes GGUF |
| `agent_eval.py` | 1/10 JSON, 0/10 Werkzeug | 9/10 JSON, 4/10 Werkzeug |

Bei `temperature=0` ist Dekodierung deterministisch; `-t 1`, `-t 2` und `-t 4`
liefern auf derselben Engine zeichengleiche Ausgabe. Ein Hardware-Einfluss auf
die *Qualität* ist damit ausgeschlossen. Bleibt die Engine.

**Ein schwächeres Indiz**, das nicht überstrapaziert werden sollte: `llama-bench`
beschriftet den Tensortyp je nach Engine verschieden — `I2_S - 2 bpw ternary` auf
`1f86f058`, `Q1_0` auf `390c3077`. Die dort ebenfalls abweichenden Größen- und
Parameterangaben (1.71 GiB / 2.74 B gegen 1.10 GiB / 2.41 B) sind allerdings
**kein** Beleg für falsch gelesene Gewichte: `llama-server` und
`llama-perplexity` melden auf *beiden* Engines übereinstimmend 1.10 GiB / 2.41 B.
Die Abweichung ist ein Anzeigefehler von `llama-bench`, nicht des Modells.
Die genaue Ursache im Ladepfad ist **nicht ermittelt** — das ist offene Arbeit.

### Was das für die Messwerte bedeutet

| Messung | Engine `390c3077` (heute) | Engine `1f86f058` (Referenz) | Windows-Referenz |
|---|---|---|---|
| gültiges JSON | 1 / 10 | **9 / 10** | 9 / 10 |
| richtiges Werkzeug | 0 / 10 | **4 / 10** | 4 / 10 |
| Perplexity (eigenes Korpus) | 41.75 ± 1.26 | *läuft noch, s. u.* | — |

Auf der Referenz-Engine reproduziert dieser Laptop den Windows-Lauf **exakt** —
nicht nur die Zahlen, sondern die Fehlerbilder: `read__file`, `write_ file`, der
wörtlich übernommene Platzhalter `<one of the five names above>`. Genau die
Beispiele aus `results/windows-i5-13500T.md`.

**Schlussfolgerung: Die Hardware ist in Ordnung. Der Laptop ist schneller als die
Referenzmaschine. Kaputt ist allein die heute geklonte Engine.**

---

## 2. Was gemessen ist

### Maschine

| | |
|---|---|
| CPU | Intel Core i7-8850H — 6 Kerne / 12 Threads, 2.6 GHz Basis, 4.3 GHz Turbo, Coffee Lake |
| Befehlssätze | AVX2, FMA, F16C — **kein** AVX-VNNI, **kein** AVX512 |
| RAM | 46 GB |
| GPU | Intel UHD 630 + NVIDIA Quadro P1000 Mobile — **ungenutzt**, alles auf der CPU |
| Platte | 246 GB, davon beim Start 43 GB frei (nach Setup + Referenz-Build: 31 GB) |
| OS | Fedora 43, Kernel 7.1.8-100.fc43.x86_64 |
| Toolchain | clang 21.1.8, cmake 3.31.11, ninja 1.13.1, Python 3.14.3 |

### Durchsatz BitNet-b1.58-2B-4T i2_s

`llama-bench -p 128 -n 64 -r 2`, ohne `--no-mmap` (auf Linux nicht nötig).

Auf der **Referenz-Engine** `1f86f058` — das sind die gültigen Zahlen:

| Threads | pp128 | tg64 |
|---|---|---|
| 4 | 133.04 ± 0.72 | **22.44 ± 0.02** |
| 8 | 147.60 ± 1.05 | 22.09 ± 0.19 |
| 12 | **175.38 ± 1.17** | 22.25 ± 0.01 |

Zum Vergleich Windows i5-13500T: bestes tg64 **8.93**, bestes pp128 **95.5**.
Also rund **2.5× schnellere Generierung** und **1.8× schnellerer Prompt** auf
diesem Laptop.

Bemerkenswert gegenüber der Windows-Beobachtung: Auf dieser CPU **schadet mehr
Threads der Generierung nicht** — tg64 bleibt von 4 bis 12 Threads flach bei
~22 tok/s. Der Windows-Bericht sah einen Einbruch von einem Drittel. Plausible
Erklärung: Der i5-13500T ist eine Hybrid-CPU (P- und E-Cores), der i7-8850H hat
sechs gleichartige Kerne. Das ist ein echter Hardware-Unterschied und gehört so
ins Ergebnis.

Auf der kaputten Engine `390c3077` gemessen (**nicht verwenden**, nur zur
Dokumentation): tg64 21.74 / 23.72 / 22.59 / 13.34 bei 4 / 8 / 12 / 16 Threads,
pp128 110.40 / 108.01 / 141.17 / 76.80. Die Zahlen sehen plausibel aus — das ist
die Falle: Der Durchsatz wirkt normal, obwohl das Modell Unsinn erzeugt.

### Perplexity

Eigenes Korpus, kein wikitext: 115 KB englische Fließtexte aus den `.md`-Dateien
von llama.cpp und BitNet, Markdown-Zeilen entfernt. Datei liegt unter
`$SCRATCH/ppl-corpus.txt` (s. Abschnitt 5) und **muss für Vergleichbarkeit
identisch wiederverwendet werden** — absolute Zahlen sind nicht mit
veröffentlichten wikitext-Werten vergleichbar, nur untereinander.

`-c 512`, 61 Chunks, `-t 8`:

| Modell | Engine | Chunks | PPL |
|---|---|---|---|
| Llama-3.2-3B-Instruct Q4_K_M | `390c3077` | 61 | **8.86 ± 0.21** |
| BitNet-b1.58-2B-4T i2_s | `390c3077` (kaputt), mit Pre-Tokenizer-Override | 61 | 41.75 ± 1.26 |
| BitNet-b1.58-2B-4T i2_s | `1f86f058` (Referenz), ohne Override | 74 | **offen — Lauf war beim Feierabend aktiv** |

> **Diese drei Zahlen sind nicht direkt vergleichbar.** Die Chunk-Zahl
> unterscheidet sich (61 gegen 74), weil verschieden tokenisiert wurde — mit
> beziehungsweise ohne `--override-kv tokenizer.ggml.pre=str:llama-bpe`. Andere
> Tokenisierung heisst anderes Chunking heisst andere Perplexity. Wer die Zahlen
> ernsthaft nebeneinanderstellen will, muss **alle** Läufe mit identischer
> Tokenizer-Einstellung wiederholen. Bis dahin taugen sie nur als grobe
> Grössenordnung.

Zwischenstand des offenen Laufs bei Chunk 12: 41.4 — die kaputte Engine stand an
derselben Stelle bei 86.9, also etwa doppelt so hoch. Endwert in
`$SCRATCH/ppl-bitnet-refengine.log` nachlesen.

Llama lief auf der neuen Engine. Vermutlich unbedenklich, weil der Defekt die
i2_s-Tensoren betrifft und nicht Q4_K_M — **geprüft ist das nicht**. Für einen
sauberen Bericht gehört Llama auf dieselbe Engine wie BitNet.

### Werkzeugwahl

Volles Protokoll beider Läufe: `$SCRATCH/bitnet-agent-refengine.log` (Referenz-Engine,
9/10 und 4/10) und `$SCRATCH/bitnet-agent-fixed.log` (neue Engine, 1/10 und 0/10).

---

## 3. Was noch komplett fehlt

1. **colibri / OLMoE — gar nicht gemessen.** Weder `bench/olmoe_eval.py` noch
   `bench/olmoe_speed.py` lief. Das ist ein Drittel des Benchmarks. Das Setup ist
   fertig: `~/ki/colibri/c/olmoe` gebaut, `~/ki/colibri/olmoe_merged` konvertiert
   (7.2 GB, fünf Shards).
2. **`bench/probe.py`** — für kein Modell gelaufen.
3. **`agent_eval.py` für Llama-3.2-3B** — nicht gelaufen. Windows-Referenz: 9/10.
4. **BitNet-Perplexity auf der Referenz-Engine** — s. o.
5. **`results/linux-i7-8850H.md`** — noch nicht geschrieben. Erst schreiben, wenn
   die Zahlen von der *richtigen* Engine stammen.
6. **`--compact-system`-Gegenprobe** (die Leerzeilen-Empfindlichkeit aus dem
   Windows-Bericht) — nicht nachgestellt.

---

## 4. Defekte, die unabhängig vom Engine-Problem gefunden wurden

Diese vier sind real und gehören ins Ergebnis, auch wenn sie nicht die Ursache
der Degeneration waren.

### 4.1 `setup/linux.sh` baut die Programme nicht

Nach `./setup/linux.sh ~/ki` existierten in `build/bin/` nur die Bibliotheken —
kein `llama-cli`, kein `llama-server`, kein `llama-bench`. Die aktuelle llama.cpp
setzt `LLAMA_BUILD_TOOLS`, `LLAMA_BUILD_EXAMPLES` und `LLAMA_BUILD_COMMON` auf
`${LLAMA_STANDALONE}`, also **OFF**, wenn sie als Submodul gebaut wird. BitNets
`CMakeLists.txt` erzwingt nur `LLAMA_BUILD_SERVER`.

Behelf (so wurde hier gebaut):

```bash
cmake -B build -DLLAMA_BUILD_COMMON=ON -DLLAMA_BUILD_TOOLS=ON -DLLAMA_BUILD_EXAMPLES=ON
cmake --build build -j "$(nproc)"
```

Auf der Referenz-Engine `1f86f058` tritt das Problem nicht auf — dort war die
Vorgabe noch anders. Es ist also eine Folge desselben ungepinnten Klons.

### 4.2 Das GGUF trägt ein kaputtes Chat-Template

Das in `ggml-model-i2_s.gguf` eingebackene Template weicht von Microsofts eigenem
`tokenizer_config.json` ab:

| Quelle | Format |
|---|---|
| offiziell (`microsoft/bitnet-b1.58-2B-4T`) | `System: …<\|eot_id\|>User: …<\|eot_id\|>Assistant: ` |
| im GGUF | `Human: …\n\nBITNETAssistant: <\|end_of_text\|>` |

Falsche Rollennamen, falscher Separator — und ein EOS-Token genau an der Stelle,
wo die Antwort beginnen soll. Über `/apply-template` nachprüfbar.

Das korrigierte Template liegt als `$SCRATCH/bitnet-official.jinja`; anwenden mit
`--jinja --chat-template-file <datei>`.

**Wichtig:** Auf der Referenz-Engine `1f86f058` spielt das keine Rolle — die ist
älter als llama.cpps Jinja-Pfad und benutzt ihre eingebaute Behandlung. Sie
liefert mit dem **unveränderten** GGUF und **ohne** jeden Override sauberes
`finish: stop`. Das Template ist also ein echter Defekt der GGUF-Auslieferung,
aber für den Referenzlauf ohne Folgen.

### 4.3 Dem GGUF fehlt die Pre-Tokenizer-Angabe

Beim Laden: `missing pre-tokenizer type, using: 'default'`. Für einen
Llama-3-BPE-Tokenizer ist `default` falsch. Auswirkung, nachgemessen:

| | `read_file` zerlegt zu |
|---|---|
| ohne Korrektur | `read` + `_` + `file` — 3 Token `[888, 62, 1213]` |
| mit `--override-kv tokenizer.ggml.pre=str:llama-bpe` | `read` + `_file` — 2 Token `[888, 2517]` |

Das ist die wahrscheinliche Ursache der zerfallenen Werkzeugnamen (`read__file`,
`write_ file`), die schon der Windows-Bericht beschreibt. **Die Vermutung ist
nicht bewiesen** — auf der Referenz-Engine wurde die Korrektur nicht gegengetestet.
Das wäre ein lohnendes Experiment: Referenz-Engine **plus**
`--override-kv tokenizer.ggml.pre=str:llama-bpe`, dann `agent_eval.py`. Steigt
die Werkzeugquote über 4/10, ist ein Teil dessen, was der Windows-Bericht dem
Modell zuschreibt, in Wahrheit ein Metadaten-Defekt der GGUF-Datei.

### 4.4 BitNets CMake kompiliert seinen eigenen Kernel nicht

`src/CMakeLists.txt`, Zeilen 2–3:

```cmake
set(GGML_SOURCES_BITNET ggml-bitnet-mad.cpp)
set(GGML_SOURCES_BITNET ggml-bitnet-lut.cpp)   # überschreibt, statt anzuhängen
```

Das zweite `set` ersetzt das erste. `ggml-bitnet-mad.cpp` landet in keinem
Build — bestätigt über `compile_commands.json`. Der Fehler steckt in `01eb415`
**und** in `0b341e5`, ist also alt und nicht die Ursache des Problems.

Nebenfolge: Der Patch `patches/bitnet-mad-const-y_col.patch` korrigiert eine
Datei, die gar nicht übersetzt wird. Er wurde von `setup/linux.sh` sauber
angewendet, aber die Begründung in `patches/README.md` — ohne ihn breche die
Übersetzung ab — trifft für diese Konfiguration (`BITNET_X86_TL2=OFF`) nicht zu.
Sollte nachgeprüft und im Text richtiggestellt werden.

### 4.5 Nebenbefund: der Kernel-Header wird nicht mehr erzeugt

`include/bitnet-lut-kernels.h` ist seit `3b04140` im Repo eingecheckt (1171
Zeilen). `setup/linux.sh` erzeugt ihn nur, `if [ ! -f ... ]` — der Codegen-Schritt
wird also stillschweigend übersprungen und der eingecheckte Header verwendet.
Hier folgenlos, weil der gesamte Header in `#if defined(GGML_BITNET_X86_TL2)`
steht und mit `-DBITNET_X86_TL2=OFF` inert ist. Bei einem TL2-Build wäre das eine
Falle.

---

## 5. Wo alles liegt

Alles Wichtige wurde aus dem flüchtigen `/tmp` gerettet nach:

```
~/ki/bench-artifacts/
```

Dort liegen Korpus, Template, Build-Skript und sämtliche Protokolle. Im Text
unten steht `$SCRATCH` für dieses Verzeichnis.

Besonders wichtig: `ppl-corpus.txt` — ohne exakt diese Datei sind die
Perplexity-Zahlen nicht mehr vergleichbar; und `bitnet-official.jinja`, das
korrigierte Chat-Template.

| Datei | Inhalt |
|---|---|
| `ppl-corpus.txt` | Perplexity-Korpus, 115 KB — **aufheben** |
| `bitnet-official.jinja` | korrigiertes Chat-Template — **aufheben** |
| `bitnet-agent-refengine.log` | 9/10, 4/10 auf Referenz-Engine |
| `bitnet-agent-fixed.log` | 1/10, 0/10 auf neuer Engine |
| `bitnet-agent.log` | 0/10, 0/10 — neue Engine, ohne Korrekturen |
| `bench-refengine.log` | llama-bench, Referenz-Engine |
| `bitnet-bench.log` | llama-bench, neue Engine |
| `ppl-bitnet-refengine.log` | BitNet-PPL auf Referenz-Engine (Lauf war aktiv) |
| `build-ref.sh` / `build-ref.log` | Skript und Protokoll des Referenz-Builds |
| `setup.log` | Protokoll von `setup/linux.sh` |

Builds:

| Pfad | Stand |
|---|---|
| `~/ki/BitNet` | `0b341e5` + Submodul `390c3077` — **kaputt für i2_s** |
| `~/ki/BitNet-ref` | `01eb415` + Submodul `1f86f058` — **die brauchbare Engine** |
| `~/ki/colibri` | gebaut, `olmoe_merged` konvertiert, ungemessen |

Modelle liegen nur unter `~/ki/BitNet/models/` und werden von `~/ki/BitNet-ref`
über absolute Pfade mitbenutzt.

Die Modelldatei ist geprüft und echt:

```
sha256  4221b252fdd5fd25e15847adfeb5ee88886506ba50b8a34548374492884c2162
size    1187801280
```

identisch mit dem, was die HF-API für `microsoft/BitNet-b1.58-2B-4T-gguf`
ausweist. **Das Modell ist als Fehlerquelle ausgeschlossen.**

---

## 6. Empfohlene nächste Schritte

1. **BitNet-PPL auf der Referenz-Engine** abschließen (`$SCRATCH/ppl-bitnet-refengine.log`).
2. **colibri/OLMoE messen** — `olmoe_eval.py` und `olmoe_speed.py`. Fehlt bislang
   vollständig.
3. **Llama-3.2-3B** auf der Referenz-Engine: `agent_eval.py`, `probe.py`,
   `llama-bench`, Perplexity. Damit stehen alle Zahlen auf einer Engine.
4. **`probe.py`** für alle drei Modelle.
5. **Gegenprobe aus 4.3:** Referenz-Engine plus Pre-Tokenizer-Override. Könnte
   einen Teil von BitNets „Syntaxschwäche" als GGUF-Metadatenfehler entlarven.
6. **`results/linux-i7-8850H.md` schreiben** — mit der ausdrücklichen Angabe,
   welche Engine benutzt wurde, weil das hier den Ausschlag gibt.
7. **`setup/linux.sh` reparieren:** Commit **und** Submodul pinnen
   (`01eb415` / `1f86f058`), die drei `LLAMA_BUILD_*`-Optionen ergänzen. Ohne Pin
   ist das Repo nicht reproduzierbar — der Kern dieses Handoffs.
8. **`README.md` und `patches/README.md` nachziehen**, sobald 4.4 geklärt ist.

### Reproduktion des Referenz-Setups

```bash
# Engine, die BitNet korrekt lädt
git clone --recursive https://github.com/microsoft/BitNet.git ~/ki/BitNet-ref
cd ~/ki/BitNet-ref
git checkout 01eb415
git submodule update --init --recursive     # holt llama.cpp 1f86f058
git apply ~/projects/bitnet-colibri-bench/patches/bitnet-mad-const-y_col.patch
python3 utils/codegen_tl2.py --model bitnet_b1_58-3B \
    --BM 160,320,320 --BK 96,96,96 --bm 32,32,32
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DBITNET_X86_TL2=OFF \
    -DLLAMA_CURL=OFF -DLLAMA_BUILD_COMMON=ON -DLLAMA_BUILD_TOOLS=ON \
    -DLLAMA_BUILD_EXAMPLES=ON -DLLAMA_BUILD_SERVER=ON
cmake --build build -j 6
```

Fertiges Skript: `$SCRATCH/build-ref.sh`.

**Prüfung, ob die Engine taugt** — vor jeder Messung:

```bash
./build/bin/llama-bench -m <i2_s.gguf> -p 8 -n 8 -r 1
```

Steht in der Modellspalte `I2_S - 2 bpw ternary` mit **1.71 GiB / 2.74 B**, ist
alles richtig. Steht dort `Q1_0` mit **1.10 GiB / 2.41 B**, liest die Engine die
Gewichte falsch und jede weitere Zahl ist wertlos.
