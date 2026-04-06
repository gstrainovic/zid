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
  - [ ] **Windows: DirectWrite Integration** (MUSS sein!) - *Ausstehend für Windows-Build*

### Phase 5: UI Components (von Gooey lernen, mit wgpu+wio bauen)
- [x] Scene-System (Gooey's `scene.zig` → WGPU Buffers)
  - [x] Quad (Rechtecke) - funktioniert mit Clay
  - [x] GlyphInstance (Text) - funktioniert mit Clay + GPURenderer
  - [ ] Shadow (Drop Shadows) - *In Clay-Zig Bindings v0.2.2 nicht direkt verfügbar*
- [x] UI Primitives (Box, Text)
  - [x] Box (Rechtecke mit Clay)
  - [x] Text (FreeType + GPU Rendering)
  - [ ] Image - *Später bei Bedarf (aktuell nicht benötigt)*
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

### Phase 7: SVG Icons (Gooey SVG-Pipeline)
- [ ] Gooey SVG-Module integrieren
  - [ ] `svg/rasterizer.zig` (Platform-Dispatcher → cairo.zig auf Linux)
  - [ ] `svg/atlas.zig` (Texture Atlas Cache für gerasterte Icons)
  - [ ] `scene/svg.zig` (SVG Path Parser)
  - [ ] `svg/backends/cairo.zig` (CPU-Rasterisierung, pure Zig)
- [ ] SVG Atlas als wgpu Texture hochladen
- [ ] Icon Rendering als Textured Quads in Clay UI
- [ ] Lucide Icons einbinden (wie Gooey's `examples/lucide_demo.zig`)
- [~] ~~vkvg Bindings~~ — entfernt, Gooey SVG-Pipeline reicht für gecachte Icons

### Phase 8: Interaktion & Editor-Logik (Input, State & Interaction Layer)
- [ ] **Input Handling (wio → Clay)**
  - [ ] Maus-Events (Move, Click, Scroll) von wio abfangen (`src/main.zig` und `src/platform/mod.zig`)
  - [ ] Maus-Position an Clay-Zig weiterleiten (`clay.setPointerState`)
  - [ ] Scroll-Events an Clay-Zig weiterleiten (`clay.updateScrollContainers`)
  - [ ] Tastatur-Events (Press, Release, Text Input) abfangen
- [ ] **Text-Buffer & Cursor Management**
  - [ ] Echte Datenstruktur für Text (z.B. Gap-Buffer, Line-Array oder Rope) statt statischer Strings (`src/editor/code_editor.zig`)
  - [ ] Cursor-Position (Zeile/Spalte) verwalten und visuell rendern (Blinkender Cursor)
  - [ ] Cursor-Navigation (Pfeiltasten, Pos1, Ende, Bild auf/ab)
- [ ] **Text Selection (Markieren)**
  - [ ] Start- und End-Position der Markierung verwalten
  - [ ] Maus-Drag-Logik zum Erstellen von Markierungen (Event-Listener in UI)
  - [ ] Markierten Text visuell hervorheben (Hintergrundfarbe hinter Glyph-Instanzen rendern)
- [ ] **Text Editing**
  - [ ] Zeichen einfügen an Cursor-Position (Keyboard Text-Input)
  - [ ] Zeichen löschen (Backspace, Delete)
  - [ ] Neue Zeilen einfügen (Enter)
  - [ ] Berücksichtigung von markiertem Text beim Tippen (Ersetzen)
- [ ] **Viewport & Scrolling Logik (Editor)**
  - [ ] Berechnung der sichtbaren Zeilen anhand des Scroll-Offsets (Viewport Culling)
  - [ ] Synchronisation zwischen Clay-ScrollContainer und Editor-State
  - [ ] Auto-Scroll, wenn Cursor den sichtbaren Bereich verlässt

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
