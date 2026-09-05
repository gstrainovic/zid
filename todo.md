# Todo: Tastenkürzel und Menüs sichtbar machen

- [ ] 1. Zentrale Kürzel-Tabelle `src/ui/shortcuts.zig` (Command, Taste, Modifier, Label, Anzeige-Text, Scope) mit Tests; `mod.zig` löst globale Tasten darüber auf
- [ ] 2. Explorer: F2 benennt den markierten Eintrag um, Entf löscht ihn (mit Bestätigungsdialog wie im Kontextmenü)
- [ ] 3. Tabs: Ctrl+W schließt den aktiven Tab (mit Speichern-Nachfrage), Ctrl+Tab / Ctrl+Shift+Tab wechseln, Ctrl+N neue Datei
- [ ] 4. Ansicht: Ctrl+B Explorer ein/aus, Ctrl+` neues Terminal, Ctrl+Shift+K Zeile löschen (Action existiert schon)
- [ ] 5. Menüs im Header aus der Tabelle: File (New File, Save, Open Folder…), Edit (Undo, Redo, Cut, Copy, Paste, Select All), View (Explorer, Split V/H, MD-Preview, Terminal); Kürzel stehen rechts im Eintrag
- [ ] 6. Editor-Kontextmenü zeigt die Kürzel aus der Tabelle (Cut, Copy, Paste, Split, MD-Preview)
- [ ] 7. Help → Keyboard Shortcuts: Dialog listet alle Bindungen aus der Tabelle
- [ ] 8. Ctrl+F: Suchleiste im Editor (Enter nächster Treffer, Shift+Enter vorheriger, Escape schließt); Action `Search` ist bisher ohne Implementierung
- [ ] 9. E2E-Skript `scripts/e2e_shortcuts.py` deckt Punkte 2–7 headless ab
- [ ] 10. AGENTS.md: irreführende Zeile zu `f2`/`delete` korrigieren, Kürzel-Tabelle als einzige Quelle dokumentieren
