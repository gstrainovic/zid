# Handoff: Bench-Erkenntnisse gegen zid prüfen

Stand 06.09.2026. Auftrag an den nächsten Agenten: prüfen, ob die drei unten
genannten Lücken echt sind, und sie dann in `~/projects/zid` schliessen.
Dieses Repo (`bitnet-colibri-bench`) ist abgeschlossen und wird nicht
verändert; es liefert nur die Messungen und den Regressionstest.

## Ausgangslage

`zid` hat den Kern der Messungen übernommen. Belegt in
`src/ai/agent.zig`, `src/ui/mod.zig:194-199` und der
`AGENTS.md` dort (Abschnitte „KI-Chat" und „Agent-Werkzeuge"):

- Standardmodell Qwen3-4B-Instruct-2507 Q4_K_M, Engine llama.cpp-Vulkan
  b10524 unter `engines/llama.cpp-vulkan/`.
- Serverstart `--jinja -c 8192 --log-disable`, GPU mit `-dev VulkanN -ngl 99`,
  Gerätewahl per `device_select.zig` (diskrete GPU ab 3 GB, iGPU übersprungen).
- Natives OpenAI-Tool-Calling, ein Endpunkt auf Port 8080.

Bewusst **nicht** übernommen und auch nicht nachzuholen: BitNet als
CPU-Option (braucht die gepinnte Engine und den Tokenizer-Override aus
`CLAUDE.md`, die gepinnte Engine kann kein Vulkan) und `bench/agent_eval.py`
als Bestandteil von zid (der Test bleibt hier, zid prüft mit
eigenen E2E-Skripten nur die Integration).

## Die drei Lücken

### 1. Temperatur 0.7 statt der gemessenen 0

- zid: `src/ai/agent.zig:256-257`, `buildPayload` schreibt fest
  `temperature: 0.7` in jede Anfrage, auch in Werkzeugrunden.
- Bench: `bench/agent_eval.py:50` misst mit `temperature=0.0`; die 10/10
  Werkzeugwahl von Qwen3-4B gelten für diesen Wert. `TODO.md` hält fest, dass
  temperature 0 das Verhalten geräteunabhängig macht.
- Offen ist, ob 0.7 die Werkzeugwahl tatsächlich verschlechtert. Das ist
  messbar, nicht zu raten:

```bash
cd ~/projects/bitnet-colibri-bench
./setup/serve-coding-agent.sh            # Qwen3-4B auf der P1000, Port 8080
# zweites Terminal: Referenz bei 0.0, dann derselbe Test bei 0.7
python3 bench/agent_eval.py --port 8080 --label qwen3-t0
sed 's/temperature=0.0/temperature=0.7/' bench/agent_eval.py > /tmp/agent_eval_t07.py
cp bench/common.py bench/tasks.py /tmp/ && python3 /tmp/agent_eval_t07.py --port 8080 --label qwen3-t07
```

  Ein Lauf bei 0.7 ist nicht deterministisch; drei Läufe machen. Fällt die
  Quote unter 10/10, gehört in `agent.zig` eine Temperatur pro Anfrageart:
  0 für Anfragen mit `tools`, 0.7 darf für reine Chat-Antworten bleiben.
  Bleibt sie bei 10/10 in allen drei Läufen, den Befund in der AGENTS.md von
  zid als negatives Ergebnis notieren und den Code lassen.

### 2. CPU-Fallback ohne Batch-Threads

- zid: `src/ai/agent.zig:107` und `:117`, `-t min(Kerne, 8)`, kein `-tb`.
- Bench: `setup/serve-coding-agent.sh`, CPU-Zweig `-t 8 -tb 12`, vermessen in
  `results/linux-i7-8850H-gpu-und-neue-modelle.md` (Qwen3-4B CPU 9.9 tok/s).
- Betrifft nur Maschinen ohne brauchbare GPU. Prüfen, ob `-tb 12` auf dem
  Laptop messbar etwas bringt (`llama-bench` mit `-t 8` gegen `-t 8 -tb 12`,
  je `-p 128 -n 64`); wenn ja, in `agent.zig` ergänzen, Wert an die Kernzahl
  koppeln statt fest 12.

### 3. Gemessene Grenzen fehlen in der AGENTS.md von zid

Nichts davon ist Code, aber der nächste Agent in zid sollte es wissen,
ohne dieses Repo zu lesen. Quelle: `FAZIT.md` und `CODING-AGENTEN.md`,
Abschnitt „Härtegrad 2".

- Ein-Datei-Fix-Zyklus gelingt mit Qwen3-4B; sobald die Ursache über einen
  Import hinweg liegt, scheitert die 3-4B-Klasse. Qwen3 scheitert dabei
  gefahrlos (analysiert, ändert nichts), Llama-3.2-3B destruktiv.
- Prompt-Verarbeitung auf der P1000 liegt bei 96 tok/s; mit jeder
  Werkzeugrunde wächst der Kontext. zid begrenzt auf 8 Runden
  (`src/ui/ai_chat.zig:32`), kürzt aber keine Chat-Historie. Bei `-c 8192`
  läuft ein längerer Chat mit Werkzeugergebnissen in die Kontextgrenze;
  prüfen, was llama-server dann tut (Fehler oder stilles Abschneiden), und
  entscheiden, ob zid alte Runden verwerfen soll.
- Regel aus dem Praxistest: Agenten-Änderungen nur in Git-Repos, `git restore`
  hat einen zerstörten Test in einer Sekunde geheilt. zid sichert nur
  über Bestätigungsdialoge. Mindestens dokumentieren; ob der Agent ausserhalb
  eines Git-Repos zusätzlich warnen soll, ist eine Produktentscheidung des
  Projektinhabers, nicht des Agenten.

## Arbeitsregeln für zid

- Arbeitsbaum dort ist **nicht sauber**: geänderte `build.zig`,
  `src/ui/dialog.zig`, `src/ui/explorer_ops.zig`, `src/ui/mod.zig` und neue
  `src/ui/dialog_ops.zig` gehören zu einer laufenden Dialog-Arbeit. Nicht
  anfassen, nicht mitcommitten, keine `git checkout`/`restore`-Befehle
  (Git-Regeln in der dortigen AGENTS.md).
- Tests dort: `zig build test --summary all`; E2E nur `--headless`, nie mit
  Fenster. `python3 scripts/e2e_ai_tools.py` ist der Integrationstest für
  Werkzeugrunden und muss nach jeder Änderung an `agent.zig` grün bleiben.
- TDD gilt: für Punkt 1 und 2 erst einen Unit-Test auf `buildPayload`
  beziehungsweise den argv-Aufbau, dann der Eingriff.
- Wissen nach AGENTS.md von zid, nicht in deren `todo.md`.
- Jede Messzahl mit Engine-Commit und Modell-sha256 (Regel aus `CLAUDE.md`
  hier); Referenzwerte stehen in `results/linux-i7-8850H-gpu-und-neue-modelle.md`.
