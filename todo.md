# Todo

14.1a split soll man verschieben können, ähnlich wie man es beim explorer kann.

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
- [ ] UI: `ui_system.updateGitStatus()` — Branch in Statusbar, File-Status im Explorer

### Phase 3: File Watcher (src/async/file_watcher.zig)

- [ ] inotify auf Linux (IN_MODIFY, IN_CREATE, IN_DELETE, IN_MOVE)
- [ ] Dedicated Thread, pushed Results in shared result_queue
- [ ] Debouncing (100ms) — nicht jedes inotify-Event sofort propagieren
- [ ] ResultTag: `.file_changed`, `.file_created`, `.file_deleted`

### Phase 4: LSP Client (src/lsp/)

- [ ] Dedicated Reader Thread für stdout → JSON-RPC parsen → result_queue
- [ ] Schreiben auf stdin = synchron (buffered, Main Thread oder Worker)
- [ ] Request-ID Tracking für Response-Matching
- [ ] Referenz: `libs/flow/src/LSP.zig` für Protokoll-Details
- [ ] ResultTag: `.lsp_completion`, `.lsp_diagnostics`, `.lsp_hover`, `.lsp_definition`

### Phase 5: flow-core Integration

- [ ] `TypedInt` — Typisierte IDs für Buffer/Nodes nach `libs/flow-core/`
- [ ] `Buffer/Node` — Kern-Rope-Struktur evaluieren vs. bestehende Implementierung
- [ ] `Keybind` — Input-Parsers (flow + vim Stile)
- [ ] `File Type Config` — Dateityp-spezifische Konfiguration
- [ ] `Highlighting` — Tree-sitter Integration evaluieren
- [ ] `Snippet` — Snippet-Parsing

### Main Loop Integration (src/main.zig)

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
