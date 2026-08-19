# Referenzlauf — Windows 11, i5-13500T

Alles am 19.08.2026 gemessen. Diese Datei ist die Vergleichsbasis; ein Lauf auf
anderer Hardware gehoert als eigene Datei daneben.

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
| Llama-3.2-3B Q4_K_M | 10/10 | **9/10** |
| BitNet-b1.58-2B-4T | 9/10 | 4/10 |
| OLMoE-1B-7B int8 (colibri) | **10/10** | 4/10 |

Die beiden Viertel sehen gleich aus und sind es nicht:

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

Nachstellen:

```bash
python3 bench/agent_eval.py --port 8080 --label mit
python3 bench/agent_eval.py --port 8080 --label ohne --compact-system
```

## Stichproben (`bench/probe.py`)

| Aufgabe | BitNet-2B-4T | Llama-3.2-3B Q4 | OLMoE (colibri) |
|---|---|---|---|
| Quicksort in Python | korrekt | korrekt | korrekt |
| Hauptstadt CH, ein Wort GROSS | `Bern` — Format ignoriert | `BERN` | `GENEVA` — falsch |
| Wechselgeld (21 Stifte, 3 fuer 5, aus 50) | `27.33` — falsch | `15` — richtig | keine Antwort, wich auf Python-Code aus |
| Deutsch, zwei Saetze zu DB-Index | unbrauchbar | sauber | geschwaetzig, halb richtig |

BitNets Rechenfehler ist lehrreich: es rundet 5/3 auf 1.67 und multipliziert,
statt 21/3 = 7 Packungen à 5 Franken zu rechnen. Llama nimmt denselben Weg,
rundet aber im richtigen Moment.

Markdown-Zaeune ignorieren alle drei, obwohl im System-Prompt ausdruecklich
verboten. Der Auswerter entfernt sie deshalb, bevor er JSON parst — sonst
misst man Formatierungsgehorsam statt Werkzeugwahl.

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
