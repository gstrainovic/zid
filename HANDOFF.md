# Handoff — Stand 20.08.2026

Gerichtet an den nächsten Lauf, gleich auf welcher Maschine. Ersetzt den
Handoff vom 19.08., der zur Übergabe des ersten Linux-Laufs geschrieben wurde
und inzwischen überholt ist; sein Inhalt steckt in `results/linux-i7-8850H.md`
und in den unten genannten Korrekturen.

Zwei Läufe sind abgeschlossen und liegen in `results/`. Der Branch des
Linux-Laufs ist nach `main` gemerged, seine Befunde sind auf Windows
nachgeprüft. Was jetzt noch offen ist, steht unter „Offene Punkte".

---

## 1. Was du wissen musst, bevor du irgendetwas misst

Beide Punkte haben je einen halben Messtag gekostet. Sie sind in
`setup/linux.sh` automatisiert, aber wer von Hand baut, muss sie kennen.

### Die Engine ist gepinnt, und das ist keine Vorsicht

```
BitNet             01eb415772c342d9f20dc42772f1583ae1e5b102
llama.cpp-Submodul 1f86f058de0c3f4098dedae2ae8653c335c868a1   (b3962)
```

Der heutige Stand von `microsoft/BitNet` zeigt mit seinem Submodul auf einen
Fork-Branch (`release-bitnet-embedding-0.6b-270m`), benannt nach einem anderen
Modell. Damit ist BitNet-b1.58-2B-4T unbenutzbar: korrekte Antwort, dann
Endlosschleife, Perplexity ×3.7, Werkzeugwahl 0/10.

**Der Durchsatz bleibt dabei unauffällig** — 21–24 tok/s, plausible Zahlen. Wer
nur Geschwindigkeit misst, merkt nichts. Deshalb vor jeder Messung:

```bash
./build/bin/llama-bench -m <i2_s.gguf> -p 8 -n 8 -r 1
```

`I2_S - 2 bpw ternary` in der Modellspalte heisst brauchbar. `Q1_0` heisst: nicht
messen. (Die dort ebenfalls abweichenden Grössenangaben sind ein Anzeigefehler
von `llama-bench`, kein Defekt — `llama-server` meldet auf beiden Engines
übereinstimmend 1.10 GiB / 2.41 B.)

### BitNet braucht den Pre-Tokenizer-Override

```
--override-kv tokenizer.ggml.pre=str:llama-bpe
```

Dem ausgelieferten GGUF fehlt das Feld. llama.cpp nimmt `default`, richtig wäre
`llama-bpe`. Ohne den Override zerfällt `read_file` in `read`+`_`+`file`, das
Modell setzt Werkzeugnamen aus Bruchstücken zusammen und verschreibt sich. Die
Trefferquote fällt von 8–9/10 auf 4/10, die Perplexity steigt.

Das gilt **nur für BitNet**. Llama-3.2-3B ist nicht betroffen.

---

## 2. Was gemessen ist

| | Windows i5-13500T | Linux i7-8850H |
|---|---|---|
| BitNet tg64 / pp128 | 8.93 / 95.5 | 22.44 / 175.4 |
| Llama-3B tg64 / pp128 | 6.68 / 28.4 | 13.64 / 36.7 |
| OLMoE (colibri) | 4.21 | 11.94 |
| BitNet Werkzeug (mit Override) | 8/10 | 9/10 |
| Llama-3B Werkzeug | 9/10 | 9/10 |
| OLMoE Werkzeug | 4/10 | 4/10 |
| Perplexity (eigenes Korpus) | — | BitNet 11.19, Llama 8.86 |
| Stichproben `probe.py` | alle drei | alle drei |

Beide Läufe benutzen nachweislich dieselbe Modelldatei:

```
sha256 4221b252fdd5fd25e15847adfeb5ee88886506ba50b8a34548374492884c2162
size   1187801280
```

---

## 3. Offene Punkte

Nach Nutzen sortiert.

### 3.1 Warum die neue Engine i2_s zerlegt

Der Ladepfad ist nicht untersucht. Die interessanteste technische Frage im
ganzen Projekt: irgendwo zwischen b3962 und b9918 hat sich das Lesen der
ternären Tensoren geändert. Reizvoll aus Neugier — praktisch nicht nötig,
solange die Engine gepinnt ist.

### 3.2 Perplexity auf Windows

Die Messung selbst fehlt; sie braucht die Windows-Maschine. Das Korpus liegt
seit dem 20.08. im Repo: `bench/ppl-corpus.txt` (sha256
`e38278b03fa41f75d843cea8125ab5819ff685304ab13b6feb62a1abc848f2f5`, 115031
Bytes — 115 KB englischer Fliesstext aus `.md`-Dateien von llama.cpp und
BitNet, 61 Chunks bei `-c 512`). Beide `results/`-Dateien verweisen darauf.

**Ohne exakt diese Datei sind die Zahlen nicht vergleichbar.** Wer misst:
gepinnte Engine, für BitNet den Pre-Tokenizer-Override (Abschnitt 1), `-c 512`,
dann gegen die Linux-Werte 11.19 (BitNet) / 8.86 (Llama) stellen.

### 3.3 Die ±1-Abweichung bei der Werkzeugwahl

