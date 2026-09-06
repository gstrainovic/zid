# CLAUDE.md — llm-bench (früher bitnet-colibri-bench)

Seit 06.09.2026 als `git subtree` Teil des vulkan-ed-Repos: Engines unter `engines/`, Modelle
flach unter `models/` (BitNet-Referenz `models/bitnet-b1.58-2B-4T/`), colibri gelöscht.

## Projektstand: abgeschlossen (20.08.2026)

Drei Läufe, alle vollständig in `results/`: Windows i5-13500T (Referenz),
Linux i7-8850H (CPU-Runde) und die zweite Laptop-Runde (GPU via Vulkan plus
Qwen3-4B, Phi-4-mini, Gemma-3-4B). Die Fragen des Projekts sind beantwortet;
Kernbefund der zweiten Runde: mit der Quadro P1000 des Laptops ist Llama-Q4
auf der GPU (24.1 tok/s) schneller als BitNet auf der CPU (22.4), und
Qwen3-4B erreicht als erstes Modell 10/10 Werkzeugwahl. **Es sind keine
weiteren Läufe geplant.** Dieses Dokument ersetzt das frühere `HANDOFF.md`; es
enthält das Betriebswissen für den Fall, dass doch noch einmal gemessen wird,
und die Entscheidungen, die nicht erneut aufgerollt werden.

## Bevor irgendetwas gemessen wird

Beide Punkte haben je einen halben Messtag gekostet. `setup/linux.sh`
automatisiert sie, aber wer von Hand baut, muss sie kennen.

### Die Engine ist gepinnt, und das ist keine Vorsicht

```
BitNet             01eb415772c342d9f20dc42772f1583ae1e5b102
llama.cpp-Submodul 1f86f058de0c3f4098dedae2ae8653c335c868a1   (b3962)
```

Der Stand von `microsoft/BitNet` vom 20.08.2026 zeigt mit seinem Submodul auf
einen Fork-Branch (`release-bitnet-embedding-0.6b-270m`), benannt nach einem
anderen Modell. Damit ist BitNet-b1.58-2B-4T unbenutzbar: korrekte Antwort,
dann Endlosschleife, Perplexity ×3.7, Werkzeugwahl 0/10.

**Der Durchsatz bleibt dabei unauffällig** — plausible Zahlen. Wer nur
Geschwindigkeit misst, merkt nichts. Deshalb vor jeder Messung:

```bash
./build/bin/llama-bench -m <i2_s.gguf> -p 8 -n 8 -r 1
```

`I2_S - 2 bpw ternary` in der Modellspalte heisst brauchbar. `Q1_0` heisst:
nicht messen. (Abweichende Grössenangaben dort sind ein Anzeigefehler von
`llama-bench`, kein Defekt.)

### BitNet braucht den Pre-Tokenizer-Override

```
--override-kv tokenizer.ggml.pre=str:llama-bpe
```

Dem ausgelieferten GGUF fehlt das Feld. llama.cpp nimmt `default`, richtig wäre
`llama-bpe`. Ohne den Override zerfällt `read_file` in `read`+`_`+`file`, die
Trefferquote fällt von 8–9/10 auf 4/10, die Perplexity steigt. Gilt **nur für
BitNet**; Llama-3.2-3B ist nicht betroffen.

### Jede Zahl braucht drei Kennungen

Engine-Commit, Submodul-Commit, Modell-sha256 — im Kopf jeder
`results/`-Datei. Referenzmodell:

```
sha256 4221b252fdd5fd25e15847adfeb5ee88886506ba50b8a34548374492884c2162
size   1187801280
```

Perplexity nur mit `bench/ppl-corpus.txt` (sha256
`e38278b03fa41f75d843cea8125ab5819ff685304ab13b6feb62a1abc848f2f5`, 115031
Bytes) bei `-c 512` — sonst nicht vergleichbar.

### Zwei Engines, feste Zuordnung

Seit der zweiten Laptop-Runde gibt es eine zweite Engine: llama.cpp Tag
`b10524` (Commit `9ee9fc04c136ef2ae729bfc60d18961b23c13ddf`), Build mit
`GGML_VULKAN=ON` unter `engines/llama.cpp-vulkan/` (Submodul des vulkan-ed-Repos). Sie existiert, weil die
gepinnte b3962 die Architekturen von Qwen3, Phi-4 und Gemma-3 nicht kennt
und kein taugliches Vulkan hat. Die Zuordnung ist fest:

- **BitNet i2_s → nur die gepinnte BitNet-Engine** (`engines/BitNet`). Auf der
  neuen Engine ist i2_s kaputt (der `Q1_0`-Defekt aus Abschnitt oben).
- **Qwen3/Phi-4/Gemma-3 → nur b10524**, CPU wie GPU.
- **Llama-3.2-3B läuft auf beiden** und dient als Brücke: tg64 13.64 (b3962)
  gegen 12.22 (b10524), pp128 36.73 gegen 49.30 — Zahlen über die
  Engine-Grenze hinweg nie ohne diese Verschiebung vergleichen.

## Ausserhalb des Rahmens — Entscheidungen des Projektinhabers (20.08.2026)

