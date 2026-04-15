# TODO - vulkan-ed

## Phase 16: Embedded Terminal (ghostty-vt)

### Build Integration
- [x] ghostty als path-Dependency in build.zig.zon
- [x] ghostty-vt als lazyDependency in build.zig (SIMD=false)
- [x] Build erfolgreich (zig build = 0 errors)

### Terminal Module (src/terminal/)
- [x] mod.zig — Module Root
- [x] conpty.zig — Windows ConPTY Wrapper (CreatePseudoConsole, Pipes, Spawn)
- [x] terminal_instance.zig — High-level API (ConPTY + ghostty-vt + Read Thread)
- [x] VT Stream statt printString (proper escape sequence parsing)

### UI Integration
- [x] FileKind.terminal Variant hinzugefügt
- [x] TabBarState.openTerminal() Methode
- [x] TabBarState.terminal_instances HashMap
- [x] Terminal-aware closeTab() mit Cleanup
- [x] "New Terminal" Button → openTerminal() statt ghostty.exe spawn
- [x] renderTerminalContent() in UI mod.zig
- [x] Input Forwarding: handleKeyPress/handleChar → Terminal wenn aktiv
- [x] Key→VT Translation (Enter, Backspace, Arrow Keys, etc.)

### Verification & Polish
- [ ] zig build run — Terminal Tab öffnen und Shell-Output sehen
- [ ] Screenshot-Verifikation: Terminal Tab mit PowerShell prompt
- [ ] Ctrl+C Forwarding testen
- [ ] Review für Phase 16

## Phase 15: Resizable File Explorer (previous)
- [x] FileExplorerState um `width: f32` erweitern
- [x] Splitter-UI-Element zwischen Sidebar und Editor
- [x] Drag-Logic für Splitter (Maus-Interaktion)
- [x] Visuelle Rückmeldung beim Hovern über Splitter