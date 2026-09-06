# HANDOFF: bitnet-colibri-bench und ~/projects/ki nach vulkan-ed holen

Stand 06.09.2026. Entscheidung des Projektinhabers: Das Bench-Repo
`~/projects/bitnet-colibri-bench` und die Laufzeitumgebung `~/projects/ki`
werden nur noch im Zusammenhang mit vulkan-ed gebraucht und wandern deshalb
in dieses Verzeichnis und dieses Repo. `pi-mono` und `colibri` werden
gelöscht. Diese Datei wird nach Abschluss gelöscht; bleibendes Wissen kommt
in `AGENTS.md`.

## Warum nicht sofort: zwei Konflikte mit der laufenden Arbeit

1. Der Arbeitsbaum hier ist schmutzig (Fuzzy-Picker: `build.zig`,
   `src/e2e_server.zig`, `src/ui/mod.zig`, `src/ui/shortcuts.zig`, neu
   `src/ui/picker.zig`, `src/ui/fuzzy.zig`, `scripts/e2e_picker.py`).
   `git subtree add` verweigert einen schmutzigen Baum, und die Migration
   ändert zwei Zeilen in `src/ui/mod.zig`. **Erst die Picker-Arbeit
   committen, dann Phase 2.**
2. Ein llama-server läuft aus dem alten Pfad (`ps -eo pid,cmd | grep
   [l]lama-server`). Verschieben schadet ihm nicht (Rename hält offene
   Dateien), aber ein Neustart des Chats scheitert, bis die Pfade im Code
   stimmen. Deshalb Symlinks als Brücke (Phase 1), Codeänderung in Phase 2.

## Ausgangslage

```
~/projects/ki/BitNet               16 GB  microsoft/BitNet @ 01eb415, Submodul llama.cpp @ 1f86f05 (b3962)
                                          davon models/ 15.2 GB (nur GGUFs), lokal ungesichert:
                                          src/ggml-bitnet-mad.cpp = llm-bench/patches/bitnet-mad-const-y_col.patch
~/projects/ki/llama.cpp-vulkan     1.4 GB ggml-org/llama.cpp @ 9ee9fc0 (b10524), Build mit GGML_VULKAN=ON
~/projects/ki/colibri              7.9 GB nur für abgeschlossene OLMoE-Messungen        -> löschen
~/projects/ki/pi-mono              728 MB Fork des Pi-Agenten, Branch ist gepusht       -> löschen
~/projects/ki/bench-artifacts      768 KB Rohlogs des ersten Linux-Laufs                -> ins Repo
~/projects/bitnet-colibri-bench    1.2 MB Git-Repo, Remote github.com/gstrainovic/bitnet-colibri-bench
```

Zielstruktur in vulkan-ed:

```
llm-bench/                 das Bench-Repo per git subtree (Historie bleibt)
llm-bench/results/logs/    bench-artifacts
models/                    alle GGUFs flach (bereits per *.gguf ignoriert; dort liegt schon gemma-4)
engines/BitNet             Submodul, gepinnt 01eb415, .gitmodules mit ignore = dirty (Patch)
engines/llama.cpp-vulkan   Submodul, gepinnt 9ee9fc0
```

Modelle: Qwen3-4B-Instruct-2507 ist Pflicht (Standardmodell des Chats),
Llama-3.2-3B und `ggml-model-i2_s.gguf` (BitNet-Referenz) sind sinnvoll.
Die fünf reinen Bench-Modelle (Qwen3.5-4B, Qwen3.5-2B, xLAM, Gemma-3,
Phi-4-mini, rund 10 GB) hat der Projektinhaber noch nicht entschieden:
**mitnehmen, nicht löschen**, nur nachfragen, wenn Platz knapp wird
(aktuell 48 GB frei).

## Phase 1: ohne Berührung des Arbeitsbaums (sofort möglich)

Alles hier ist untracked oder liegt ausserhalb des Repos; `git status` in
vulkan-ed ändert sich nicht.

Modell-Layout (festgelegt): die sieben Vergleichs-GGUFs flach in `models/`,
das BitNet-Referenzmodell behält Ordner und Dateinamen als
`models/bitnet-b1.58-2B-4T/ggml-model-i2_s.gguf`. Die alten Pfade
`.../BitNet/models/_compare/<name>.gguf` (Chat, Serve-Skript) und
`.../BitNet/models/BitNet-b1.58-2B-4T/ggml-model-i2_s.gguf` (`linux.sh`)
bleiben über Symlinks gültig, bis Phase 2 die Pfade umstellt.

