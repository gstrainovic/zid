# Zed-Editor Killer - Projektplanung

## 🎯 Ziel

Cross-platform Code Editor (Windows + Linux) mit GPU-Rendering, inspiriert von Zed.

## 📐 Architektur-Entscheidungen

### Cross-platform wo es Sinn macht
- ✅ **WGPU Native** für GPU Rendering (DirectX 12 / Vulkan / Metal)
- ✅ **Clay-Zig** für UI Layout (Flexbox, Constraints - reine Mathematik)
- ✅ **Gooey SVG-Pipeline** für Icons (SVG Path → CPU-Rasterisierung → Texture Atlas Cache → GPU Quad)

### Platform-spezifisch wo Qualität zählt
- 🔴 **Text Rendering**: DirectWrite (Windows) / FreeType+HarfBuzz (Linux)
- 🔴 **Window Management**: wio (cross-platform)
  - **Goran:** wio langt? → **Antwort: Ja für Start, bei Problemen → Win32 direkt (Windows) / Wayland direkt (Linux)**
- 🔴 **Font Discovery**: 
  - **Goran:** Was ist das? Ich will eh nur JetBrains Mono überall!
  - **Antwort:** Wenn wir JetBrains Mono mitliefern (gebundelte Font-Datei), brauchen wir KEINE Font Discovery! Wir laden die .ttf/.otf direkt vom Dateipfad. Spart uns Registry/Fontconfig komplett! ✅

### Gooey-Migration Strategie

**Von Gooey übernehmen:**
- ✅ GPU Rendering Pipeline (Vulkan-basiert)
- ✅ Declarative UI Patterns
- ✅ Component System (Button, TextInput, TextArea, Scroll, etc.)
- ✅ Animation System
- ✅ Theme System (Catppuccin Light/Dark)
- ✅ Entity System
- ✅ Virtual Lists/Tables
- ✅ Code Editor Beispiel (Syntax Highlighting Logic)

**Ersetzen:**
- ❌ Cairo SVG Rasterizing → ✅ **Gooey SVG-Pipeline** (cairo.zig CPU-Rasterisierung + Atlas Cache — einmalig pro Icon, danach GPU)
- ❌ Platform-spezifischer Code → ✅ wio (cross-platform Windowing)
  - **Goran:** Was ist damit gemeint? → **Antwort:** Gooey hatte separaten Code für Windows (Win32), Linux (Wayland/X11), macOS (AppKit). Wir ersetzen das durch wio, das alle Plattformen abdeckt.
- ❌ Font Discovery → ✅ JetBrains Mono direkt laden (keine System-Suche nötig)
  - **Goran:** ? → **Antwort:** Siehe oben - wir bundlen die Font-Datei, fertig!

**Nicht übernehmen:**
- ❌ Linux-spezifischer Code (Wayland, DBus, etc.)
  - **Goran:** Wieso hatte es und wieso brauchen wir es nicht?
  - **Antwort:** Gooey hatte Wayland/X11 für Window-Management + DBus für File-Dialogs. Wir nutzen stattdessen wio für Windows + eigene Vulkan-Renderer. DBus/File-Dialogs können wir später bei Bedarf nachbauen.
- ❌ macOS-spezifischer Code (AppKit, CoreText, Metal) - **Goran:** Brauchen wir nicht, löschen! ✅
- ❌ Web/WASM-spezifischer Code

## 🏗️ Geplante Architektur

```
┌─────────────────────────────────────────────┐
│         DEIN EDITOR (Zig)                   │
├─────────────────────────────────────────────┤
│  UI Layout: Clay-Zig (cross-platform)       │
│  - Flexbox, Constraints, etc.               │
├─────────────────────────────────────────────┤
│  Rendering: WGPU Native (cross-platform)    │
│  - DirectX 12 (Windows) / Vulkan (Linux)    │ Goran: Gooey nutzt Vulkan direkt - WGPU ist aber besser! WGPU abstrahiert DX12/Vulkan automatisch, weniger Code!
│  - Einheitlicher Shader-Code (WGSL)         │
├─────────────────────────────────────────────┤
│  Text Rendering: Platform-spezifisch        │
│  ├─ Windows: DirectWrite → Glyph-Atlas      │
│  └─ Linux: FreeType + HarfBuzz → Glyph-Atlas│ Goran: macOS löschen, brauchen wir nicht! ✅
│       ↓                                     │
│  GPU Texture (einheitlich für WGPU)         │
├─────────────────────────────────────────────┤
│  SVG Icons: Gooey SVG-Pipeline              │
│  - SVG Path → CPU-Rasterisierung (einmalig) │
│  - Texture Atlas Cache → GPU Quad           │
├─────────────────────────────────────────────┤
│  Window Management: wio                     │
│  - Cross-platform (Windows + Linux)         │
│  - Native Zig, Input Handling               │
│  - Stellt Window Handle für WGPU Surface    │
└─────────────────────────────────────────────┘
```

