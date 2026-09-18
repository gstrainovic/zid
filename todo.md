# Offene Punkte

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