```bash
cd ~/projects/vulkan-ed
mkdir -p engines models/bitnet-b1.58-2B-4T

# Modelle (nur GGUFs im Quellordner, mit fd geprüft)
mv ~/projects/ki/BitNet/models/_compare/*.gguf models/
mv ~/projects/ki/BitNet/models/BitNet-b1.58-2B-4T/ggml-model-i2_s.gguf models/bitnet-b1.58-2B-4T/
rmdir ~/projects/ki/BitNet/models/_compare ~/projects/ki/BitNet/models/BitNet-b1.58-2B-4T

# Engines verschieben
mv ~/projects/ki/BitNet engines/BitNet
mv ~/projects/ki/llama.cpp-vulkan engines/llama.cpp-vulkan

# Brücken: alte Engine-Pfade und alte Modellpfade bleiben gültig
ln -s ~/projects/vulkan-ed/engines/BitNet ~/projects/ki/BitNet
ln -s ~/projects/vulkan-ed/engines/llama.cpp-vulkan ~/projects/ki/llama.cpp-vulkan
ln -s ../../../models engines/BitNet/models/_compare
ln -s ../../../models/bitnet-b1.58-2B-4T engines/BitNet/models/BitNet-b1.58-2B-4T

# Prüfen, dass beide alten Pfade auflösen
ls -L ~/projects/ki/BitNet/models/_compare/Qwen3-4B-Instruct-2507-Q4_K_M.gguf
ls -L ~/projects/ki/BitNet/models/BitNet-b1.58-2B-4T/ggml-model-i2_s.gguf
```

BitNets eigenes `.gitignore` ignoriert `models/*` (Zeile 36), die zwei
Symlinks tauchen im Submodul also nicht als untracked auf.

Das Bench-Repo ist committet und sauber (HEAD `8a26b74`, enthält
`HANDOFF-vulkan-ed.md`); der Subtree in Phase 2 kann direkt vom Remote
oder vom lokalen Pfad gezogen werden. Vorher `git -C
~/projects/bitnet-colibri-bench push`, sonst fehlt der Commit auf GitHub.

Löschen (vom Projektinhaber am 06.09.2026 freigegeben):

```bash
rm -rf ~/projects/ki/colibri
rm -rf ~/projects/ki/pi-mono          # Branch fix/filter-deprecated-models-globally liegt auf origin
sed -i '/pi-mono\/packages\/coding-agent/d' ~/.bashrc   # Zeile 109, Alias pi
```

Rohlogs und Bench-Repo vorbereiten (das ist ein anderes Repo, dort direkt
auf main committen):

```bash
cd ~/projects/bitnet-colibri-bench
mkdir -p results/logs && mv ~/projects/ki/bench-artifacts/* results/logs/ && rmdir ~/projects/ki/bench-artifacts
# ppl-corpus.txt ist ein Duplikat von bench/ppl-corpus.txt (sha256 e38278b0...), löschen
rm results/logs/ppl-corpus.txt
git add results/logs && git commit -m "Rohlogs des ersten Linux-Laufs ins Repo"
```

Pfade im Bench-Repo, die in Phase 2 auf die neuen Orte müssen (jetzt schon
vorbereiten, aber die Symlinks halten sie bis dahin funktionsfähig):

- `setup/serve-coding-agent.sh`: `ENGINE`, `MODELLE`
- `setup/linux.sh`: `ROOT`-Vorgabe, `models/`-Pfade, den colibri-Abschnitt entfernen
- `CLAUDE.md`, `README.md`, `HANDOFF-vulkan-ed.md`, `docs/modell-inventar-2026-08-20.md`
- `bench/olmoe_eval.py`, `bench/olmoe_speed.py`: bleiben als Messprotokoll, aber
  Kopfkommentar „colibri gelöscht am 06.09.2026, nicht mehr lauffähig"
- `results/*.md` sind historische Protokolle: **nicht anfassen**

## Phase 2: nach dem Commit der Picker-Arbeit

Vorher prüfen: `git status --short` leer (bis auf diese Datei).

