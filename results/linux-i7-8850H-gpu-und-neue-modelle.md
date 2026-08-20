# Zweite Runde auf dem i7-8850H — GPU und aktuelle Q4-Modelle

Lauf vom 20.08.2026, gleiche Maschine wie `linux-i7-8850H.md`. Auftrag des
Projektinhabers: die GPUs des Laptops ausmessen und aktuelle CPU-Modelle
(Qwen, Phi, Gemma) nachziehen; Windows bleibt aussen vor.

## Das Ergebnis vorweg

Der Laptop hat neben der Intel UHD 630 eine **NVIDIA Quadro P1000 Mobile**
(4 GB, Pascal) — und die verändert das Bild:

| Modell | Gerät | tg64 | pp128 | Werkzeug |
|---|---|---|---|---|
| Llama-3.2-3B Q4_K_M | **P1000** (Vulkan) | **24.07** | 134.6 | 9/10 |
| BitNet-b1.58-2B-4T i2_s | CPU (gepinnte Engine) | 22.44 | 175.4 | 9/10 |
| Qwen3-4B-2507 Q4_K_M | **P1000** (Vulkan) | 19.27 | 95.6 | **10/10** |
| Llama-3.2-3B Q4_K_M | CPU | 12.22–13.64¹ | 36.7–49.3¹ | 9/10 |
| Qwen3-4B-2507 Q4_K_M | CPU | 9.86 | 30.8 | **10/10** |
| Phi-4-mini Q4_K_M | CPU | 10.00 | 30.3 | **10/10** |
| Gemma-3-4B Q4_K_M | CPU | 9.64 | 34.3 | 8/10 |
| beliebiges Q4-Modell | UHD 630 (Vulkan) | 4.2–4.6 | 15–19 | — |

¹ je nach Engine, siehe „Brücke" unten.

Drei Sätze Fazit:

1. **Die P1000 schlägt BitNet.** Llama-3B auf der GPU (24.07 tok/s) liegt über
   BitNet auf der CPU (22.44) — bei gleicher Werkzeugquote 9/10 und frei
   bleibender CPU. BitNets Alleinstellung auf diesem Laptop fällt, sobald die
   GPU mitspielt; als **reine CPU-Option** bleibt BitNet unerreicht (22.4
   gegen 12.2 des nächstbesten).
2. **Qwen3-4B ist das zuverlässigste Agentenmodell des Projekts:** als erstes
   Modell 10/10 Werkzeugwahl, dazu alle sechs Stichproben fehlerfrei —
   einschliesslich der strikten Formatvorgabe, an der BitNet scheitert. Auf
   der P1000 läuft es mit brauchbaren 19.3 tok/s.
3. **Die iGPU ist nutzlos.** Die UHD 630 liegt bei einem Drittel der
   CPU-Generierung; es gibt keinen Grund, sie je wieder anzufassen.

## Engine und Modelle — die exakten Kennungen

Die neuen Modelle brauchen eine neue Engine: die gepinnte b3962 kennt die
Architekturen von Qwen3, Phi-4 und Gemma-3 nicht. Die gepinnte Engine bleibt
unangetastet und misst weiterhin BitNet; **BitNet läuft niemals auf der neuen
Engine** (i2_s-Defekt, siehe `CLAUDE.md`).

```
Engine   llama.cpp Tag b10524, Commit 9ee9fc04c136ef2ae729bfc60d18961b23c13ddf
Build    ~/ki/llama.cpp-vulkan/build — GGML_VULKAN=ON, Release, gcc 15.3.1
GPUs     Vulkan0 = Intel UHD 630 (Mesa, uma:1, fp16:1)
         Vulkan1 = Quadro P1000 (NVIDIA 580.178.04, uma:0, fp16:0, int dot:1)
```

Kein CUDA: das CUDA-13-Toolkit unterstützt Pascal nicht mehr, Vulkan ist der
verbleibende Weg zur P1000 — und er reicht.

| Modell | sha256 | Bytes | Quelle |
|---|---|---|---|
| Qwen3-4B-Instruct-2507-Q4_K_M | `3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597` | 2497281120 | unsloth/Qwen3-4B-Instruct-2507-GGUF |
| Phi-4-mini-instruct-Q4_K_M | `88c00229914083cd112853aab84ed51b87bdf6b9ce42f532d8c85c7c63b1730a` | 2491874272 | unsloth/Phi-4-mini-instruct-GGUF |
| gemma-3-4b-it-Q4_K_M | `882e8d2db44dc554fb0ea5077cb7e4bc49e7342a1f0da57901c0802ea21a0863` | 2489757856 | ggml-org/gemma-3-4b-it-GGUF |
| Llama-3.2-3B-Instruct-Q4_K_M | `6c1a2b41161032677be168d354123594c0e6e67d2b9227c84f296ad037c728ff` | 2019377696 | wie Runde 1 |