## 💡 UI-Architektur (in Diskussion)

### Idee: Gooey-Teile wiederverwenden

**Problem mit Gooey direkt:**
- Text Rendering Probleme unter Windows
- Zu stark auf Linux/macOS fixiert

**Lösungsansatz:**
- **Von Gooey übernehmen:**
  - GPU Rendering Pipeline (Vulkan-basiert)
  - Declarative UI Patterns
  - Component System (Button, TextInput, etc.)
  - Animation System
  - Theme System
  - **SVG-Pipeline** (cairo.zig Rasterisierung + Atlas Cache) — einmalig pro Icon pro Größe, danach GPU

- **Ersetzen:**
  - ❌ Platform-spezifischer Code → ✅ wio (cross-platform)
  - ❌ Font Discovery → ✅ JetBrains Mono direkt laden

### Text Rendering Strategie

**⚠️ KRITISCHE ERKENNTNIS: FreeType auf Windows = UNBENUTZBAR**

Screenshots von Windows-Test (`/mnt/windows1/Users/gstra/projects/zed-killer`):
- `text_test_result.png` - "HELLLOOO WORLD" extrem verschwommen
- `final_zed_result.png` - Text auf dunklem Hintergrund matschig
- `zed_killer_final.png` - Editor-Text **unleserlich**, Monospace-Font katastrophal

**Ursache:** FreeType ohne Subpixel-Rendering (ClearType) auf Windows erzeugt Graustufen-Anti-Aliasing = matschiger Text.

**✅ Korrekte Strategie:**

**Windows: DirectWrite (NICHT FreeType!)**
- DirectWrite mit ClearType = gestochen scharfer Text
- RGB Subpixel-Rendering wie native Windows-Apps
- **MUSS sein, kein "optional"** - sonst unbenutzbar!

**Linux: FreeType + HarfBuzz**
- Bewährt, gute Qualität mit Subpixel-Hinting

**Font-Strategie: JetBrains Mono bundlen**
- ✅ Wir liefern JetBrains Mono .ttf/.otf mit dem Editor
- ✅ Keine Font Discovery nötig (kein Fontconfig, keine Registry-Suche)
- ✅ Gleiche Font auf beiden Plattformen = konsistentes Aussehen
- ✅ Spart Komplexität!

**Glyph-Atlas Architektur:**
```
Windows: DirectWrite + JetBrainsMono.ttf → Glyph-Atlas (RGBA Textur) → GPU
Linux:   FreeType+HarfBuzz + JetBrainsMono.ttf → Glyph-Atlas (RGBA Textur) → GPU
                                                ↓
                                   Einheitliches GPU-Rendering (WGPU)
```

### SVG Icons: Gooey SVG-Pipeline

**Warum Gooey's SVG statt vkvg:**
- ✅ Existiert bereits, getestet, funktioniert
- ✅ SVG Path Parsing + CPU-Rasterisierung (cairo.zig)
- ✅ Texture Atlas Cache — jedes Icon wird nur einmal gerastert
- ✅ Danach nur GPU Quad Rendering (schnell)
- ✅ Keine extra Vulkan-Instance nötig (vkvg bräuchte eigenen VkDevice)
- ✅ Pure Zig, keine externe Library-Dependency

**vkvg wäre Overkill:**
- Für statische Icons die einmal gecacht werden ist GPU-Rasterisierung unnötig
- Zwei Vulkan-Kontexte (wgpu + vkvg) = Ressourcenverschwendung
- vkvg lohnt sich nur für dynamische 2D-Inhalte (Canvas, Zeichentools)

## ✅ TODO

### Phase 1: Projekt-Setup
- [x] Zig Projekt initialisieren
- [x] WGPU Native als Dependency
- [x] Clay-Zig als Dependency
- [x] ~~vkvg Integration~~ → entschieden: Gooey SVG-Pipeline statt vkvg
- [x] Build-Skripte für Windows + Linux

