# Todo: Tastenkürzel und Menüs sichtbar machen

- [ ] 5. Menüs im Header aus der Tabelle: File (New File, Save, Open Folder…), Edit (Undo, Redo, Cut, Copy, Paste, Select All), View (Explorer, Split V/H, MD-Preview, Terminal); Kürzel stehen rechts im Eintrag
- [ ] 6. Editor-Kontextmenü zeigt die Kürzel aus der Tabelle (Cut, Copy, Paste, Split, MD-Preview)
- [ ] 7. Help → Keyboard Shortcuts: Dialog listet alle Bindungen aus der Tabelle
- [ ] 8. Ctrl+F: Suchleiste im Editor (Enter nächster Treffer, Shift+Enter vorheriger, Escape schließt); Action `Search` ist bisher ohne Implementierung
- [ ] 9. E2E-Skript `scripts/e2e_shortcuts.py` deckt Punkte 2–7 headless ab
- [ ] 10. AGENTS.md: irreführende Zeile zu `f2`/`delete` korrigieren, Kürzel-Tabelle als einzige Quelle dokumentieren
- [ ] 11. Bug: erstes getipptes Zeichen nach Ctrl+N geht verloren ("abc" → "bc"), headless mit editor_state reproduzierbar (scripts/e2e_shortcuts.py, Punkt 3/4)
