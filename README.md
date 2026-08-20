# bitnet-colibri-bench

Ein kleines Messgeschirr für zwei Behauptungen, die beide „grosses Modell auf
kleiner Maschine" versprechen:

- **[microsoft/BitNet](https://github.com/microsoft/BitNet)** — ternäre 1.58-Bit-Modelle,
  eigene CPU-Kernel auf llama.cpp-Basis.
- **[JustVugg/colibri](https://github.com/JustVugg/colibri)** — MoE-Engine in reinem C,
  streamt Experten von der Platte.

Gemessen wird nicht nur Durchsatz, sondern auch, ob die Modelle als **Agent**
taugen — also Werkzeuge zuverlässig auswählen — denn dort entscheidet sich, ob
so etwas lokal einen Nutzen hat.

Der Referenzlauf steht in [`results/windows-i5-13500T.md`](results/windows-i5-13500T.md),
der zweite Lauf in [`results/linux-i7-8850H.md`](results/linux-i7-8850H.md).
**Das Projekt ist abgeschlossen** (20.08.2026); weitere Läufe sind nicht
geplant.

## Ergebnis in drei Zeilen

| Modell | Engine | i5-13500T (35 W) | i7-8850H | richtiges Werkzeug |
|---|---|---|---|---|
| BitNet-b1.58-2B-4T i2_s | llama.cpp, BitNet-Build | **8.9 tok/s** | **22.4 tok/s** | **8–9/10** |
| Llama-3.2-3B Q4_K_M | derselbe BitNet-Build | 6.7 tok/s | 13.6 tok/s | 9/10 |
| OLMoE-1B-7B int8 | colibri | 4.2 tok/s | 11.9 tok/s | 4/10 |

BitNet ist schnell **und** für Werkzeugwahl brauchbar — gleichauf mit dem
4-Bit-Modell bei 1.3–1.65-fachem Durchsatz und halber Dateigrösse. colibri ist
sauber gebaut und rechnet korrekt, aber die grossen Modelle, für die es
existiert, passen auf solche Maschinen nicht auf die Platte (GLM-5.2 int4:
372 GB); mit einem 7-B-Modell greift sein Streaming-Konzept gar nicht.

> **Zwei Dinge sind nicht optional, sonst misst man Unsinn.**
>
> 1. **Die Engine muss gepinnt sein** — BitNet `01eb415` mit llama.cpp-Submodul
>    `1f86f058`. Der heutige Klon zeigt auf einen Fork-Branch, mit dem
>    BitNet-b1.58-2B-4T degeneriert (Perplexity ×3.7, Endlosschleifen) — bei
>    **unauffälligem Durchsatz**. `setup/linux.sh` pinnt und prüft das.
> 2. **BitNet braucht `--override-kv tokenizer.ggml.pre=str:llama-bpe`** — dem
>    ausgelieferten GGUF fehlt das Feld. Ohne den Override zerfallen
>    Werkzeugnamen und die Trefferquote fällt von 8–9/10 auf 4/10.
>
> Beides ist in `results/` mit Belegen dokumentiert.

## Aufbau

```
bench/
  tasks.py         Aufgaben — eine Quelle für alle Läufer
  common.py        HTTP-Aufruf, JSON-Extraktion (nur Standardbibliothek)
  probe.py         6 Fähigkeitsstichproben  -> llama-server
  agent_eval.py    10 Werkzeugaufgaben      -> llama-server
  olmoe_eval.py    dieselben Aufgaben       -> colibris olmoe (stdin)
  olmoe_speed.py   Dekodier-Durchsatz per Steigungsmessung
  test_prompts.py  sichert den Prompttext ab (Byte-Gleichheit, beide Fassungen)
  windows/         die PowerShell-Fassungen des ersten Laufs
patches/           ein nötiger Fix an BitNet, mit Begründung
setup/linux.sh     baut beides, pinnt die Engine, prüft Modell und Engine
results/           je Maschine eine Datei
CLAUDE.md          Betriebswissen und getroffene Entscheidungen
```

Jede Datei in `results/` nennt **Engine-Commit, llama.cpp-Submodul-Commit und
den sha256 der Modelldatei**. Ohne die drei Angaben ist ein Messwert nicht
nachvollziehbar — genau daran ist der erste Linux-Lauf gescheitert.

Die Python-Skripte brauchen **keine Fremdpakete** — Standardbibliothek genügt,
damit auf dem Testrechner nichts zu installieren ist.

## Loslegen (Linux)

```bash
git clone <dieses-repo> && cd bitnet-colibri-bench
./setup/linux.sh ~/ki
```

Das holt und baut BitNet (mit Patch) und colibri, lädt BitNet-b1.58-2B-4T, das
Vergleichsmodell Llama-3.2-3B-Q4_K_M und konvertiert OLMoE. Rund 25 GB Platte,
je nach Leitung ein bis zwei Stunden. Danach:

```bash
cd ~/ki/BitNet

# Durchsatz. -t bewusst durchprobieren: die Vorgabe (alle Threads) ist
# auf Hybrid-CPUs regelmässig die schlechteste Einstellung.
./build/bin/llama-bench -m models/BitNet-b1.58-2B-4T/ggml-model-i2_s.gguf \
    -p 128 -n 64 -t 4,8,12,16 -r 2

# Qualität: Server starten, dann die zwei Läufer.
# --override-kv ist Pflicht, nicht Feinschliff — siehe Kasten oben.
./build/bin/llama-server -m models/BitNet-b1.58-2B-4T/ggml-model-i2_s.gguf \
    -t 4 -tb 12 -c 4096 --port 8080 \
    --override-kv tokenizer.ggml.pre=str:llama-bpe &
python3 ~/bitnet-colibri-bench/bench/agent_eval.py --port 8080 --label BitNet-2B-4T
python3 ~/bitnet-colibri-bench/bench/probe.py      --port 8080 --label BitNet-2B-4T

# Gegenprobe mit demselben Server-Binary, anderes Modell
./build/bin/llama-server -m models/_compare/Llama-3.2-3B-Instruct-Q4_K_M.gguf \
    -t 8 -c 4096 --port 8081 &
python3 ~/bitnet-colibri-bench/bench/agent_eval.py --port 8081 --label Llama-3.2-3B-Q4
```

colibri hat keinen OpenAI-Endpunkt, deshalb ein eigener Läufer:

```bash
python3 ~/bitnet-colibri-bench/bench/olmoe_eval.py \
    --engine ~/ki/colibri/c/olmoe --snap ~/ki/colibri/olmoe_merged
python3 ~/bitnet-colibri-bench/bench/olmoe_speed.py \
    --engine ~/ki/colibri/c/olmoe --snap ~/ki/colibri/olmoe_merged
```

## Warum so gemessen

**Werkzeugwahl getrennt von JSON-Syntax.** `agent_eval.py` zählt beides einzeln,
weil die Fehlerarten verschieden teuer sind. Ein kaputter Werkzeugname fällt dem
Parser auf und lässt sich wiederholen. Ein sauberer Aufruf des *falschen*
Werkzeugs läuft durch — der Agent tut etwas anderes als verlangt und merkt es
nicht. Genau darin unterscheiden sich BitNet und OLMoE, obwohl beide 4/10
treffen.

**Markdown-Zäune werden vor dem Parsen entfernt.** Kein getestetes Modell hält
sich an „no markdown fences". Bliebe das drin, misst man Formatierungsgehorsam
statt Werkzeugwahl.

**Der System-Prompt ist Teil der Messung.** Eine einzige entfernte Leerzeile
drückt BitNet von 4/10 auf 2/10, während Llama-3.2-3B unverändert 9/10 liefert
(`--compact-system` stellt es nach, Details in `results/`). Deshalb liegt der
Prompttext in `bench/tasks.py` und wird nicht je Läufer neu getippt — sonst
vergleicht man Promptfassungen statt Modelle.

**Durchsatz für colibri per Steigung.** `olmoe` gibt im Chat-Modus keine tok/s
aus, und der eingebaute Referenzlauf misst zwölf Token bei kaltem Expert-Cache.
`olmoe_speed.py` misst denselben Prompt mit zwei verschiedenen `MAX_NEW` und
teilt die Zeitdifferenz durch die Tokendifferenz; Laden, Prefill und
Cache-Aufwärmen fallen als konstanter Anteil heraus.

**Vergleichsmodell auf derselben Engine.** Llama-3.2-3B-Q4_K_M läuft über
dieselbe Binärdatei aus demselben Build. Sonst misst man Compilerflags.

## Bekannte Fallstricke

- **Der BitNet-Patch trifft auch Linux.** Er hängt am Compiler, nicht am OS:
  sobald `__AVX2__` gesetzt ist — also bei jedem clang/gcc-Build — bricht die
  Übersetzung ohne ihn ab. Siehe [`patches/README.md`](patches/README.md).
- **`setup_env.py` von BitNet nicht benutzen.** Es erzwingt unter Windows
  Visual Studio und macht auf Linux nur dieselben zwei cmake-Aufrufe, die
  `setup/linux.sh` direkt ausführt.
- **`--no-mmap` ist eine Windows-Krücke.** Der MinGW-Build erkennt
  `PrefetchVirtualMemory` nicht und weigert sich sonst, das Modell zu laden. Auf
  Linux weglassen, dann lädt das Modell schneller.
- **colibri braucht OpenMP zur Laufzeit.** Ein Build, den man auf eine andere
  Maschine kopiert, findet dort womöglich kein `libgomp.so.1` und beendet sich
  ohne Ausgabe. `coli doctor` benennt es.
- **OLMoE-Konvertierung ist wiederaufnehmbar.** Abbrechen ist ungefährlich,
  derselbe Aufruf macht dort weiter, wo er aufgehört hat.
