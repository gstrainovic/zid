# Offene Punkte

- `scripts/e2e_shortcuts.py` scheitert bei „Ctrl+Tab wechselt zyklisch“: der Test ist älter als
  der MRU-Commit 02a43b4, `e2e_tabs.py` prüft bereits das neue Verhalten. Test an MRU anpassen
  oder den Schritt streichen.
- `explorer_entries` (E2E-RPC) liest im Server-Thread `file_explorer.git_status`, während der
  Main-Thread es in `updateGitStatus` ersetzt. Unter `VULKAN_ED_PAGE_ALLOC=1` einmal als Segfault
  in `isIgnored` sichtbar. RPC-Lesezugriffe wie die Eingaben puffern und im Main-Thread
  beantworten (siehe AGENTS.md, Server-Thread-Schwäche).
- `git_worker.runGitCwd` verwirft stderr, im Log steht nur `git exited 128`. Stderr mitloggen
  und für Ordner ohne Repo (z. B. `~/projects`) gar keine git-Tasks einreihen.
- `src/ui/mod.zig`, `src/main.zig`, `src/ui/file_explorer.zig` sind nicht `zig fmt`-konform
  (schon vor dem UAF-Fix). In einem eigenen Commit formatieren.
