# Offene Punkte

## Source Control: Changes-Bereich mit Commit-Eingabefeld wie VS Code

zid kann nichts stagen oder committen. `git_worker.zig` hat nur lesende Tasks (status, log,
show, diff, blame, timeline, graph); Source Control Graph, Timeline und Diff-Editor sind reine
Ansichten. Eine gelöschte Datei lässt sich heute nur im Terminal-Tab committen (`git rm`, `git
commit`).

Quellen (gelesen, Stand `microsoft/vscode` main): `extensions/git/src/repository.ts` (Gruppen,
Buchstaben, Farben, Platzhalter, Diff-Seiten), `extensions/git/src/commands.ts` (stage, unstage,
clean, smartCommit, Dialogtexte), `extensions/git/src/git.ts` (git-Argumente, Fehlercodes),
`extensions/git/package.json` (Menüs, Inline-Reihenfolge, Icons),
`src/vs/workbench/contrib/scm/browser/scmViewPane.ts` und `media/scm.css` (Zeilen, Eingabefeld,
Aktionen beim Überfahren).

### Skizze: Sidebar im Modus Source Control

```
┌ SOURCE CONTROL ───────────────────────────── ✓ ⟳ ┐   Kopf 30 px; ✓ = Commit, ⟳ = Refresh
│ ┌───────────────────────────────────────────────┐ │
│ │ Message (Ctrl+Enter to commit on "main")      │ │   line_edit, 1 Zeile, Rand 1 px, Radius 4,
│ └───────────────────────────────────────────────┘ │   26 px + 10 px; Platzhalter gedimmt
│ [        ✓ Commit                              ]  │   Knopf 28 px, volle Breite (scm.showActionButton)
│ ▾ Staged Changes                        1   − ⊟   │   Gruppe 22 px, Badge = Anzahl, Aktionen nur
│     test-README.md                          D     │   beim Überfahren: − Unstage All, ⊟ View
│ ▾ Changes                               2   + ↶ ⊟ │   + Stage All, ↶ Discard All, ⊟ View
│     code_editor.zig  src/editor             M     │   Name, dahinter Ordner gedimmt, rechts Buchstabe
│     neu.txt                                 U     │   farbig; beim Überfahren vor dem Buchstaben:
│                                       ⊟ + ↶       │   ⊟ Open File, + Stage, ↶ Discard (Reihenfolge
│                                                   │   inline@1 openFile, inline@2 stage/clean)
│ ▾ SOURCE CONTROL GRAPH                  Auto ⟳    │   wie heute darunter
│   ● main  fix(editor): …                          │
└───────────────────────────────────────────────────┘
```

- Gruppen in VS-Code-Reihenfolge: „Merge Changes“ (nur bei Konflikten), „Staged Changes“
  (nur wenn nicht leer), „Changes“ (immer), „Untracked Changes“ nur bei
  `git.untrackedChanges = separate`; zid nimmt den Standard `mixed` (untracked in „Changes“).
- Eingabefeld: `line_edit` einzeilig (VS Code wächst bis `scm.inputMaxLineCount`, erster Schritt
  eine Zeile). Platzhalter genau `Message (Ctrl+Enter to commit on "<branch>")`; Branch aus dem
  vorhandenen `taskGitBranch`. Ctrl+Enter = Commit (`scm.acceptInput`).
- Zeile: Dateiname, Ordnerpfad relativ zur Repo-Wurzel gedimmt, rechts Status-Buchstabe in
  Statusfarbe. Gelöscht (`D`, Index Deleted, Konflikt-Deleted) durchgestrichen. Hover-Text =
  `getStatusText`: „Index Modified“, „Index Added“, „Index Deleted“, „Index Renamed“, „Index
  Copied“, „Modified“, „Deleted“, „Untracked“, „Ignored“, „Intent to Add“, „Type Changed“,
  „Conflict: Both Modified“ usw.
- Buchstaben: M (modified/index modified), A (index added, intent to add), D (deleted/index
  deleted), R (renamed), C (copied), T (type changed), U (untracked), I (ignored), ! (Konflikte).
