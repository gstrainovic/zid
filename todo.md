# Offene Punkte

## Source Control: Changes-Bereich mit Commit-Eingabefeld wie VS Code

zid kann nichts stagen oder committen. `git_worker.zig` hat nur lesende Tasks (status, log,
show, diff, blame, timeline, graph); Source Control Graph, Timeline und Diff-Editor sind reine
Ansichten. Eine gelöschte Datei lässt sich heute nur im Terminal-Tab committen (`git rm`, `git
commit`).

Vorbild: VS Codes Source-Control-Ansicht (`extensions/git/src/repository.ts`,
`src/vs/workbench/contrib/scm/browser/scmViewPane.ts`), oberhalb des Graphen in der
Source-Control-Sidebar (`UI.sidebar_mode == .scm`):

1. Eingabefeld „Message (Ctrl+Enter to commit on "main")“ über `line_edit`, Ctrl+Enter committet;
   leere Nachricht öffnet wie VS Code einen Hinweis statt zu committen.
2. Abschnitte „Staged Changes“ und „Changes“ (aufklappbar, Zähler-Badge) aus dem vorhandenen
   `taskGitStatus` (porcelain v2: A/M/D/R/?); Zeile = Dateiname, gedimmter Ordnerpfad, Status-
   Buchstabe farbig wie im Explorer, gelöschte Dateien durchgestrichen.
3. Inline-Aktionen je Zeile beim Überfahren: „+“ (`git add -- <pfad>`; bei gelöschter Datei
   `git rm --cached` bzw. `git add -A -- <pfad>`), „−“ (`git restore --staged -- <pfad>`),
   „↶ Discard“ mit Rückfrage (`git checkout -- <pfad>`, untracked: löschen). Abschnitts-Kopf:
   „Stage All“, „Unstage All“, Refresh.
4. Klick auf eine Zeile öffnet den Diff-Editor: Changes = Arbeitskopie gegen Index, Staged =
   Index gegen HEAD (`git_diff.index_ref` gibt es schon für die Timeline).
5. Commit als neuer Worker-Task (`git commit -m <nachricht>` mit `core.quotepath=off`), Fehler
   (Hook, leerer Index, fehlende user.name) als Toast; danach Status, Graph und Timeline neu
   laden. Keine Amend-, Sign-off- oder Push-Knöpfe im ersten Schritt.
6. Tastatur wie im Graphen: ↑↓ wählen, Enter öffnet den Diff, Entf verwirft mit Rückfrage,
   Escape zurück in den Editor.
7. Unit-Tests für Status-Parsing in Abschnitte und Tastatur ohne Clay; E2E
   `scripts/e2e_scm_changes.py` mit Fixture-Repo: Datei ändern, löschen, stagen, committen,
   Graph zeigt den neuen Commit. AGENTS.md-Abschnitt „Source Control Graph“ ergänzen.

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
