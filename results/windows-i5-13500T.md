# Referenzlauf — Windows 11, i5-13500T

Alles am 19.08.2026 gemessen. Diese Datei ist die Vergleichsbasis; ein Lauf auf
anderer Hardware gehoert als eigene Datei daneben.

> **Korrektur vom 20.08.2026.** Die urspruengliche Fassung dieser Datei deutete
> BitNets 4/10 bei der Werkzeugwahl als Modelleigenschaft. Das war falsch: die
> Ursache ist ein fehlendes Metadatenfeld in der GGUF-Datei. Mit korrigiertem
> Pre-Tokenizer trifft BitNet auf dieser Maschine **8/10** statt 4/10. Der
> Befund stammt aus `linux-i7-8850H.md` und wurde hier unabhaengig nachgemessen.
> Alle Durchsatzzahlen bleiben unveraendert gueltig. Die betroffenen Abschnitte
> sind unten kenntlich gemacht.

## Engine und Modell — die exakten Kennungen

Diese Angaben fehlten in der ersten Fassung. Genau daran ist der Linux-Lauf
zunaechst gescheitert: `setup/linux.sh` klonte ungepinnt und baute eine voellig
andere Engine, mit der das Modell unbrauchbar ist. Ohne diese Zeilen ist ein
Messwert nicht nachvollziehbar.

| | |
|---|---|
| BitNet-Commit | `01eb415772c342d9f20dc42772f1583ae1e5b102` (10.03.2026) |
| llama.cpp-Submodul | `1f86f058de0c3f4098dedae2ae8653c335c868a1` |
| Versionszeile der Binaerdatei | `version: 3962 (1f86f058)` |
| CMake-Optionen | `-DBITNET_X86_TL2=OFF -DLLAMA_CURL=OFF`, Ninja, Release |
| Patch | `patches/bitnet-mad-const-y_col.patch` angewendet |
| Modelldatei | `ggml-model-i2_s.gguf`, 1 187 801 280 Bytes |
| Modell-sha256 | `4221b252fdd5fd25e15847adfeb5ee88886506ba50b8a34548374492884c2162` |
| Vergleichsmodell | `Llama-3.2-3B-Instruct-Q4_K_M.gguf` (bartowski), 2 019 377 696 Bytes |

Der sha256 ist identisch mit dem des Linux-Laufs — beide Berichte vermessen
nachweislich dieselbe Datei auf derselben Engine. Unterschiede in den
Ergebnissen sind damit auf die Hardware eingegrenzt.

## Maschine

| | |
|---|---|
| CPU | 13th Gen Intel Core i5-13500T — 6 P-Cores + 8 E-Cores, 20 Threads, 1.6 GHz Basis, 35 W |
| Befehlssaetze | AVX2, AVX-VNNI, FMA, F16C — **kein** AVX512 |
| RAM | 16 GB |
| GPU | Intel UHD 770 — kein CUDA, alles lief auf der CPU |
| Platte | 476 GB SSD |
| OS | Windows 11 Pro 10.0.26200 |

Toolchain: clang 22.1.7 (`mingw-mstorsjo-llvm-msvcrt`, Ziel `x86_64-w64-windows-gnu`),
Ninja 1.13.2, CMake 4.3.3. Kein Visual Studio installiert.

## Durchsatz

`llama-bench`, jeweils `-p 128 -n 64 -r 2 --mmap 0`. Vorgabe von llama.cpp waere
`-t 20`; das ist auf dieser CPU die schlechteste Wahl.

| Modell | Datei | Threads | Generierung (tg64) | Prompt (pp128) |
|---|---|---|---|---|
| BitNet-b1.58-2B-4T i2_s | 1.1 GB | 4 | **8.93 ± 0.04** | 64.2 ± 7.4 |
| " | | 8 | 7.73 ± 0.39 | 93.9 ± 3.0 |
| " | | 12 | 6.48 ± 1.21 | **95.5 ± 2.9** |
| " | | 16 | 6.08 ± 0.35 | 54.4 ± 6.1 |
| " | | 20 | 5.84 ± 0.30 | 40.4 ± 24.9 |
| bitnet_b1_58-large i2_s | 257 MB | 4 | **23.05 ± 6.09** | **340.6 ± 16.9** |
| " | | 8 | 11.46 ± 0.02 | 250.4 ± 32.9 |
| Llama-3.2-3B-Instruct Q4_K_M | 2.2 GB | 4 | 6.46 ± 0.31 | 17.0 ± 0.3 |
| " | | 8 | **6.68 ± 0.21** | **28.4 ± 1.1** |
| " | | 12 | 6.24 ± 0.07 | 27.8 ± 0.1 |
| OLMoE-1B-7B int8, colibri | 7.4 GB | 14 (OpenMP) | **4.21** (Steigungsmessung) | — |

