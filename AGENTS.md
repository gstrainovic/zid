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
   5. Screenshot muss BEWEISEN dass Implementierung funktioniert
   6. Falls nicht: Schritte 1-5 wiederholen bis es passt
   7. todo.md abhaken, commit & push
   8. Weiter mit nächstem Task
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

## Current Status

Siehe todo.md für aktuellen Projektstatus.