- Farben (VS Code `gitDecoration.*`, dark): modified/stageModified `#E2C08D`, deleted/
  stageDeleted `#C74E39`, added `#81B88B`, untracked `#73C991`, renamed `#73C991`, ignored
  `#8C8C8C`, conflicting `#E4676B`. Explorer nutzt heute `theme.success/warning/danger/muted`;
  beide auf dieselben Theme-Felder ziehen (`git_added`, `git_modified`, `git_deleted`,
  `git_untracked`, `git_renamed`, `git_conflict` in `theme.zig`).
- Aktionen erscheinen beim Überfahren der Zeile bzw. des Gruppenkopfs (scm.css: `display:none`
  → hover), wie heute „Open Changes“ im Graphen. Icons Lucide: plus, minus, undo-2 (discard),
  file (open), check (commit), refresh-cw.

### Skizze: Daten

- Quelle bleibt `taskGitStatus` (porcelain v2, `--null --ignored`). `parseStatusOutput` liefert
  heute nur einen Buchstaben je Pfad für den Explorer. Neu: zweites Format mit XY-Paar, altem
  Pfad bei Rename/Copy (Zeile `2 …`) und Konflikten (Zeile `u …`), aus derselben git-Ausgabe.
- Zuordnung XY → Gruppe wie `repository.ts`: X in {M,A,D,R,C,T} → Staged (Index-Status), Y in
  {M,D,T} → Changes, `??` → Changes (mixed) mit U, `!!` → nur Explorer, `u`-Zeilen (DD, AU, UD,
  UA, DU, AA, UU) → Merge Changes mit `!`. Eine Datei kann in beiden Gruppen stehen (`MM`).
- Neues Modul `src/git/git_changes.zig` (ohne Clay, unit-getestet): `parseStatus` → Gruppen und
  Zeilen, `letter`, `strikeThrough`, `statusText`, `diffSpec(row)`, Auswahl und Tastatur wie
  `git_scm.View.moveSelection`/`activateSelected`. Ansicht `src/ui/scm_changes_view.zig` über
  dem Graphen in `sidebar_mode == .scm`; `scm_graph_view` bleibt unverändert.
- Diff-Klick (`git.openDiffOnClick = true`): Staged → HEAD gegen Index (`git_diff.Spec` mit
  `parent = "HEAD"`, `hash = git_diff.index_ref`, wie „Staged Changes“ in der Timeline); Changes →
  Index gegen Arbeitskopie (neu: rechte Seite aus der Datei statt `git show`, Worker-Variante von
  `taskGitFileDiff`); Untracked → leerer Baum gegen Datei; Deleted → HEAD gegen leer. Titel wie
  VS Code: `name (Index)` bzw. `name (Working Tree)`.
- Neue Worker-Tasks (alle über `runGit` im Repo, `core.quotepath=off`):
  - stage: `git add -A -- <pfade>` (deckt gelöschte Dateien ab; VS Code nutzt `add -A`, `rm` nur
    im Konfliktfall „Deleted by them“ nach Rückfrage).
  - unstage: `git reset -q HEAD -- <pfade>`; ohne Commits `git rm --cached -r -- <pfade>`.
  - discard: tracked `git checkout -q -- <pfade>`, untracked `git clean -f -q -- <pfade>`.
  - commit: `git commit --quiet --file - --allow-empty-message`, Nachricht über stdin;
    `runGit` braucht dafür eine stdin-Variante.
  - Fehler als Toast aus stderr: `Aborting commit due to empty commit message`, `Please tell me
    who you are.` (user.name/user.email), Hook-Abbruch (Exit ≠ 0 mit Hook-Ausgabe).
- Nach jeder Aktion: Status neu laden (bestehender git-status-Debounce reicht, weil git die
  Index-Datei schreibt), nach Commit zusätzlich `scm_graph.refresh()` und `timeline.refresh()`.

### Skizze: Verhalten

