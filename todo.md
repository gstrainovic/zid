# Todo

14.1a split soll man verschieben können, ähnlich wie man es beim explorer kann.

---

## AI Agent & LLM Tasks

- [x] **Modell-Download Button:** Implementiere eine UI-Funktion (oder Button in der Sidebar), die das empfohlene Gemma 4 Modell automatisch via HTTP/curl herunterlädt.
- [x] **Function Calling (Tools):** Implementiere die JSON-Schnittstelle im System-Prompt, damit der Agent Befehle wie `read_file` und `replace_text` ausführen kann.
- [x] **VRAM Context Management:** Dynamische Anpassung der `--ctx-size` basierend auf dem verfügbaren VRAM.
- [ ] **Native C-Bindings:** Migration von HTTP (`llama-server`) auf native C-Integration (`llama.h`) für geringere Latenz.
- [x] **Memory Leak Fix:** In `src/ui/ai_chat.zig` (workerThread) muss das Ergebnis von `getAIResponse()` ordnungsgemäß freigegeben werden.
- [x] **Copy to Clipboard:** Erlaube das Kopieren von KI-Antworten (z.B. durch Klick auf die Nachricht), da `clay.text` keine native Text-Selektion unterstützt.

---

## Async Subsystem + Git Integration — Plan für Sonnet

### Kontext

vulkan-ed braucht ein async Subsystem für Git, LSP, File Watcher, Build etc.
Der Main Thread gehört wio (Events) + wgpu (Rendering) — darf NICHT blockieren.

### Architektur-Entscheidung: Thread Pool + Unified Event Queue

**NICHT Actor Model.** flow-editor nutzt thespian (Erlang-style Actors), aber:
- thespian übernimmt die Event Loop → kollidiert mit wio+wgpu Main Loop
- 79/80 flow-Files importieren thespian → totale Durchdringung, nicht isolierbar
- Zwei Event Loops parallel = Race Conditions, undefined Behavior

**Stattdessen:** Thread Pool mit submit()/pollResults() Pattern.
Gleich wie das bestehende Terminal-Pattern (std.Thread + Mutex), nur generisch.

```
Main Thread (wio+wgpu)
    │ submit(task)          pollResults() → non-blocking drain
    ▼                       ▲
┌───────────────────────────────────┐
│  Scheduler (Work Queue + Result Queue)  │
├──────┬──────┬──────┬──────────────┤
│ W0   │ W1   │ W2   │ W3          │
│(git) │(lsp) │(build)│(file_watch) │
└──────┴──────┴──────┴──────────────┘
```

### Was wir von flow übernehmen (Logik, nicht Transport)

- `libs/flow/src/git.zig` — Git CLI Kommandos + Output-Parsing (status --porcelain=v2)
- `libs/flow/src/VcsStatus.zig` / `VcsBlame.zig` — Datenstrukturen für Git-State
- `libs/flow/src/LSP.zig` — JSON-RPC Protokoll, Request/Response Matching
- `libs/flow-core/` — TypedInt, Buffer/Node, Keybind, File Type Config, Highlighting, Snippet

### Phase 1: Scheduler (src/async/scheduler.zig)

- [x] `Scheduler` struct mit N Worker Threads (std.Thread)
- [x] `BoundedQueue(Task)` — Work Queue, Main → Workers, Mutex + Condition
- [x] `BoundedQueue(TaskResult)` — Result Queue, Workers → Main, Mutex
- [x] `ResultTag` enum — erweiterbar: `.git_status`, `.git_diff`, `.lsp_response`, ...
- [x] `submit(task)` — non-blocking, pushed in Work Queue
- [x] `pollResults(buf)` — non-blocking, draint Result Queue in Buffer
- [x] `shutdown()` — should_stop Atomic + Condition broadcast + join
- [x] Test: submit 10 Tasks, poll alle Results, verify ordering/completeness

