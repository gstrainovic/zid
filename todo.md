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

## Explorer und Terminal: eigene Scrollbalken auf `scrollbar.zig` umstellen

`src/ui/file_explorer.zig` (`scrollbar_dragging`, `scrollbar_thumb_y`, eigenes Zeichnen ab
`renderScrollbar`) und `src/terminal/terminal_instance.zig` (gleiche Felder, gezeichnet in
`mod.zig` um Zeile 4590) halten je eine Kopie der Balken-Logik. Editor und Markdown-Vorschau
laufen seit `d258882` über `scrollbar.zig` (`Model`, `hitTest`, `pageOffset`, `dragOffset`,
`render` mit Hover-Rückgabe für den Pfeil-Cursor). Der I-Beam-über-Balken-Fehler trat deshalb
zweimal auf; die beiden Kopien haben ihn oder bekommen ihn beim nächsten Umbau wieder.

1. Explorer: `Model` mit Zeilen als Einheiten wie im Editor bauen, Klick/Zug über `hitTest`,
   `pageOffset`, `dragOffset`; die Felder `scrollbar_*` bis auf Track-Lage entfernen; Hover in
   `getDesiredCursor` berücksichtigen. E2E: bestehende Explorer-Suiten müssen grün bleiben.
2. Terminal: dito, Zeichnen aus `mod.zig` in `scrollbar.render` überführen.
3. Satz in AGENTS.md („Explorer und Terminal haben noch eigene“) danach streichen.