Beobachtungen:

- **Mehr Threads schaden der Generierung.** 4 → 20 Threads kostet BitNet ein
  Drittel Durchsatz. E-Cores und SMT bringen bei speicherlatenz-gebundener
  Dekodierung nichts und stoeren die Lastverteilung. Nur die
  Prompt-Verarbeitung skaliert, und auch die nur bis 12.
- **BitNet gegen gewoehnliche 4-Bit-Quantisierung**, gleiche Engine, gleicher
  Build: 1.34x bei der Generierung (8.93 gegen 6.68), 3.4x beim Prompt
  (95.5 gegen 28.4). Der Vorteil aus dem Paper ist real. Zu beachten: 2.4 B
  gegen 3.6 B Parameter, also kein reiner Kernel-Vergleich.
- **colibri ist hier nicht plattengebunden.** `coli doctor` meldet volle
  Expert-Residenz im RAM und 100 % projizierte Trefferrate; Peak-RSS 5.49 GB.
  Die Streaming-Idee, wegen der colibri existiert, greift bei einem 7-B-Modell
  auf 16 GB RAM gar nicht — sie zahlt sich erst bei den grossen Modellen aus,
  und die passen hier nicht auf die Platte.

## Werkzeugwahl (`bench/agent_eval.py`)

Zehn Aufgaben, fuenf definierte Werkzeuge, `temperature=0`.

| Modell | gueltiges JSON | richtiges Werkzeug |
|---|---|---|
| **BitNet-2B-4T + `llama-bpe`** | **10/10** | **8/10** |
| Llama-3.2-3B Q4_K_M | 10/10 | **9/10** |
| BitNet-b1.58-2B-4T ohne Override | 9/10 | 4/10 |
| OLMoE-1B-7B int8 (colibri) | **10/10** | 4/10 |

### Die 4/10 sind ein GGUF-Defekt, keine Modelleigenschaft

Dem ausgelieferten `ggml-model-i2_s.gguf` fehlt das Feld `tokenizer.ggml.pre`.
llama.cpp nimmt ersatzweise `default`, richtig waere `llama-bpe` — BitNet-b1.58
benutzt den Llama-3-Tokenizer. Die Folge ist eine andere Zerlegung genau an den
Bezeichnern, um die es geht: `read_file` wird zu `read`+`_`+`file` statt
`read`+`_file`. Das Modell muss Werkzeugnamen aus Bruchstuecken zusammensetzen
und verschreibt sich dabei.

Nachgemessen auf dieser Maschine, gleiche Engine, gleiche Modelldatei, einziger
Unterschied `--override-kv tokenizer.ggml.pre=str:llama-bpe`:

| | gueltiges JSON | richtiges Werkzeug |
|---|---|---|
| ohne Override | 9/10 | 4/10 |
| **mit Override** | **10/10** | **8/10** |

Drei Laeufe je Variante, jeweils identisch. Saemtliche unten dokumentierten
Verstuemmelungen verschwinden vollstaendig.

**Abweichung zum Linux-Lauf:** dort 9/10 statt 8/10, bei identischer Engine und
bytegleicher Modelldatei. Es ist dieselbe Zusatzaufgabe — Nr. 4, „Find every
place where TODO appears under ./app" → `list_dir` statt `search`. Ein
unterschiedlicher Aufruf wurde als Ursache ausgeschlossen (mit und ohne `-tb`
gemessen, beide Male 8/10).

Zwei Erklaerungen geprueft, beide ausgeschieden:

1. **Prompttext.** Der Linux-Lauf hat `TOOL_SYSTEM` in `tasks.py` umgebaut
   (Schleife statt Handausrichtung). Der erzeugte Text ist nachgerechnet
   zeichengleich mit der Fassung, auf der die Windows-Zahlen beruhen;
   `bench/test_prompts.py` sichert das ab.