### Die Brücke zwischen den Engines

Llama-3.2-3B wurde auf beiden Engines auf der CPU gemessen, damit die Runden
vergleichbar bleiben:

| | b3962 (gepinnt) | b10524 (neu) |
|---|---|---|
| tg64 | **13.64** | 12.22 |
| pp128 | 36.73 | **49.30** |

Die neue Engine generiert auf dieser CPU ~10 % langsamer, verarbeitet Prompts
aber ein Drittel schneller. Wer Zahlen beider Runden vergleicht, muss diese
Verschiebung mitdenken; der GPU-Vorsprung der P1000 (24.07 gegen 12.22 auf
identischer Engine: **2.0×**) ist davon unberührt.

## Durchsatz

`llama-bench -p 128 -n 64 -r 2`, Engine b10524, unbelastete Maschine. (Eine
erste P1000-Reihe lief versehentlich parallel zum Engine-Build; die
Wiederholung auf ruhiger Maschine wich um <1.5 % ab — die diskrete GPU ist
gegen CPU-Last weitgehend immun. Gültig sind die Werte der ruhigen Maschine.)

### Quadro P1000, `-ngl 99`

| Modell | pp128 | tg64 |
|---|---|---|
| Llama-3.2-3B Q4_K_M | 134.64 ± 0.00 | **24.07 ± 0.01** |
| Qwen3-4B-2507 Q4_K_M | 95.60 ± 0.00 | 19.27 ± 0.00 |
| Phi-4-mini Q4_K_M | 113.33 ± 0.18 | 18.54 ± 0.00 |
| Gemma-3-4B Q4_K_M | 110.07 ± 0.01 | 19.31 ± 0.00 |

Alle vier Modelle passen samt Kontext in die 4 GB VRAM. Die Pascal-Karte kann
kein FP16 im Shader (`fp16:0`), hat aber Int-Dot-Instruktionen — für
Q4-Gewichte offenbar genug: die tg-Werte entsprechen fast exakt dem
Verhältnis der Speicherbandbreiten (GPU ~82 GB/s gegen Dual-Channel-DDR4).

### Intel UHD 630, `-ngl 99`

| Modell | pp128 | tg64 |
|---|---|---|
| Llama-3.2-3B | 19.48 ± 0.02 | 4.61 ± 0.00 |
| Qwen3-4B-2507 | 14.77 ± 0.04 | 4.22 ± 0.00 |
| Phi-4-mini | 17.28 ± 0.06 | 4.26 ± 0.00 |
| Gemma-3-4B | 16.98 ± 0.05 | 4.17 ± 0.00 |

Durchweg ein Drittel der CPU-Generierung und die Hälfte der CPU-Promptrate.
Die iGPU teilt sich die Speicherbandbreite mit der CPU und hat weniger
Rechenwerke — sie verliert auf beiden Achsen.

### CPU, neue Engine (`-dev none`, Threads 4/8/12)

| Modell | pp128 (bester) | tg64 (bester) |
|---|---|---|
| Llama-3.2-3B | 49.30 ± 0.19 (t4) | 12.22 ± 0.00 (t8) |
| Qwen3-4B-2507 | 30.79 ± 0.14 (t8) | 9.86 ± 0.02 (t8) |
| Phi-4-mini | 30.27 ± 0.02 (t8) | 10.00 ± 0.02 (t8) |
| Gemma-3-4B | 34.33 ± 0.16 (t8) | 9.64 ± 0.00 (t8) |

Die drei 4B-Modelle liegen dicht beieinander — erwartbar, sie sind
speicherbandbreitengebunden und praktisch gleich gross (2.31–2.32 GiB).

## Werkzeugwahl (`bench/agent_eval.py`)

Server: neue Engine, CPU, `-t 4 -tb 12 -c 4096 --jinja`, `temperature=0`.
Werkzeugwahl ist eine Modelleigenschaft; auf der GPU ändert sie sich nicht.

| Modell | gültiges JSON | richtiges Werkzeug |
|---|---|---|
| **Qwen3-4B-2507** | 10/10 | **10/10** |
| **Phi-4-mini** | 10/10 | **10/10** |
| Gemma-3-4B | 10/10 | 8/10 |
| *(Referenz Runde 1: BitNet 9/10, Llama-3B 9/10, OLMoE 4/10)* | | |