- **Keine Fehlerberichte an fremde Projekte.** Die zwei belegten Defekte der
  BitNet-Auslieferung (fehlendes `tokenizer.ggml.pre`, kaputtes Chat-Template
  im GGUF) werden **nicht** an microsoft/BitNet gemeldet. Die technische
  Dokumentation in `results/` bleibt bewusst erhalten. Dasselbe gilt für
  colibri und jedes andere fremde Repo — bitte nicht erneut vorschlagen.
- **Keine Läufe auf weiterer Hardware.** Der Wunsch nach einem dritten Lauf auf
  einer AVX512-Maschine ist gestrichen; es bleibt bei den zwei vorhandenen
  Maschinen. Die GPUs des Laptops sind inzwischen gemessen (siehe
  `results/linux-i7-8850H-gpu-und-neue-modelle.md`): die Quadro P1000 lohnt
  sich für Q4-Modelle via Vulkan, die UHD 630 ist unbrauchbar und wird nicht
  erneut angefasst. Unverändert gilt: **für BitNet und colibri nützt eine GPU
  nichts** — die i2_s-Kernel sind CPU-only, BitNets `gpu/`-Pfad ist ein
  eigenes Projekt (eigene Konvertierung, `compute_80`; die P1000 ist
  `compute_61`, das CUDA-13-Toolkit kann Pascal ohnehin nicht mehr) und
  colibris CUDA-Backend lädt laut `docs/cuda.md` nur residente Tensoren.
- **Kein weiterer Windows-Lauf.** Die dort fehlende Perplexity-Messung entfällt
  bewusst: Perplexity misst Modell und Engine, nicht die Hardware. Bei
  bytegleichem Modell und gepinnter Engine gelten die Linux-Werte (BitNet
  11.19, Llama 8.86) für beide Maschinen; Compiler-Unterschiede bewegen
  allenfalls Nachkommastellen (siehe „±1" unten).

## Bewusst nicht untersucht

- **Warum die neue Engine i2_s zerlegt.** Irgendwo zwischen b3962 und b9918
  hat sich das Lesen der ternären Tensoren geändert; der Ladepfad ist nicht
  untersucht. Reizvoll aus Neugier — praktisch nicht nötig, solange die Engine
  gepinnt ist.
- **Die ±1-Abweichung bei der Werkzeugwahl** (Windows 8/10, Linux 9/10, gleiche
  Engine, bytegleiches Modell). Prompttext und AVX-VNNI sind als Ursachen
  **widerlegt** (Byte-Vergleich via `bench/test_prompts.py`; eigens gebaute
  Engine mit `-mno-avxvnni`, Ergebnis unverändert). Übrig: Compiler,
  Optimierung, Mathematikbibliothek. Als Warnung notiert: Werkzeugquoten können
  zwischen Maschinen um ±1 schwanken, auch bei identischem Modell und
  identischer Engine.

## Nicht erneut aufrollen

- **`ggml-bitnet-mad.cpp` wird übersetzt.** Der Verdacht, ein doppeltes `set()`
  in `src/CMakeLists.txt` mache die Datei tot, stimmt für den gepinnten Stand
  nicht: ggmls eigenes `CMakeLists.txt` zieht beide Quelldateien mit festem
  Pfad ein, und der Build scheitert ohne `patches/bitnet-mad-const-y_col.patch`
  genau an dieser Datei. Details in `patches/README.md`.
- **Die Leerzeilen-Empfindlichkeit** aus dem Windows-Bericht war ein Symptom
  des fehlenden Pre-Tokenizers, kein Modellverhalten. Mit Override 9/10 in
  beiden Promptfassungen.
- **`setup/linux.sh` baute anfangs nur Bibliotheken.** llama.cpp setzt
  `LLAMA_BUILD_COMMON/TOOLS/EXAMPLES` als Submodul auf OFF; die Optionen stehen
  jetzt im Skript, mit Existenzprüfung der Programme.
- **Die Prompt-Glättung im OLMoE-Läufer** kostete zwei von zehn Aufgaben
  (Werkzeugliste ohne Trennzeichen). Behoben durch `TOOL_SYSTEM_ONELINE`,
  abgesichert durch `bench/test_prompts.py`.
- **Die widerlegte AVX-VNNI-Hypothese** hat einen Build gekostet; ohne diese
  Notiz kostet sie den nächsten noch einmal.

## Arbeitsregeln

- **Jede Zahl braucht Engine-Commit, Submodul-Commit und Modell-sha256.** Der
  erste Linux-Lauf ist genau daran gescheitert: gegen eine andere Engine
  gemessen, Unterschied der Hardware zugeschrieben.
- **Prompttext gehört in `tasks.py`, nicht in den Läufer.** Zweimal ist beim
  Portieren daran etwas verrutscht; beide Male sah es nach Modellverhalten aus.
- **Fremde Befunde nachmessen, nicht übernehmen.** Der Tokenizer-Befund hat
  sich bestätigt, der CMake-Befund nicht — beide kamen aus demselben Bericht.
- **Negative Ergebnisse aufschreiben.**