```bash
cd ~/projects/vulkan-ed

# 1. Bench-Repo als Subtree, Historie bleibt (1.2 MB)
git subtree add --prefix=llm-bench https://github.com/gstrainovic/bitnet-colibri-bench.git main

# 2. Engines als Submodule aus den vorhandenen Klonen (git übernimmt ein
#    existierendes Repo am Pfad, die Builds bleiben erhalten)
git submodule add https://github.com/microsoft/BitNet.git engines/BitNet
git submodule add https://github.com/ggml-org/llama.cpp engines/llama.cpp-vulkan
git config -f .gitmodules submodule.engines/BitNet.ignore dirty   # lokaler Patch, wie libs/fancy-cat
git -C engines/BitNet rev-parse HEAD    # muss 01eb415... sein
git -C engines/BitNet submodule status  # 3rdparty/llama.cpp muss 1f86f05... sein
git -C engines/llama.cpp-vulkan rev-parse HEAD   # 9ee9fc0...
git add .gitmodules engines && git commit -m "engines: BitNet (01eb415) und llama.cpp b10524 als Submodule"
```

3. Pfade im Code umstellen, TDD-Regel beachten (ein Test, der den
   Standardpfad relativ zum Repo prüft, vor der Änderung):

- `src/ui/mod.zig:202` und `:204`: Standard-Engine und -Modell. Heute
  `$HOME/projects/ki/...`. Ziel: relativ zum Repo-Root oder zur ausführbaren
  Datei, nicht mehr über `$HOME`; dabei `engines/llama.cpp-vulkan/build/bin/llama-server`
  und `models/Qwen3-4B-Instruct-2507-Q4_K_M.gguf`.
- `src/ui/ai_chat.zig:319`: Hinweistext nennt `~/projects/ki`.
- `AGENTS.md` Zeilen 127 bis 128 (Abschnitt „KI-Chat") und die Kernregeln
  aus `llm-bench/CLAUDE.md` in einen neuen Abschnitt „Engines und Modelle"
  übernehmen: gepinnte Engine, `Q1_0`-Prüfung mit `llama-bench`,
  Tokenizer-Override für BitNet, Engine-Zuordnung (BitNet nur gepinnt,
  Qwen3 nur b10524).
- Bench-Pfade aus Phase 1 auf `engines/` und `models/` umstellen, danach
  `llm-bench/HANDOFF-vulkan-ed.md`: die `../vulkan-ed/...`-Verweise werden
  zu Repo-Pfaden.

4. Symlinks und Rest entfernen, GitHub-Repo des Bench archivieren:

```bash
rm ~/projects/ki/BitNet ~/projects/ki/llama.cpp-vulkan && rmdir ~/projects/ki
rm -rf ~/projects/bitnet-colibri-bench          # erst nach erfolgreichem Subtree und Nachweis unten
gh repo archive gstrainovic/bitnet-colibri-bench --yes
```

## Nachweis vor der Fertigmeldung (Output zeigen)

```bash
cd ~/projects/vulkan-ed
git status --short | grep -i gguf ; echo "kein GGUF im Index: $?"      # muss 1 sein
du -sh .git                                                             # ~1.6 GB, nicht gewachsen
zig build && zig build test --summary all
python3 scripts/e2e_ai_chat.py                                          # Warmup, Delta, Escape
./engines/BitNet/build/bin/llama-bench -m models/<bitnet i2_s> -p 8 -n 8 -r 1   # Spalte "I2_S - 2 bpw ternary", nicht Q1_0
llm-bench/setup/serve-coding-agent.sh llama gpu 8081 &                  # Bench-Skript mit neuen Pfaden startet
python3 llm-bench/bench/agent_eval.py --port 8081 --label llama-nach-umzug    # erwartet 9/10 wie in results/
```

## Danach

`llm-bench/HANDOFF-vulkan-ed.md` beschreibt drei offene Abgleiche
(Temperatur 0.7 statt 0, CPU-Batch-Threads, gemessene Grenzen in
AGENTS.md). Das ist der nächste Auftrag, nicht Teil dieser Migration.

## Regeln

- Git-Regeln aus `AGENTS.md`: kein `checkout`/`restore`/`reset`/`clean` ohne
  Rückfrage. Die einzigen Löschungen sind die oben freigegebenen.
- Vor jedem `rm -rf` den Pfad anzeigen und prüfen, dass er kein Symlink auf
  `engines/` ist (`ls -ld`).
- Erledigt = diese Datei löschen. Wissen nach `AGENTS.md`, nicht nach `todo.md`.