Windows 8/10 gegen Linux 9/10, gleiche Engine, bytegleiches Modell, dieselbe
Zusatzaufgabe (Nr. 4). Zwei Erklärungen wurden geprüft und **beide scheiden
aus**: der Prompttext (nachgerechnet zeichengleich, durch
`bench/test_prompts.py` gesichert) und AVX-VNNI (eigens eine Engine mit
`-mno-avxvnni` gebaut, `AVX_VNNI = 0` bestätigt, Ergebnis unverändert 8/10).

Übrig als Kandidaten: verschiedene Compiler (clang 22.1.7 MinGW gegen clang
21.1.8 Fedora), Optimierung, Mathematikbibliothek. Praktisch belanglos — eine
Aufgabe an einem knappen Logit — aber als Warnung notiert: Werkzeugquoten können
zwischen Maschinen um ±1 schwanken, auch bei identischem Modell und identischer
Engine. Wer es weiterverfolgen will, vergleicht die Logits der betroffenen
Aufgabe direkt statt der Endergebnisse.

### 3.4 Ein dritter Lauf wäre aussagekräftig

Beide bisherigen CPUs haben AVX2, aber **kein AVX512**. Eine Maschine mit
AVX512 (Zen 4/5, Xeon, Ice Lake und neuer) würde zeigen, ob BitNets Vorsprung
gegen Q4 mit breiteren Vektoren wächst oder schrumpft. Das ist die grösste
offene Wissenslücke.

Ebenfalls unbeantwortet: **eine NVIDIA-GPU nützt hier nichts.** Die i2_s-Kernel
in diesem Build sind CPU-only; BitNets `gpu/`-Pfad ist ein eigenes Projekt
(eigene Konvertierung, `compute_80`, also Ampere aufwärts) und colibris
CUDA-Backend lädt laut `docs/cuda.md` nur residente Tensoren, nicht die
gestreamten Experten. Wer eine GPU testen will, misst damit llama.cpp mit
Q4-Modellen — nicht BitNet.

---

## 4. Ausserhalb des Rahmens

**Keine Fehlerberichte an fremde Projekte.** Die zwei belegten Defekte der
BitNet-Auslieferung — das fehlende `tokenizer.ggml.pre` und das kaputte
Chat-Template im GGUF — werden **nicht** an microsoft/BitNet gemeldet.
Entscheidung des Projektinhabers vom 20.08.2026.

Die technische Dokumentation bleibt bewusst erhalten: beide Defekte sind in
`results/` mit Messungen belegt und in Abschnitt 1 als Betriebsanweisung
festgehalten, weil man sie zum Messen kennen muss. Nur der Vorschlag, sie
upstream zu melden, entfällt — bitte nicht erneut als offenen Punkt aufführen.

Dasselbe gilt für colibri und jedes andere fremde Repo in diesem Projekt.

---

## 5. Was nicht mehr offen ist

Damit es niemand erneut aufrollt:

- **`ggml-bitnet-mad.cpp` wird übersetzt.** Der Linux-Lauf hatte das bestritten
  (doppeltes `set()` in `src/CMakeLists.txt` überschreibe die Quellenliste) und
  daraus geschlossen, `patches/bitnet-mad-const-y_col.patch` korrigiere eine
  tote Datei. Für den gepinnten Stand stimmt das nicht: ggmls eigenes
  `CMakeLists.txt` zieht beide Quelldateien mit festem Pfad ein, die Objektdatei
  ist 9941 Bytes gross, und der Build ist ohne den Patch genau an dieser Datei
  gescheitert. Details in `patches/README.md`.
- **Die Leerzeilen-Empfindlichkeit** aus dem Windows-Bericht war ein Symptom des
  fehlenden Pre-Tokenizers, kein Modellverhalten. Mit Override 9/10 in beiden
  Promptfassungen.
- **`setup/linux.sh` baute nur Bibliotheken.** Ursache: llama.cpp setzt
  `LLAMA_BUILD_COMMON/TOOLS/EXAMPLES` als Submodul auf OFF. Die drei Optionen
  sind jetzt im Skript, mit anschliessender Existenzprüfung der Programme.
- **Die Prompt-Glättung im OLMoE-Läufer** hat zwei von zehn Aufgaben gekostet
  (Werkzeugliste lief ohne Trennzeichen zu Fliesstext zusammen). Behoben durch
  `TOOL_SYSTEM_ONELINE`, abgesichert durch `bench/test_prompts.py`.

---

## 6. Arbeitsregeln, die sich bewährt haben

- **Jede Zahl braucht Engine-Commit, Submodul-Commit und Modell-sha256.** Der
  erste Linux-Lauf ist genau daran gescheitert: Die Windows-Ergebnisse nannten
  die Engine nicht, also wurde gegen eine andere gemessen und der Unterschied
  zunächst der Hardware zugeschrieben. Jede Datei in `results/` führt die drei
  Angaben inzwischen im Kopf.
- **Prompttext gehört in `tasks.py`, nicht in den Läufer.** Zweimal ist beim
  Portieren genau daran etwas verrutscht — einmal eine Leerzeile, einmal die
  Trennzeichen der Werkzeugliste. Beide Male sah es nach Modellverhalten aus.
- **Fremde Befunde nachmessen, nicht übernehmen.** Der Tokenizer-Befund hat
  sich bestätigt, der CMake-Befund nicht. Beide kamen aus demselben Bericht.
- **Negative Ergebnisse aufschreiben.** Die widerlegte AVX-VNNI-Hypothese hat
  einen Build gekostet; ohne Notiz kostet sie den nächsten noch einmal.