- Commit bei leerer Nachricht: Eingabefeld fokussieren und Hinweis „Please provide a commit
  message“ unter dem Feld (VS Code inputValidation, Hintergrund info/warning/error).
- Commit ohne Staged Changes: VS Code `smartCommit` fragt „There are no staged changes to
  commit. Would you like to stage all your changes and commit them directly?“ mit Yes / Always /
  Never; zid im ersten Schritt nur Yes / Cancel (kein Setting), Yes = `git add -A` und commit.
- Discard fragt immer (Dialog vorhanden, vgl. `showSaveConfirmationDialog`): eine Datei „Are
  you sure you want to discard changes in '<name>'?“ Knopf „Discard File“; gelöschte Datei „Are
  you sure you want to restore '<name>'?“ Knopf „Restore File“; untracked „Are you sure you want
  to DELETE the following untracked file: '<name>'?“ Knopf „Delete File“; Discard All „…discard
  ALL changes in <n> files? This is IRREVERSIBLE!“ Knopf „Discard All <n> Files“.
- Tastatur (Fokus in der Sidebar wie beim Graphen): ↑↓/PgUp/PgDn/Home/End wählen über beide
  Gruppen hinweg, Enter/Leertaste öffnen den Diff, Entf = Discard mit Rückfrage, Escape zurück
  in den Editor; Tab wechselt zwischen Eingabefeld und Liste (`scm.focusNextInput`).
- Kein Amend, Sign-off, Push oder Sync im ersten Schritt; Kopf-Aktionen nur Commit und Refresh.

### Umsetzung (Reihenfolge)

1. `theme.zig`: Git-Statusfarben als eigene Felder, Explorer darauf umstellen.
2. `git_changes.zig` mit Tests: Status-Parsing in Gruppen, Buchstabe, Durchstreichen, Hover-Text,
   Diff-Spec, Auswahl/Tastatur.
3. Worker: stdin für `runGit`, Tasks stage/unstage/discard/commit mit Tests gegen ein Fixture-Repo
   (wie `taskGitLog`-Tests).
4. Ansicht: Eingabefeld, Commit-Knopf, Gruppen, Zeilen, Hover-Aktionen, Dialoge, Toasts.
5. Diff-Editor-Seiten Index/Arbeitskopie.
6. E2E `scripts/e2e_scm_changes.py` (Fixture-Repo: ändern, löschen, neu anlegen, stagen,
   unstagen, discard mit Dialog, commit, Graph zeigt den Commit, Buchstaben und Farben per RPC
   `scm_state`). AGENTS.md-Abschnitt „Source Control Graph“ um den Changes-Bereich ergänzen.

## Windows: Watcher folgt Symlink-Ordnern nicht

`src/async/file_watcher_win.zig` hält ein `ReadDirectoryChangesW`-Handle auf die Wurzel mit
`bWatchSubtree=TRUE`; Windows folgt dabei keinen Reparse-Points (Symlink, Junction). Linux ist
seit `bc6872c` behoben (`scripts/e2e_external_change.py`, vier Fälle grün).

1. `python3 scripts/e2e_external_change.py` auf dem Windows-PC laufen lassen. Erwartung: `inplace`
   und `atomic` grün (main.zig reicht `file_created` jetzt weiter), `symlink` vermutlich grün
   (Ereignis kommt über den echten Pfad, `UI.bufferKeyForPath` vergleicht per realpath),
   `symlink_out` rot. `os.symlink` braucht dort Developer-Mode oder Admin; sonst Junction per
   `mklink /J` im Skript als Fallback.
2. Für `symlink_out`: beim Start den Baum einmal durchgehen, je Symlink-/Junction-Ordner mit Ziel
   außerhalb der Wurzel ein eigenes `ReadDirectoryChangesW`-Handle öffnen (gleiche Filter, gleiche
   Overlapped-Schleife), Ereignispfade unter dem Link-Pfad melden. Ziel innerhalb der Wurzel
   braucht kein zweites Handle.
3. AGENTS.md-Satz „Der Windows-Watcher folgt Symlink-Ordnern nicht“ danach streichen.
