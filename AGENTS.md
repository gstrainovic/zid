# Agent Instructions

## Working Rules

1. **todo.md ist das Gesetz**
   - Reihenfolge der Phasen strikt einhalten
   - Nicht springen oder überspringen
   - Erst Phase N abschließen, dann Phase N+1

2. **8-Schritte Workflow pro Task**
   ```
   1. todo.md gründlich lesen und verstehen
   2. Beispiele finden mit `rg` Suche (example|demo|sample) rekursiv überall, auch in libs/
   3. Implementieren (von Gooey übernehmen statt neu erfinden)
   4. Mit ./gui-screenshot.sh Screenshot machen
   5. Screenshot SELBST PRÜFEN: mit Read-Tool als Bild öffnen und visuell
      kontrollieren ob die Implementierung sichtbar ist. NICHT nur prüfen
      ob die Datei existiert oder ein PNG ist — den INHALT anschauen!
      Checkliste: Ist das neue Feature sichtbar? Ist es korrekt positioniert?
      Ist Text lesbar? Sind Farben wie erwartet?
   6. Falls Screenshot den Claim NICHT visuell beweist: Schritte 3-5
      wiederholen bis es passt. NICHT zum Reviewer gehen mit einem
      Screenshot der die Implementierung nicht zeigt!
   7. todo.md abhaken, commit & push
   8. ./scripts/review.sh <N> aufrufen (Supervisor Gate)
   ```

3. **Keine Ausreden**
   - ❌ "Zu komplex" → nicht akzeptabel
   - ❌ "Gut genug" → nicht akzeptabel
   - ❌ Abkürzungen nehmen → nicht akzeptabel
   - ✅ Vollständig implementieren oder fragen

4. **Verifizierung**
   - Jeder Schritt mit `./gui-screenshot.sh` verifizieren
   - Screenshot muss funktionierende Implementierung beweisen
   - Nur Logs reichen NICHT
   - Erst weiter wenn visuell bewiesen

5. **Git Workflow**
   - Nach jedem abgeschlossenen Task: commit & push
   - Todo.md aktualisieren bevor commit
   - Commit message beschreibt was implementiert wurde

6. **Gooey Referenz**
   - Von Gooey übernehmen statt neu erfinden
   - Code kopieren und anpassen für wio+wgpu+Clay
   - Nicht Gooey's Platform-Layer nutzen (wir haben wio)
   - Gooey's Component-Logik als Vorlage verwenden

## Screenshot Tool

```bash
# Usage
./gui-screenshot.sh screenshots/output_name.png [wait_seconds]

# Beispiel
./gui-screenshot.sh screenshots/phase4_text.png 5
```

## Supervisor Gates (Claude als Reviewer)

Zwischen jeder Phase ist ein **Review-Gate durch Claude** Pflicht. Qwen darf nicht
eigenmaechtig mit Phase N+1 beginnen, solange Phase N nicht ACK ist.

### Workflow pro Phase

1. Phase laut 8-Schritte-Workflow abschliessen (inkl. Screenshot).
2. todo.md-Haken setzen, commit + push.
3. **Review aufrufen:**
   ```bash
   ./scripts/review.sh <phase-nummer>
   ```
4. Ausgabe ist JSON auf stdout + Exit-Code:
   - Exit `0` = **ACCEPT** → Qwen setzt Git-Tag und darf weiter:
     ```bash
     git tag phase-<N>-ack && git push --tags
     ```
   - Exit `1` = **REJECT** → JSON enthaelt `reasons` und `required_fixes`.
     Qwen arbeitet die Fixes ab, macht neuen Screenshot, commit + push,
     **ruft review.sh erneut auf**. Nicht weiter zu Phase N+1!
   - Exit `2` = Infrastruktur-Fehler (Screenshot fehlt, CLI fehlt). Beheben, neu aufrufen.

### Sonderfall: Bestehender Code vor dem todo.md-Reset

Der todo.md-Reset zum `phase-0-ack`-Tag hat alle Haken entfernt, aber der
Code unter `src/` kann eine Phase schon implementieren (z.B. Phase 1
Projekt-Setup, Phase 2 wio-Window). In diesem Fall **nicht neu schreiben**,
sondern **neu verifizieren**:

1. `zig build` ausfuehren — muss sauber bauen.
2. `./gui-screenshot.sh screenshots/phase<N>_verify.png 5` — Screenshot
   der die Phase-Funktion visuell beweist (fuer Phase 1: laufendes Fenster,
   fuer Phase 2: Input-Events reagieren, etc.).
3. todo.md-Haken setzen.
4. Commit-Message mit Praefix `verify:` statt `feat:`:
   `verify: Phase N bestehende Implementierung validiert`.
5. `./scripts/review.sh <N>` aufrufen.

Der Reviewer akzeptiert verify-Commits wenn (a) der Screenshot den Claim
visuell beweist **und** (b) der Render-/Logik-Pfad im HEAD-Code tatsaechlich
existiert (nicht nur todo.md-Edit). Ein leerer `verify:`-Commit ohne Screenshot-
Beweis ist REJECT.

### Vier Grundregeln, die Claude streng prueft

1. **Screenshot-Diff-Regel** — Wenn der neue Phase-Screenshot byte-identisch
   oder visuell identisch zum Vorgaenger-Screenshot ist, ist die Phase nicht
   fertig, egal was der Code behauptet. (Byte-Check passiert bereits im Wrapper,
   vor dem Claude-Aufruf, um Tokens zu sparen.)

2. **Claim-Match-Regel** — Jedes Wort im todo.md-Task ("Line Numbers", "Button",
   "TextArea") muss im Screenshot als erkennbares visuelles Element vorkommen.
   Ein andersfarbiges Rechteck ist **kein** TextInput. Ein dunkler Streifen ist
   **kein** Line-Numbers-Gutter.

3. **Keine Stubs im Diff** — TODO/FIXME/placeholder/unimplemented im neuen Code
   der abgehakten Phase → automatischer REJECT.

4. **Implementierungs-Spuren im Diff** — Wenn die Phase ein neues UI-Element
   behauptet, muss der Render-Pfad im Diff sichtbar sein (neue Draw-Calls,
   Shader-Uniforms, Vertex-Buffer). todo.md-Edit allein ist keine Implementierung.

### Token-Budget

Der Reviewer laeuft mit **Sonnet 4.6**, **Effort: medium**, unter
`--max-budget-usd 0.60`. Qwen darf review.sh beliebig oft aufrufen —
billiger ist es trotzdem, den Screenshot **selbst visuell zu pruefen**
(Schritt 5 im 8-Schritte-Workflow) bevor review.sh aufgerufen wird.

Warum diese Wahl:
- **Sonnet statt Opus:** Reviewer-Aufgabe ist strukturiert (Claim-vs-Evidenz,
  JSON-Output), Opus waere Overkill und ~5x teurer.
- **Effort medium statt high:** Reviews sind kein Research, keine Algorithmen.
  Medium reicht fuer Bildvergleich + Diff-Check und spart Thinking-Tokens.

## Current Status

Siehe todo.md für aktuellen Projektstatus. Letzter ACK-Anker:
`git tag --list 'phase-*-ack' | sort -V | tail -1`