Qwen3 und Phi-4-mini sind die ersten Modelle des Projekts mit voller
Punktzahl. Gemmas zwei Fehlgriffe sind beide derselbe Typ: es wählt `search`,
wo `read_file` (Aufgabe 1) bzw. `run_shell` (Aufgabe 5) verlangt ist —
saubere JSON-Syntax, falsches Werkzeug, also genau die stille Fehlerart, die
der Test von der Syntax trennt. Phi-4-mini und Gemma zäunen die Antworten
mehrheitlich in Markdown ein (6/10 bzw. 10/10), Qwen3 nie; der Auswerter
entfernt die Zäune vor dem Parsen.

## Stichproben (`bench/probe.py`)

| | Qwen3-4B | Phi-4-mini | Gemma-3-4B |
|---|---|---|---|
| Werkzeug-JSON | sauber | sauber | sauber (im Zaun) |
| Quicksort | korrekt | korrekt | korrekt |
| „exactly one word, uppercase" | **BERN** ✓ | ZURICH ✗ | **BERN** ✓ |
| Deutsch (Index erklären) | gut, 1 Tippfehler | brauchbar, redundant | gut |
| Rechnung (erwartet 15) | 15 ✓ | 15 ✓ | 15 ✓ |
| Mehrschritt-Plan | 3 saubere Schritte | 3 saubere Schritte | 2 Schritte (read fehlt) |

Bemerkenswert: Phi-4-mini antwortet auf die Hauptstadtfrage `ZURICH` — Format
befolgt, Inhalt falsch, exakt das Fehlerbild von BitNet mit Override aus
Runde 1. Die Rechenaufgabe lösen erstmals alle Kandidaten einer Runde; Qwen3
rechnet über 105/3, Phi und Gemma über 7×5.

## Nachtrag: xLAM-2-1B — der Tool-Calling-Spezialist enttäuscht

Nachgemessen am 20.08. abends (TODO aus dem Agenten-Experiment): Salesforce
xLAM-2-1b-fc-r, ein eigens auf Function-Calling trainiertes Kleinmodell.
Basis laut Engine-Erkennung: Qwen2.5-1.5B (1.54 B Parameter).

```
Datei   xLAM-2-1B-fc-r-Q4_K_M.gguf
sha256  61eeb070aaae78ff1cbb16fecd14e35a624d792cb3592a6116a82dba92285aa3
Bytes   986048192      Quelle: Salesforce/xLAM-2-1b-fc-r-gguf
```

| | CPU (t8) | P1000 |
|---|---|---|
| pp128 | 132.29 ± 0.21 | 233.35 ± 0.00 |
| tg64 | 28.98 ± 0.01 | **45.33 ± 0.00** |

Mit Abstand das schnellste Modell des Projekts — und trotzdem keine
Empfehlung: **Werkzeugwahl 8/10** (eine leere Antwort, eine Verweigerung
mit der falschen Behauptung, kein Werkzeug passe), also schlechter als die
Generalisten BitNet/Llama (9/10) und Qwen3/Phi (10/10). Die Stichproben
sind deutlich: Formatvorgabe missachtet (`Bern` statt `BERN`), die
Rechenaufgabe grotesk falsch (rechnet 21 × 5 = 105 Franken für 21 Stifte,
verheddert sich in negativem Wechselgeld), Mehrschritt-Plan bricht nach
einem Schritt ab. Die Function-Calling-Spezialisierung ersetzt die
fehlende Allgemeinfähigkeit der 1.5B-Klasse nicht — für Agentenarbeit
zählt beides.

## Keine Perplexity in dieser Runde

Absichtlich. Das Korpus-Perplexity-Verfahren vergleicht nur bei identischer
Tokenisierung (siehe Runde 1); Qwen3, Phi-4 und Gemma-3 haben drei
verschiedene Tokenizer, deren Werte weder untereinander noch mit BitNet/Llama
vergleichbar wären. Die Fragen dieser Runde — Durchsatz und
Agententauglichkeit — beantworten Durchsatzmessung und Werkzeugwahl direkt.

## Was das für die Gesamtaussage des Projekts heisst

Die Empfehlung ist jetzt zweigeteilt:

- **Maschine mit brauchbarer diskreter GPU** (dieser Laptop): Q4-Modelle auf
  die GPU. Höchster Durchsatz: Llama-3B (24.1 tok/s, 9/10). Höchste
  Zuverlässigkeit: Qwen3-4B (19.3 tok/s, 10/10). BitNet ist hier nicht mehr
  die schnellste Option — und lässt zudem die GPU brachliegen.
- **Reine CPU-Maschine** (der Windows-Referenzrechner): BitNet bleibt
  unangefochten — 1.65× Durchsatz gegenüber dem nächstbesten bei
  gleichwertiger Werkzeugwahl. Wer dort 10/10 statt 9/10 will, zahlt mit
  Qwen3-4B einen Faktor 2.3 beim Durchsatz.

Die iGPU-Zahlen gelten als erledigt: Intel-Grafik dieser Generationen braucht
niemand mehr zu messen.