### Phase 2: Platform Layer - Window Management
- [x] wio als Dependency integrieren
- [x] wio Window erstellen (Linux/Wayland)
- [x] wio → WGPU Surface Verbindung
- [x] Input Event Handling
- [x] Event Loop implementieren

### Phase 3: Rendering
- [x] WGPU Device/Surface Initialisierung
- [x] Basic Triangle Rendering (Test)
- [x] Clay Layout → WGPU Render Commands (Rectangle)
- [x] Clay Renderer für WGPU bauen
  - [x] Rectangle Shader (rectangle.wgsl)
  - [x] ClayRenderer Modul (clay_renderer/mod.zig)
  - [x] Integration in main.zig
  - [x] Vertex Buffer mit COPY_DST Usage
  - [x] Verifiziert: Clay-Rechtecke pro Frame gerendert (Screenshot: phase3_clay_only.png)
  - [x] Event-basierter Render Loop (wio.wait mit Timeout)

- [x] Phase 4: Text Rendering (HÖCHSTE PRIORITÄT!)
  - [x] JetBrains Mono Font-Dateien bundlen (.ttf/.otf)
  - [x] Glyph-Atlas Interface definieren
  - [x] **Gooey TextSystem adaptieren** (Atlas, Cache, Shaper)
    - [x] Gooey's `text_system.zig` → unser TextRenderer
    - [x] Gooey's `atlas.zig` → GPU Glyph-Atlas
    - [x] Gooey's `cache.zig` → Subpixel-Glyph-Cache
    - [x] Gooey's `render.zig` → Text → Scene
    - [x] Gooey's `backends/freetype/` → FreeType Integration
  - [x] **Linux: FreeType + HarfBuzz** (von Gooey)
    - [x] JetBrainsMono.ttf laden
    - [x] Subpixel-Hinting konfigurieren
    - [x] Gooey's `backends/freetype/` integriert
  - [x] GPU Text Renderer (gpu_renderer.zig)
    - [x] Text-Color Pipeline (einfache Quads)
    - [x] NDC-Koordinaten (-1 bis 1)
    - [x] Verifiziert: "HELLO" als Text sichtbar (Screenshot: phase4_text.png)
    - [x] Text-Atlas Shader vorbereitet (text_atlas.wgsl)
    - [x] Glyph-Atlas Rendering mit echten Font-Glyphen
  - [x] **Windows: DirectWrite Integration** (MUSS sein!) - *Erfolgreich implementiert*