2. **AVX-VNNI.** Naheliegende Vermutung: der i5-13500T hat es, der i7-8850H
   nicht — anderer Kernel, andere Rundung, anderes Argmax bei knappem Logit.
   Dafuer wurde eine zweite Engine mit `-mno-avxvnni` gebaut
   (`system_info: AVX_VNNI = 0` bestaetigt). Ergebnis: **weiterhin 8/10**, und
   die Ausgaben sind zeichengleich mit dem VNNI-Build. **Widerlegt.**

Damit bleibt die Ursache **offen**. Uebrig als Kandidaten: unterschiedliche
Compiler (clang 22.1.7 MinGW gegen clang 21.1.8 auf Fedora), abweichende
Optimierung oder Mathematikbibliothek. Praktisch ist die Abweichung eine
einzelne Aufgabe an einem knappen Logit und aendert an keiner Aussage etwas —
sie ist als Warnung notiert, dass Werkzeugquoten zwischen Maschinen um ±1
schwanken koennen, auch bei bytegleichem Modell und gleicher Engine.

### Die Fehlerbilder ohne Override

Historisch, denn mit korrektem Tokenizer treten sie nicht mehr auf. Die beiden
Viertel — BitNet und OLMoE — sahen gleich aus und waren es nicht:

**BitNet scheitert an der Syntax.** Werkzeugnamen zerfallen beim Tokenisieren:

```
{"tool": "read__file", "args": {"path": "README.md"}}      erwartet read_file
{"tool": "write_ file", "args": {"path": "notes.txt", ...}} erwartet write_file
{"tool": "list_dir", "args": {...}}                         Platzhalter woertlich uebernommen
{"tool": "read_ftp", "args": {"path": "/etc/hosts"}}        Werkzeug frei erfunden
```

**OLMoE scheitert an der Auswahl.** Syntaktisch tadellos, 10 von 10 — und dann
sechsmal `read_file`, egal was gefragt war:

```
"Run the unit tests with pytest."          -> read_file("example.txt")
"List everything in the current directory" -> read_file(".")
"Find every place where TODO appears"      -> read_file("./app/TODO")
"Install the dependencies with npm install"-> npm(command="install", ...)   erfunden
```

Fuer den Einsatz ist der Unterschied wesentlich: BitNets Fehler faengt ein
Parser ab (unbekannter Werkzeugname → Wiederholung). OLMoEs Fehler ist ein
gueltiger Aufruf des falschen Werkzeugs — der Agent liest eine Datei statt die
Tests zu starten und laeuft weiter. Stiller Fehler, teurer zu finden.

Nach der Tokenizer-Korrektur trifft diese Gegenueberstellung nicht mehr BitNet
gegen OLMoE, sondern nur noch OLMoE. BitNet macht beide Fehlerarten nicht mehr.

## Eine Leerzeile halbiert BitNets Trefferquote

Beim Portieren des Testgeschirrs von PowerShell nach Python ist im System-Prompt
versehentlich eine Leerzeile verschwunden — die zwischen „…and no others:" und
der Werkzeugliste. Sonst kein Zeichen anders. Ergebnis:

| System-Prompt | BitNet-2B-4T | Llama-3.2-3B Q4 |
|---|---|---|
| mit Leerzeile | 4/10 | 9/10 |
| ohne Leerzeile (`--compact-system`) | **2/10** | 9/10 |

Je zwei Läufe pro Variante, alle vier reproduzierbar identisch. Es ist also kein
Rauschen, sondern Empfindlichkeit gegen die Formatierung des Prompts — und sie
trifft nur BitNet. Llama liefert in beiden Varianten dasselbe.

Der Anteil gültigen JSONs bleibt bei 9/10; es kippt ausschliesslich die
Werkzeugwahl. Praktisch heisst das: eine Zahl wie „4/10" ist für BitNet keine
Modelleigenschaft, sondern gilt für genau diese Promptfassung. Wer damit
arbeiten will, muss den Prompt festnageln und jede Änderung neu messen.