**Wichtig:** Worker Threads dürfen NIEMALS wio/wgpu/Clay anfassen.
Results sind nur Daten (strings, structs). Main Thread rendert.

### Phase 2: Git Integration (src/git/)

- [x] `git_worker.zig` — Git-spezifische Task-Funktionen
- [x] `git status --porcelain=v2` parsen → `StatusData` struct
- [x] `git rev-parse --abbrev-ref HEAD` → Branch-Name
- [x] `git log --oneline -n 50` → `[]LogEntry`
- [x] `git diff <path>` → Diff-Text
- [x] `git blame <path>` → `[]BlameLine`
- [x] Alle via `std.process.Child` (eigener Prozess, non-blocking im Worker)
- [x] Referenz: `libs/flow/src/git.zig` für Kommandos und Parsing-Logik
- [x] UI: `ui_system.updateGitStatus()` — Branch in Statusbar, File-Status im Explorer
  - [x] Branch-Name in Status Bar (unten), Git-Branch-Icon
  - [x] ~ / + / - / ? Indikatoren nach Dateinamen im File Explorer
  - [x] Scheduler im Main Loop + Headless Loop verdrahtet
  - [x] Beweis: Screenshot zeigt `async-subsystem` in Status Bar + `~` bei modifizierten Files

### Phase 3: File Watcher (src/async/file_watcher.zig)

- [x] inotify auf Linux (IN_MODIFY, IN_CREATE, IN_DELETE, IN_MOVED_FROM/TO, IN_CLOSE_WRITE)
- [x] Dedicated Thread, pushes Results in shared result_queue (pushResult)
- [x] Recursive Verzeichnis-Überwachung (addTree)
- [x] poll() mit 100ms timeout für inotify fd
- [x] ResultTag: `.file_changed`, `.file_created`, `.file_deleted`
- [x] Beweis: Screenshot zeigt Status Bar + ~ Indikatoren (async-subsystem Branch)

### Phase 4: LSP Client (src/lsp/)

- [x] Dedicated Reader Thread für stdout → JSON-RPC parsen → result_queue
- [x] Schreiben auf stdin = synchron (buffered, Main Thread oder Worker)
- [x] Request-ID Tracking für Response-Matching
- [x] Referenz: `libs/flow/src/LSP.zig` für Protokoll-Details
- [x] ResultTag: `.lsp_completion`, `.lsp_diagnostics`, `.lsp_hover`, `.lsp_definition`
- [x] wired into build.zig + main.zig

### Phase 5: flow-core Integration

- [x] `TypedInt` — Typisierte IDs für Buffer/Nodes in flow_core verfügbar
- [x] `Buffer/Node` — flow_core.Buffer in code_editor.zig integriert (Rope, Cursor, View, Selection)
- [x] `Keybind` — flow_core.keybind (parse_flow, parse_vim) verfügbar, noch nicht tief integriert
- [x] `File Type Config` — flow_core.file_type_config verfügbar
- [x] `Highlighting` — flow_core.highlight.SyntaxHighlighter in code_editor.zig verwendet
- [x] `Snippet` — flow_core.snippet verfügbar

### Main Loop Integration (src/main.zig)

- [x] Scheduler + Git-Worker als Module ins Haupt-Exe
- [x] `pollResults()` im Render Loop + Headless Loop
- [x] `wio.cancelWait()` erzwingt Redraw wenn Results vorliegen

```zig
// Nach wio.update() und event handling, VOR renderExample():
var result_buf: [32]async_mod.TaskResult = undefined;
const results = scheduler.pollResults(&result_buf);
for (results) |result| {
    switch (result.tag) {
        .git_status => ui_system.updateGitStatus(result),
        .git_branch => ui_system.updateBranch(result),
        .lsp_diagnostics => ui_system.updateDiagnostics(result),
        .file_changed => ui_system.reloadBuffer(result),
        // ...
    }
}
if (results.len > 0) wio.cancelWait(); // Force redraw
```