### Phase 5: UI Components (von Gooey lernen, mit wgpu+wio bauen)
- [x] Scene-System (Gooey's `scene.zig` → WGPU Buffers)
  - [x] Quad (Rechtecke) - funktioniert mit Clay
  - [x] GlyphInstance (Text) - funktioniert mit Clay + GPURenderer
- [x] UI Primitives (Box, Text)
  - [x] Box (Rechtecke mit Clay)
  - [x] Text (FreeType + GPU Rendering)
  - [x] Image (Pixeldaten → wgpu Texture → Textured Quad) - *Voraussetzung für Phase 7 (SVG Icons) und Phase 9 (Bild-/SVG-Preview)*
- [x] Button, TextInput, TextArea, ScrollContainer
  - [x] Button (primary Farbe)
  - [x] TextInput (surface Farbe)
  - [x] TextArea (overlay Farbe)
  - [x] ScrollContainer (accent Farbe)
- [x] Theme System (Catppuccin Light/Dark)
  - [x] Dark Theme (Macchiato) - aktiv
  - [x] Light Theme (Latte) - verfügbar
- [x] Animation System
  - [x] Fade, Slide, Scale Animationen (vom User bestätigt - funktionierte live)
  - [x] Easing functions
  - [x] AnimationManager

### Phase 6: Code Editor
- [x] Code Editor Container mit Line Numbers Gutter
  - [x] Editor Container (dunkel)
  - [x] Line Numbers Gutter (dunkler, links)
  - [x] Screenshot beweis: screenshots/phase6_codeeditor_v2.png
- [x] Syntax Highlighting Logic (von Gooey's `code_editor_state.zig`)
  - [x] Highlighter Modul (src/editor/highlighter.zig)
  - [x] Keywords, Strings, Comments, Numbers, Types farbig hervorgehoben
- [x] Current Line Highlight
  - [x] Helle Hintergrundfarbe für aktuelle Zeile
- [x] Scrollable Editor-Content
  - [x] Editor-Content in ScrollContainer

### Phase 7: SVG Icons (Gooey SVG-Pipeline) - *durch Benutzer verifiziert*
- [x] Gooey SVG-Module integrieren
  - [x] `svg/rasterizer.zig` (Platform-Dispatcher → cairo.zig auf Linux)
  - [x] `svg/atlas.zig` (Texture Atlas Cache für gerasterte Icons)
  - [x] `scene/svg.zig` (SVG Path Parser)
  - [x] `svg/backends/cairo.zig` (CPU-Rasterisierung, pure Zig)
- [x] SVG Atlas als wgpu Texture hochladen
- [x] Icon Rendering als Textured Quads in Clay UI
- [x] Lucide Icons einbinden (wie Gooey's `examples/lucide_demo.zig`)
- [x] ~~vkvg Bindings~~ — entfernt, Gooey SVG-Pipeline reicht für gecachte Icons

### Phase 8: Interaktion & Editor-Logik (Input, State & Interaction Layer)
- [x] **Input Handling (wio → Clay)**
  - [x] Maus-Events (Move, Click, Scroll) von wio abfangen (`src/main.zig` und `src/platform/mod.zig`)
  - [x] Maus-Position an Clay-Zig weiterleiten (`clay.setPointerState`)
  - [x] Scroll-Events an Clay-Zig weiterleiten (`clay.updateScrollContainers`)
  - [x] Tastatur-Events (Press, Release, Text Input) abfangen
- [x] **Text-Buffer & Cursor Management**
  - [x] Echte Datenstruktur für Text (z.B. Gap-Buffer, Line-Array oder Rope) statt statischer Strings (`src/editor/code_editor.zig`)
  - [x] Cursor-Position (Zeile/Spalte) verwalten und visuell rendern (Blinkender Cursor)
  - [x] Cursor-Navigation (Pfeiltasten, Pos1, Ende, Bild auf/ab)
- [x] **Text Selection (Markieren)**
  - [x] Start- und End-Position der Markierung verwalten
  - [x] Maus-Drag-Logik zum Erstellen von Markierungen (Event-Listener in UI)
  - [x] Markierten Text visuell hervorheben (Hintergrundfarbe hinter Glyph-Instanzen rendern)
- [x] **Text Editing**
  - [x] Zeichen einfügen an Cursor-Position (Keyboard Text-Input)
  - [x] Zeichen löschen (Backspace, Delete)
  - [x] Neue Zeilen einfügen (Enter)
  - [x] Berücksichtigung von markiertem Text beim Tippen (Ersetzen)
- [x] **Viewport & Scrolling Logik (Editor)**
  - [x] Berechnung der sichtbaren Zeilen anhand des Scroll-Offsets (Viewport Culling)
  - [x] Synchronisation zwischen Clay-ScrollContainer und Editor-State
  - [x] Auto-Scroll, wenn Cursor den sichtbaren Bereich verlässt
  - [x] **Performance-Test mit Großdatei:** `libs/gooey/src/layout/engine.zig` (3363 Zeilen) beim Start laden und Scrolling testen
  - [x] **Clipboard Integration**
    - [x] Kopieren, Ausschneiden, Einfügen via Tastatur-Shortcuts (Ctrl+C, Ctrl+X, Ctrl+V)
    - [x] Integration mit System-Zwischenablage (via wio oder Platform-Code)
  - [x] **Maus-Interaktion & Kontextmenü**
    - [x] Rechtsklick-Erkennung im Editor
    - [x] Einfaches Kontextmenü (Clay UI) mit "Copy", "Cut", "Paste"
- [x] **Undo/Redo**
  - [x] Undo-Stack (Ctrl+Z)
  - [x] Redo-Stack (Ctrl+Y / Ctrl+Shift+Z)
  - [x] **Verifiziert:** Alle Phase-8 Features visuell bestätigt (screenshot: phase8_verify.png)

### Phase 9: File Explorer, Tabs & Datei-Vorschau
- [x] **Tab-Leiste**
  - [x] Offene Dateien als Tabs darstellen (Clay Layout)
  - [x] Tab wechseln (Klick), Tab schließen (X-Button)
  - [x] Aktiver Tab visuell hervorgehoben
  - [x] Tab-Label vollständig sichtbar (nicht abgeschnitten wie ".n.zig")
  - [x] Close-Icon (X) korrekt als SVG rendern (statt rotem Quadrat)
  - [x] SVG-Icons im File Explorer korrekt farbig (nicht schwarz)
- [x] **File Explorer (Sidebar)**
  - [x] Verzeichnisbaum anzeigen (Tree-Widget)
  - [x] Ordner auf/zuklappen
  - [x] Datei-Icons via Gooey SVG-Pipeline (Phase 7)
  - [x] Datei öffnen per Klick → neuer Tab
- [ ] **SVG-Datei Preview**
  - [ ] SVG-Dateien im Editor-Tab als Bild anzeigen (wie VSCode)
  - [ ] cairo.zig rasterisiert SVG → wgpu Texture → Textured Quad im Tab
- [ ] **Bild-Datei Preview**
  - [ ] PNG/JPG im Editor-Tab anzeigen

## 🔮 Phase 10: Flow-Editor Integration (GPU-beschleunigt, Cross-Platform)

**Ziel:** Flow's Editor-Kern (Rope Buffer, Syntax Highlighting, LSP, Actors) mit Vulkan-Ed's GUI (wgpu + Clay + wio) verbinden.

### Architektur

```
┌─────────────────────────────────────────────────────┐
│  Flow's App-Logik (unverändert!)                    │
│  - Buffer (Rope), Syntax, LSP, Actors, Keybindings │
│  - TUI/Editor-Code (tui/*.zig)                     │
└────────────────────┬────────────────────────────────┘
                     │ Thespian Messages
        ┌────────────┴────────────┐
        │                         │
        ▼ (alt)                   ▼ (neu)
┌──────────────────┐   ┌──────────────────────┐
│ win32/gui.zig    │   │ vulkan-ed/gui.zig    │
│ - HWND           │ →   │ - wio Window         │
│ - D3D11          │   │ - wgpu Renderer      │
│ - Win32 Input    │   │ - Clay Layout        │
│ - DirectWrite    │   │ - wgpu Font-Atlas    │
│ Windows-only     │   │ - Linux + Windows    │
└──────────────────┘   └──────────────────────┘
```

### Phase 10.2: Flow's win32/gui.zig durch wio+wgpu ersetzen
- [x] `libs/flow/src/vulkan_ed_gui.zig` erstellen (ersetzt win32/gui.zig)
  - [x] wio Window erstellen
  - [x] wgpu Renderer initialisieren
  - [x] Resize → sendResize("RDR", "Resize", ...) an Flow TUI
  - [x] Input → sendKey() / sendMouse() an Flow TUI
  - [x] vaxis.Screen empfangen → wgpu Cell-Rendering
- [x] **Verifikation:** `zig build -Dgui` → flow-gui Binary erfolgreich erstellt (178MB)

### Phase 10.3: Vulkan-Ed Explorer + Tabs integrieren
- [ ] File Explorer → Flow Buffer öffnen
- [ ] Tabs → pro Tab ein Flow Buffer
- **Verifikation:** Screenshot → Explorer + Flow-Editor + Tabs

## 🎯 Phase 11: vulkan-ed als 3. Renderer in Flow

**Architektur-Entscheidung (final):** vulkan-ed wird **nicht** als externes Repo neben Flow betrieben, sondern als **dritte Renderer-Variante** innerhalb von Flow integriert — analog zu `src/renderer/vaxis/` (Terminal) und `src/renderer/win32/` (D3D11+DirectWrite).

**Threading-Modell:** Weg 1 — Thespian bleibt auf Main-Thread (`ctx.run()`), wio+wgpu+Clay laufen auf Worker-Thread, gestartet via `std.Thread.spawn` aus dem TUI-Actor heraus. Exakt das Muster von `libs/flow/src/win32/gui.zig:304-310`. Begründung: auch Flows experimentelle `wio-sokol-gui`-Branch geht diesen Weg — Thespian's `ctx.run()` will den Main-Thread (Signal-Handler, Entry-Actor, Teardown). macOS bleibt damit faktisch ausgeschlossen, ist laut Projekt-Scope aber sowieso kein Ziel.

**Build-Switch:** `-Drenderer={vaxis|win32|vulkan_ed|auto}` ersetzt das binäre `-Dgui`-Flag. Default `auto` wählt plattformabhängig.

### Phase 11.A — Renderer-Skeleton (baut, schwarzes Fenster)
- [x] Ordner `libs/flow/src/renderer/vulkan_ed/` mit `renderer.zig`, `gui.zig`, `Plane.zig`, `Cell.zig`, `style.zig`, `input.zig`
- [x] `Cell.zig`/`Plane.zig`/`style.zig` 1:1 von `src/renderer/vaxis/` kopieren (reines Daten-Layout, keine Backend-Logik)
- [x] `renderer.zig` als Stub mit voller API-Oberfläche von `src/renderer/win32/renderer.zig` (510 Zeilen): `init`, `deinit`, `run`, `render`, `stop`, `stdplane`, `process_renderer_event`, `set_fontsize`, `adjust_fontsize`, `reset_fontsize`, `set_fontface`, `reset_fontface`, `get_fontfaces`, `set_terminal_title`, `set_terminal_style`, `set_sgr_pixel_mode_support`, `set_mouse_cursor`. Bodies: `_ = self; return;` oder `return error.NotImplemented`
- [x] `init()` ruft `gui.init()`, `run()` ruft `try gui.start()` (gibt Worker-Thread zurück, blockiert nicht)
- [x] **Verifikation A:** `zig build check` + `zig build check -Drenderer=vulkan_ed` bauen erfolgreich

### Phase 11.B — wio-Window auf Worker-Thread
- [x] `gui.zig` Skeleton aus `src/win32/gui.zig:300-380` ableiten:
  - [x] `global` Struct mit `init_called`, `start_called`, `window`, `tui_pid`
  - [x] `pub fn init() void` — wio einmalig initialisieren
  - [x] `pub fn start() !std.Thread` — `tui_pid = thespian.self_pid().clone()`, dann `std.Thread.spawn(.{}, entry, .{})`
  - [x] `fn entry() !void` — wio.createWindow + Event-Loop `while (wio.run()) |event| handleEvent(event)`
- [x] `wio` Dependency in `libs/flow/build.zig.zon` ergänzen (Pfad zu lokalem Submodule)
- [x] Neues Build-Modul `vulkan_ed_gui_mod` in `libs/flow/build.zig` parallel zu `gui_mod`. Imports: `wio`, `cbor`, `thespian`, `input`, `vaxis`
- [x] **Verifikation B:** Build durch mit `-Drenderer=vulkan_ed`

### Phase 11.C — Vendoring (verschoben aus 11.H, war falsch sortiert)

**Begründung Reorder (2026-04-13):** Ursprünglicher Plan wollte erst wgpu-Surface neu schreiben (11.C), dann später vendoren (11.H). Falsch — vulkan-ed hat funktionierenden wio+wgpu+Atlas+Cell-Render-Stack. Erst vendoren, dann adaptieren. Spart ~2 Tage Doppelarbeit + verhindert Bug-Drift zwischen beiden Implementierungen.

- [ ] `vulkan-ed/src/text/` → `libs/flow/src/renderer/vulkan_ed/text/`
- [ ] `vulkan-ed/src/clay_renderer/` → `libs/flow/src/renderer/vulkan_ed/clay_renderer/`
- [ ] `vulkan-ed/src/rendering/` → `libs/flow/src/renderer/vulkan_ed/rendering/`
- [ ] `vulkan-ed/src/svg/` → `libs/flow/src/renderer/vulkan_ed/svg/` (nur falls von text/ benötigt)
- [ ] `vulkan-ed/src/platform/` → `libs/flow/src/renderer/vulkan_ed/platform/` (wgpu-Surface Helpers)
- [ ] Shaders (`*.wgsl`) + `JetBrainsMono.ttf` mitnehmen
- [ ] Imports anpassen (relative Pfade)
- [ ] `wgpu_native_zig` + `clay-zig` Deps in `libs/flow/build.zig.zon`
- [ ] Build-Modul `vulkan_ed_gui_mod` um neue Imports erweitern
- **Verifikation C:** `zig build -Drenderer=vulkan_ed` baut ohne Fehler

### Phase 11.D — Render-Loop adaptieren (vendored Stack → Flow)
- [ ] `gui.zig`/`entry()` ersetzt `vulkan-ed/src/main.zig` Worker-Loop. Anpassungen:
  - `main()` → `entry(pid: thespian.pid)`
  - Standalone GPA → `std.heap.page_allocator` (Worker-Thread-tauglich)
  - Editor-State raus, stattdessen `vaxis.Screen` Cell-Buffer als Render-Quelle
- [ ] Cell-Renderer schreiben (auf vendored Atlas + GPU-Pipeline):
  - Pro Cell: Background-Quad mit Cell.bg
  - Glyph aus Atlas mit Cell.fg
  - Cursor: separater Quad-Pass
- [ ] `process_renderer_event()` empfängt Screen-Diff (Wire-Format aus `src/renderer/win32/renderer.zig:195-280`) → in Shared-Cell-Buffer schreiben
- [ ] Resize-Event: Surface reconfigure + Cell-Counts neu berechnen
- **Verifikation D:** Screenshot zeigt Flow-Editor mit Text + Syntax + Cursor

### Phase 11.E — Input: wio → Thespian → Flow-TUI
- [ ] wio-Event-Mapping nach Pattern aus `src/renderer/vaxis/input.zig` — Tasten in Flow's `input` Modul-Codes übersetzen
- [ ] Pro Event: `gui.tui_pid.send(.{"i", scancode, codepoint, modifiers, key_string})` (exakt das Wire-Format aus `src/win32/gui.zig` — dann braucht TUI-Layer keine Anpassung)
- [ ] Resize-Event: Fenstergröße in Cell-Counts umrechnen, `tui_pid.send(.{"RDR", "Resize", cols, rows, cell_w, cell_h})`
- **Verifikation E:** Tippen, Pfeiltasten, Enter, Backspace funktionieren. Resize ändert Editor-Layout

### Phase 11.F — Font/Theme/Window-Title
- [ ] `set_fontsize`, `adjust_fontsize`, `reset_fontsize` → Atlas regenerieren mit neuer Größe
- [ ] `set_terminal_title` → `wio.setWindowTitle()`
- [ ] `set_terminal_style` → speichern, beim nächsten Render verwenden
- [ ] `set_mouse_cursor` → `wio.setCursor()`
- **Verifikation F:** Ctrl++/Ctrl+- ändert Fontgröße live, Fenstertitel zeigt Dateiname

### Phase 11.G — build.zig Switch: `-Drenderer=`
- [x] `libs/flow/build.zig` Zeile 13 erweitern:
  ```zig
  const RendererKind = enum { auto, vaxis, win32, vulkan_ed };
  const renderer_kind = b.option(RendererKind, "renderer", "Renderer backend") orelse .auto;
  const gui = b.option(bool, "gui", "Standalone GUI mode") orelse (renderer_kind != .auto and renderer_kind != .vaxis);
  ```
- [x] Im `renderer_mod`-blk Verzweigung auf `renderer_kind` einbauen
- [x] Default-Logik: `auto` + `gui=true` → Plattform-Default (Windows: `win32`, sonst `vulkan_ed`)
- [x] **Verifikation G:**
  - `zig build check` → vaxis (TUI) ✅
  - `zig build check -Drenderer=vulkan_ed` → vulkan_ed baut erfolgreich ✅

### Phase 11.H — ENTFERNT (in 11.C aufgegangen)

### Phase 11.I — Verifikation & Aufräumen
- [ ] Alle 3 Renderer testen:
  - `zig build run` (vaxis, Terminal)
  - `zig build -Dgui run` (win32, D3D11)
  - `zig build -Drenderer=vulkan_ed run` (wgpu+wio)
- [ ] Großdatei-Test: `libs/gooey/src/layout/engine.zig` (3363 Zeilen) öffnen, scrollen, Performance vergleichen mit win32-Renderer
- [ ] Linux-Build prüfen (Cross-compile oder WSL): `zig build -Drenderer=vulkan_ed -Dtarget=x86_64-linux`
- [ ] Phase 10.3 anhängen: Explorer/Tabs aus vulkan-ed → Flow-Buffer-Kommandos

### Reihenfolge & Aufwand

| Phase | Aufwand | Risiko | Blocker für |
|-------|---------|--------|-------------|
| 11.A | 1 Tag   | niedrig | alle | ✅ |
| 11.B | 1 Tag   | niedrig | C–F | ✅ |
| 11.C | 1 Tag   | niedrig (mechanisches Vendoring) | D | offen |
| 11.D | 2–3 Tage | hoch (Cell-Pipeline auf vaxis.Screen) | I | offen |
| 11.E | 1 Tag   | mittel (Key-Mapping vollständig) | I | offen |
| 11.F | 0.5 Tag | niedrig | I | offen |
| 11.G | 0.5 Tag | niedrig | — | ✅ |
| 11.H | — | — | — | entfernt |
| 11.I | 0.5 Tag | — | — | offen |

**Gesamt:** ~6–8 Arbeitstage. **Kritischer Pfad:** A → B → C → D. Phasen E/F können parallel zu D laufen.

**Verworfen:** wgpu/wio in `gui.zig` neu schreiben. Stash in `libs/flow`: `Phase 11.C wgpu re-init (verkehrt rum, sollte vendored werden)` — bei Bedarf via `git stash list` einsehbar, sonst droppen.

## 🛠️ Windows-Build ohne Admin

**Problem:** Flow's tree-sitter-Tarballs enthalten Unix-Symlinks (Grammars teilen Query-Dateien). Auf Windows ohne `SeCreateSymbolicLinkPrivilege` (Admin oder Developer Mode) bricht der Zig-Package-Manager beim Unpack mit `AccessDenied` ab.

**Lösung:** `scripts/fix_zig_cache.py` befüllt `%LOCALAPPDATA%\zig\p\<name>-<version>-<hash>\` manuell — Tarball wird heruntergeladen und mit Symlinks-als-Kopien ausgepackt. Nutzt `\\?\`-Pfad-Präfix für Windows Long-Path-Workaround.

**Nutzung bei Symlink-Fehler:**
```bash
python scripts/fix_zig_cache.py add "<name>-<version>-<hash>" "<tarball-url>"
```
Hash und URL kommen direkt aus der Zig-Fehlermeldung. Erfolgreich getestet mit `tree_sitter-0.26.7-z0LhyJOPZzF4S6ZW6MrFTfJgiM9Fp81hqKrXUKSBaUAc`.

## 📚 Verfügbare Libraries

| Library | Zweck | Status |
|---------|-------|--------|
| clay-zig | UI Layout Engine | ✅ Verfügbar |
| wgpu_native_zig | GPU Rendering (DX12/Vulkan/Metal) | ✅ Verfügbar |
| gooey (SVG-Pipeline) | SVG Icons (Rasterisierung + Atlas Cache) | ✅ Verfügbar |
| **wio** | **Window Management + Input (cross-platform)** | ✅ Im Windows-Fork verwendet |
| gooey | UI Framework (Referenz/Inspiration) | ⚠️ Nur Linux/macOS |

## 🔗 Resources

- Gooey Win-Fail Branch: `/home/g/projects/vulkan-ed/gooey-win-fail`
- **Windows Zed-Killer (Screenshots!):** `/mnt/windows1/Users/gstra/projects/zed-killer`
  - `text_test_result.png` - FreeType Text-Qualität katastrophal
  - `final_zed_result.png` - Dunkler Hintergrund, immer noch unscharf
  - `zed_killer_final.png` - Editor unbenutzbar
- Clay-Zig: `/home/g/projects/vulkan-ed/clay-zig`
- WGPU: `/home/g/projects/vulkan-ed/wgpu_native_zig`
- Gooey (Referenz): `/home/g/projects/vulkan-ed/gooey`

## 📖 Lessons Learned aus Gooey Windows Fail

1. **FreeType auf Windows = unbenutzbar** (kein Subpixel-Rendering)
2. **DirectWrite ist Pflicht** für Windows, kein "nice-to-have"
3. **NanoVG als Cairo-Ersatz** war nicht implementiert (nur placeholder)
4. **wio + Vulkan Platform-Code** ist gut - kann übernommen werden
5. **Gooey SVG-Pipeline > vkvg** für Icons — CPU-Rasterisierung + Atlas Cache reicht, vkvg braucht eigene Vulkan-Instance = Overkill
6. **WGPU hat kein Window Management** - wio verwenden
7. **Windows Fork Code ist brauchbar** - nur Text/SVG müssen ersetzt werden
8. **JetBrains Mono bundlen** - keine Font Discovery nötig (spart Komplexität!)
9. **macOS/WASM nicht unterstützen** - Fokus auf Windows + Linux
10. **WGPU > direktes Vulkan** - abstrahiert DX12/Vulkan automatisch, weniger Code
