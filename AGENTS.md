# AGENTS.md

## Git Regeln

- **KEINE git-destructive Befehle ohne explizite Erlaubnis**: Kein `git push --force`, `git reset`, `git checkout`, `git restore`, `git clean` ohne vorher zu fragen.
- **Sitzungsstart über `scripts/sync.sh`, nicht nur `git pull`:**
  1. `git status` im Repo und in den Submodulen; vorgefundene Änderungen committen.
  2. `./scripts/sync.sh`: holt origin/main per Rebase, zieht die gepinnten Submodule
     nach (`submodule update --init`), prüft MuPDF und die Referenz-Repos.
  3. `./scripts/sync.sh --push`: erst Submodul-Forks, dann das Hauptrepo.

  `pull` allein lässt die Submodule auf dem alten Pin; Build und Tests liefen dann gegen
  veraltetes clay-zig oder zigdown. Nach `submodule update` stehen die Forks ohne Branch
  da: vor Arbeit in `libs/clay-zig` usw. den Branch aus `.gitmodules` auschecken.

## Logging

- Debug-Zeilen nur mit `ZID_DEBUG=1` (`logFn` in main.zig filtert zur Laufzeit); ohne Variable
  bleiben info/warn/err.
- `logFn` schreibt per `writerStreaming`, weil `File.writer()` eine umgeleitete Log-Datei
  (`2>log`) laufend ab Offset 0 überschreibt.

## Build Commands

```bash
zig build run              # Run zid
zig build run -- --headless  # Headless mode (screenshots via RPC port 9999)
zig build run -- --interactive  # Interactive mode (stdin/stdout command interface)
zig build -Doptimize=ReleaseSafe  # Release build
zig build test-text        # nur Textsystem (Glyph-Cache, Atlas; Root src/text_tests.zig)
```

## Skills

Hier stehen nur Regeln, die überall gelten. Wissen zu einzelnen Bereichen liegt in
`.claude/skills/<name>/SKILL.md`: vor Arbeit an einem Bereich die passende Skill laden. Neue
Befunde gehören in die Skill ihres Bereichs, nicht hierher.

## Überall geltende Regeln

- **UI-Bausteine nie parallel nachbauen:** Schaltfläche, Tooltip, Scrollbalken, Kontextmenü und
  Eingabezeile gibt es je einmal; verwenden oder erweitern (Skill `ui-bausteine`).
- **Kürzel und Menüeinträge nur in `src/ui/shortcuts.zig`** eintragen (Skill `menues-kuerzel`).

## E2E-Tests

- Immer `--headless --ai=off`, nie ein Fenster: headless läuft derselbe Frame-Loop, ein Fenster
  stört den User.
- Fixtures unter `tmp/` anlegen, nie aus `test_data/` lesen; eingecheckte Vorlagen liegen unter
  `scripts/fixtures/`.
- Die UI-Uhr läuft in Echtzeit: Tests, die auf Tooltips, Toasts oder Hover warten, rechnen in
  echter Zeit, nicht in Frames.
- Jeder RPC, der veränderlichen UI-Zustand liest (Buffer, Editoren, Listen), läuft per `onMain`
  im Hauptthread.
- RPC-Referenz, Threading und Koordinaten: Skill `e2e-rpc`; Suitenbetrieb und Windows: Skill
  `grosse-dateien`.