> **Nachtrag vom 20.08.2026.** Auch das war ein Symptom des fehlenden
> Pre-Tokenizers, nicht des Modells. Der Linux-Lauf hat beide Promptfassungen
> mit `llama-bpe` wiederholt: **9/10 in beiden**, die Empfindlichkeit ist
> vollstaendig weg. Das passt zur Erklaerung — ein Modell, das Bezeichner aus
> Bruchstuecken zusammensetzen muss, haengt an jeder Formatierungskleinigkeit;
> eines, das sie als Token sieht, nicht.
>
> Die Schlussfolgerung des Absatzes bleibt als Arbeitsregel trotzdem richtig:
> der Prompttext gehoert festgenagelt. Sie gilt nur nicht mehr als Aussage
> ueber BitNet.

Nachstellen:

```bash
python3 bench/agent_eval.py --port 8080 --label mit
python3 bench/agent_eval.py --port 8080 --label ohne --compact-system
```

## Stichproben (`bench/probe.py`)

| Aufgabe | BitNet + `llama-bpe` | BitNet ohne Override | Llama-3.2-3B Q4 | OLMoE (colibri) |
|---|---|---|---|---|
| Quicksort in Python | korrekt | korrekt | korrekt | korrekt |
| Hauptstadt CH, ein Wort GROSS | `ZURICH` — falsch | `Bern` — Format ignoriert | `BERN` | `GENEVA` — falsch |
| Wechselgeld (21 Stifte, 3 fuer 5, aus 50) | **`15` — richtig** | `27.33` — falsch | `15` — richtig | keine Antwort, wich auf Python-Code aus |
| Deutsch, zwei Saetze zu DB-Index | verstaendlich, redundant | unbrauchbar | sauber | geschwaetzig, halb richtig |

Der Rechenweg wird durch die Tokenizer-Korrektur richtig: ohne Override rundet
BitNet 5/3 auf 1.67 und multipliziert, Ergebnis 27.33. Mit Override rechnet es
21/3 = 7 Packungen à 5 Franken = 35, also 15 Franken zurueck — Wort fuer Wort
dieselbe Herleitung wie im Linux-Lauf.

Die Hauptstadt ist die einzige Stichprobe, die sich durch die Korrektur
**verschlechtert**: ohne Override `Bern` (inhaltlich richtig, Format ignoriert),
mit Override `ZURICH` (Format richtig, Inhalt falsch). Auch das deckt sich mit
dem Linux-Lauf.

Markdown-Zaeune ignorieren alle drei, obwohl im System-Prompt ausdruecklich
verboten. Der Auswerter entfernt sie deshalb, bevor er JSON parst — sonst
misst man Formatierungsgehorsam statt Werkzeugwahl.

## Perplexity — noch nicht gemessen

Auf dieser Maschine steht die Perplexity-Messung noch aus. Wer sie nachholt,
nimmt zwingend das Korpus aus dem Repo, `bench/ppl-corpus.txt` (sha256
`e38278b03fa41f75d843cea8125ab5819ff685304ab13b6feb62a1abc848f2f5`, 115031
Bytes), mit `-c 512` — nur dann sind die Zahlen mit dem Linux-Lauf
(BitNet 11.19, Llama 8.86) vergleichbar. Fuer BitNet gilt auch hier der
Pre-Tokenizer-Override; Details in `results/linux-i7-8850H.md`.

## Windows-Eigenheiten, die auf Linux wegfallen

Alles hiervon ist Windows-spezifisch und sollte auf dem Laptop kein Thema sein:

1. `sentencepiece` liess sich nicht bauen: Python 3.14 hat kein Wheel, und der
   Quellbau stirbt an CMake 4.3.3 (`Compatibility with CMake < 3.5 has been
   removed`). Loesung war eine venv mit Python 3.12.
2. `setup_env.py` erzwingt unter Windows `cmake -T ClangCL`, also Visual Studio.
   Ohne VS bleibt nur der Weg ueber Ninja und MinGW-clang von Hand.
3. Uebersetzungsfehler in `ggml-bitnet-mad.cpp` — siehe `patches/`. Der trifft
   **auch Linux**, weil er nur vom Compiler abhaengt, nicht vom OS.
4. `error while loading shared libraries: libomp.dll` — die MinGW-Runtime muss
   neben die Binaerdateien kopiert werden (`libomp`, `libc++`, `libunwind`,
   `libwinpthread-1`).
5. `llama_model_load: error loading model: PrefetchVirtualMemory unavailable` —
   der MinGW-Build erkennt die API nicht. Deshalb ueberall `--no-mmap`. Auf
   Linux nicht noetig, und ohne mmap laedt das Modell langsamer.
