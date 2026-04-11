# Flow GUI Protocol – Thespian Interface Specification

**Dokumentiert das Protokoll zwischen Flow's TUI-App (Buffer, Syntax, LSP) und dem GUI-Renderer.**

Dieses Protokoll ist die **einzige** Schnittstelle zwischen Editor-Logik und Rendering.
Ein neuer Renderer (wgpu + Clay + wio) muss dieses Protokoll implementieren – der Rest von Flow bleibt unverändert.

---

## Architektur

```
┌──────────────────────────────────────┐
│  Flow TUI-App (tui/*.zig)            │
│  - Buffer, Syntax, LSP, Keybindings  │
│  - Erzeugt vaxis.Screen (Cell-Grid)  │
└──────────────┬───────────────────────┘
               │ Thespian Messages (CBOR)
    ┌──────────┴──────────┐
    │                     │
    ▼ (GUI schickt)       ▼ (TUI schickt)
┌──────────────┐  ┌─────────────────────┐
│ GUI-Renderer │  │ WM_APP_UPDATE_SCREEN│
│ (ersetzen!)  │  │ (synchron, HWND)    │
│ - wio Window │  │                     │
│ - wgpu       │  │                     │
│ - Input      │  │                     │
└──────────────┘  └─────────────────────┘
```

---

## 1. GUI → TUI Messages (Renderer schickt an App)

**Format:** Thespian Message (CBOR-serialisiert)
**Quelle:** `win32/gui.zig`
**Empfänger:** `tui/tui.zig:receive_safe()` → `rdr_.process_renderer_event()`

### 1.1 WindowCreated

Wird gesendet wenn das Fenster erstellt wurde.

```zig
pid.send(.{
    "RDR",
    "WindowCreated",
    hwnd_ptr,  // usize: HWND pointer (Windows-spezifisch)
})
```

| Feld | Typ | Bedeutung |
|---|---|---|
| `"RDR"` | string | Namespace: Renderer |
| `"WindowCreated"` | string | Event-Name |
| `hwnd_ptr` | usize | Windows HWND (für unsere GUI: ignoriert oder Window-Handle) |

**Verarbeitung in TUI:** `tui.zig:409` → `rdr_.process_renderer_event()`

**Für Vulkan-Ed:** Window-Handle speichern für `updateScreen()` Aufrufe.

---

### 1.2 Resize

Wird gesendet wenn Fenster-Größe sich ändert.

```zig
state.pid.send(.{
    "RDR",
    "Resize",
    client_cell_count.x,  // u16: Anzahl Cells horizontal
    client_cell_count.y,  // u16: Anzahl Cells vertikal
    client_size.x,        // u16: Pixel-Breite
    client_size.y,        // u16: Pixel-Höhe
})
```

| Feld | Typ | Bedeutung |
|---|---|---|
| `"RDR"` | string | Namespace |
| `"Resize"` | string | Event-Name |
| `client_cell_count.x` | u16 | Zellen horizontal |
| `client_cell_count.y` | u16 | Zellen vertikal |
| `client_size.x` | u16 | Pixel-Breite |
| `client_size.y` | u16 | Pixel-Höhe |

**Verarbeitung in TUI:** `renderer/vaxis/renderer.zig:winsize` → `self.resize(ws)` → Screen-Buffer neu berechnen

**Für Vulkan-Ed:**
- wio Resize-Event → Cell-Count berechnen (Pixel / Font-Size)
- Message an TUI schicken
- TUI antwortet mit neuem `vaxis.Screen`

---

### 1.3 Input (Keyboard)

Wird gesendet bei Tastatureingaben.

```zig
state.pid.send(.{
    "RDR",
    "I",
    event,           // u8: input.event.press (1), repeat (2), release (3)
    key_code,        // u21: Key-Code (KKP format)
    codepoint,       // u21: Unicode-Codepoint
    utf8_text,       // []const u8: UTF-8 encodierter Text (leer bei release/modifiers)
    mod_bits,        // u8: Modifier-Bitmaske
})
```

| Feld | Typ | Bedeutung |
|---|---|---|
| `"RDR"` | string | Namespace |
| `"I"` | string | Event-Typ: Input |
| `event` | u8 | `1` = press, `2` = repeat, `3` = release |
| `key_code` | u21 | Key-Code (siehe Key-Codes unten) |
| `codepoint` | u21 | Unicode-Codepoint des Zeichens |
| `utf8_text` | []const u8 | UTF-8 Text (nur bei press ohne Modifier) |
| `mod_bits` | u8 | Modifier-Bits (siehe Modifier unten) |

**Verarbeitung in TUI:** `renderer/vaxis/renderer.zig:280` → `key_press` oder `key_release` → `dispatch_input()`

**Für Vulkan-Ed:**
- wio Keyboard-Event → Key-Code mappen (siehe Key-Codes unten)
- Modifier aus wio-Flags berechnen
- Message an TUI schicken

---

### 1.4 Mouse

#### 1.4.1 Mouse Move

```zig
// Ohne gedrückter Taste:
state.pid.send(.{
    "RDR",
    "M",
    cell.x,        // i32: Cell-Spalte
    cell.y,        // i32: Cell-Zeile
    offset.x,      // i32: Pixel-Offset innerhalb der Cell
    offset.y,      // i32: Pixel-Offset innerhalb der Cell
})

// Mit gedrückter linker Maustaste (Drag):
state.pid.send(.{
    "RDR",
    "D",
    @intFromEnum(input.mouse.BUTTON1),  // u8: Button
    cell.x, cell.y, offset.x, offset.y,
})
```

#### 1.4.2 Mouse Button (Press/Release)

```zig
state.pid.send(.{
    "RDR",
    "B",
    event_type,    // u8: input.event.press (0) oder input.event.release (1)
    button,        // u8: Button-ID (siehe unten)
    cell.x, cell.y, offset.x, offset.y,
})
```

| Feld | Typ | Bedeutung |
|---|---|---|
| `"RDR"` | string | Namespace |
| `"M"` | string | Mouse Move |
| `"D"` | string | Mouse Drag |
| `"B"` | string | Mouse Button |
| `event_type` | u8 | `1` = press, `2` = repeat, `3` = release |
| `button` | u8 | `1` = links, `2` = mitte, `3` = rechts, `4` = wheel up, `5` = wheel down |
| `cell.x/y` | i32 | Cell-Position |
| `offset.x/y` | i32 | Sub-Cell Pixel-Offset |

**Verarbeitung in TUI:** `renderer/vaxis/renderer.zig:310` → `.mouse` → `dispatch_mouse()` oder `dispatch_mouse_drag()`

---

### 1.5 Mouse Wheel

Wird als Button-Events gesendet (siehe 1.4.2):
- Wheel Up → Button 4
- Wheel Down → Button 5

---

### 1.6 FontFace Liste

Wird gesendet wenn TUI verfügbare Fonts abfragt.

```zig
// Aktueller Font:
state.pid.send(.{
    "fontface",
    "current",
    font_name_utf8,  // []const u8
})

// Verfügbare Fonts (einer pro Message):
state.pid.send(.{
    "fontface",
    font_name_utf8,
})

// Ende der Liste:
state.pid.send(.{ "fontface", "done" })
```

**Verarbeitung in TUI:** `tui.zig:587-599`

**Für Vulkan-Ed:** System-Fonts auflisten (Fontconfig auf Linux, DirectWrite auf Windows).

---

### 1.7 Quit

```zig
state.pid.send(.{ "cmd", "quit" })
```

---

## 2. TUI → GUI Messages (App schickt an Renderer)

**Format:** Windows SendMessage (synchron) oder Thespian Message
**Quelle:** TUI-Thread → GUI-Thread
**Empfänger:** `win32/gui.zig:WndProc()`

### 2.1 updateScreen (DIE WICHTIGSTE!)

Wird gesendet wenn der Screen-Inhalt sich geändert hat (jeder Frame!).

```zig
// Windows:
WM_APP_UPDATE_SCREEN = win32.WM_APP + 9
win32.SendMessageW(hwnd, WM_APP_UPDATE_SCREEN, @intFromPtr(screen), 0)
```

| Parameter | Typ | Bedeutung |
|---|---|---|
| `wparam` | `*const vaxis.Screen` | Pointer zum Screen-Buffer |
| `lparam` | `0` | – |

**`vaxis.Screen` Struktur:**

```zig
pub const Screen = struct {
    width: u16,           // Anzahl Cells horizontal
    height: u16,          // Anzahl Cells vertikal
    width_pix: u16,       // Pixel-Breite des Client-Bereichs
    height_pix: u16,      // Pixel-Höhe des Client-Bereichs
    buf: []Cell,          // width * height Einträge (flaches Array)
    cursor: Cursor,       // Cursor-Position (row, col)
    cursor_vis: bool,     // Cursor sichtbar?
    cursor_shape: CursorShape,  // Block, Underline, Beam
    mouse_shape: MouseShape,    // Maus-Cursor-Form (Pointer, Text, Default)
    width_method: WidthMethod,  // Wie Cell-Breite berechnet wird
};
```

**`vaxis.Cell` Struktur:**

```zig
pub const Cell = struct {
    char: GraphemeChar,  // Unicode-Zeichen
    style: Style,        // Farben + Attribute
};

pub const GraphemeChar = struct {
    grapheme: []const u8,  // UTF-8 encodiert (1-4 Bytes)
    width: u8,             // 1 = normal, 2 = double-wide (CJK)
};

pub const Style = struct {
    fg: Color,    // Vordergrund-Farbe
    bg: Color,    // Hintergrund-Farbe
    // Attribute sind in Style-Bits codiert
    // bold, italic, underline, strikethrough, etc.
};

pub const Color = union(enum) {
    default,              // Standard-Farbe
    index: u8,            // xterm 256-Farb-Palette (0-255)
    rgb: [3]u8,           // Echte RGB-Farbe (0-255 pro Kanal)
};
```

**Für Vulkan-Ed:**
- Screen-Buffer kopieren (Arena-Allocator wie in `win32/gui.zig:1296-1322`)
- Pro Cell: Glyph laden (wenn nicht im Cache), Quad zeichnen mit FG/BG-Farbe
- Cursor an `cursor.row/cursor.col` rendern

---

### 2.2 Set Background

```zig
WM_APP_SET_BACKGROUND = win32.WM_APP + 2
win32.SendMessageW(hwnd, WM_APP_SET_BACKGROUND, color, 0)
```

| Parameter | Typ | Bedeutung |
|---|---|---|
| `color` | u32 | Hintergrund-Farbe (ARGB) |

---

### 2.3 Font-Size ändern

```zig
// Size anpassen (delta):
WM_APP_ADJUST_FONTSIZE = win32.WM_APP + 3
win32.SendMessageW(hwnd, WM_APP_ADJUST_FONTSIZE, @as(u32, @bitCast(delta: f32)), 0)

// Size setzen (absolut):
WM_APP_SET_FONTSIZE = win32.WM_APP + 4
win32.SendMessageW(hwnd, WM_APP_SET_FONTSIZE, @as(u32, @bitCast(size: f32)), 0)

// Zurücksetzen:
WM_APP_RESET_FONTSIZE = win32.WM_APP + 6
win32.SendMessageW(hwnd, WM_APP_RESET_FONTSIZE, 0, 0)
```

**Für Vulkan-Ed:** Font-Atlas neu bauen mit neuer Size.

---

### 2.4 Font-Face ändern

```zig
// Font-Face setzen:
WM_APP_SET_FONTFACE = win32.WM_APP + 5
win32.SendMessageW(hwnd, WM_APP_SET_FONTFACE, @intFromPtr(&FontFace), 0)

// Zurücksetzen:
WM_APP_RESET_FONTFACE = win32.WM_APP + 7
win32.SendMessageW(hwnd, WM_APP_RESET_FONTFACE, 0, 0)

// Verfügbare Fonts abfragen:
WM_APP_GET_FONTFACES = win32.WM_APP + 8
win32.SendMessageW(hwnd, WM_APP_GET_FONTFACES, 0, 0)
```

**`FontFace` Struktur:**

```zig
pub const FontFace = struct {
    buf: [FontFace.max * 2]u16,  // UTF-16 encodiert (Windows)
    len: usize,                   // Länge
    
    pub fn slice(self: *const FontFace) []const u16 { ... }
    pub fn initUtf8(utf8: []const u8) !FontFace { ... }  // UTF-8 → UTF-16
};
```

**Für Vulkan-Ed:** Font-Name als UTF-8 speichern, System-Font laden.

---

### 2.5 Exit

```zig
WM_APP_EXIT = win32.WM_APP + 1
win32.SendMessageW(hwnd, WM_APP_EXIT, 0, 0)
```

---

## 3. Key-Codes

### input.key (u21)

Die wichtigsten Key-Codes aus Flow's `input`-Modul:

| Key-Code | Bedeutung |
|---|---|
| `'a'...` | Buchstaben (lowercase) |
| `'0'...` | Zahlen |
| `input.key.enter` | Enter |
| `input.key.escape` | Escape |
| `input.key.backspace` | Backspace |
| `input.key.tab` | Tab |
| `input.key.space` | Space |
| `input.key.left` | Pfeil links |
| `input.key.right` | Pfeil rechts |
| `input.key.up` | Pfeil hoch |
| `input.key.down` | Pfeil runter |
| `input.key.home` | Home |
| `input.key.end` | End |
| `input.key.page_up` | Page Up |
| `input.key.page_down` | Page Down |
| `input.key.insert` | Insert |
| `input.key.delete` | Delete |
| `input.key.f1...f12` | Function-Keys |
| `input.key.left_control` | Ctrl links |
| `input.key.right_control` | Ctrl rechts |
| `input.key.left_alt` | Alt links |
| `input.key.right_alt` | Alt rechts (AltGr) |
| `input.key.left_shift` | Shift links |
| `input.key.right_shift` | Shift rechts |
| `input.key.left_super` | Super/Win links |
| `input.key.right_super` | Super/Win rechts |

**Für Vulkan-Ed:** wio's Key-Codes → Flow's Key-Codes mappen.

---

## 4. Modifier-Bits (u8)

```zig
pub const mod = struct {
    pub const shift: u8     = 0x01;
    pub const alt: u8       = 0x02;
    pub const ctrl: u8      = 0x04;
    pub const super: u8     = 0x08;
    pub const hyper: u8     = 0x10;
    pub const meta: u8      = 0x20;
    pub const caps_lock: u8 = 0x40;
    pub const num_lock: u8  = 0x80;
};
```

**Beispiel:** Ctrl+A = `mod.ctrl` = `0x04`

---

## 5. Mouse-Button-IDs

| Button | ID | Bedeutung |
|---|---|---|
| `BUTTON1` | 1 | Linke Maustaste |
| `BUTTON2` | 2 | Mittlere Maustaste |
| `BUTTON3` | 3 | Rechte Maustaste |
| `BUTTON4` | 4 | Mausrad hoch |
| `BUTTON5` | 5 | Mausrad runter |

---

## 6. Render-Loop (Frame-Ablauf)

```
1. GUI-Thread startet (win32/gui.zig:entry)
   ↓
2. Window erstellen → send("RDR", "WindowCreated", hwnd)
   ↓
3. sendResize() → send("RDR", "Resize", cells_x, cells_y, px_x, px_y)
   ↓
4. TUI verarbeitet Resize → berechnet vaxis.Screen
   ↓
5. TUI schickt WM_APP_UPDATE_SCREEN(hwnd, *vaxis.Screen)
   ↓
6. GUI-Thread kopiert Screen-Buffer (WM_APP_UPDATE_SCREEN handler)
   ↓
7. InvalidateRect(hwnd) → WM_PAINT auslösen
   ↓
8. WM_PAINT: Iteriere screen.buf → render.Cells erzeugen → render.paint()
   ↓
9. Input-Events (Keyboard/Mouse) → send("RDR", "I"/"M"/"B", ...)
   ↓
10. TUI verarbeitet Input → aktualisiert Screen → zurück zu Schritt 5
```

---

## 7. Für Vulkan-Ed zu implementieren

### 7.1 Window-Management (wio)
- [ ] Fenster erstellen
- [ ] Resize-Handling → `sendResize()` an TUI
- [ ] Window-Handle speichern für `updateScreen()`

### 7.2 Input-Handling
- [ ] wio Keyboard → Flow Key-Codes mappen
- [ ] wio Mouse → Flow Mouse-Events mappen
- [ ] Modifier berechnen (Ctrl, Alt, Shift, Super)

### 7.3 Renderer (wgpu)
- [ ] `updateScreen(*vaxis.Screen)` → Screen-Buffer kopieren
- [ ] Font-Atlas laden (JetBrains Mono)
- [ ] Cell-Rendering: Pro Zelle → Quad + Glyph + FG/BG-Farbe
- [ ] Cursor rendern (Beam/Block/Underline)
- [ ] Mouse-Cursor aktualisieren (`mouse_shape`)

### 7.4 Thespian-Integration
- [ ] Flow's TUI als Actor starten
- [ ] GUI-Actor als Renderer registrieren
- [ ] Message-Loop implementieren

---

## Quellen

- `libs/flow/src/win32/gui.zig` – Windows GUI Implementierung
- `libs/flow/src/renderer/vaxis/renderer.zig` – Renderer-Interface
- `libs/flow/src/renderer/win32/renderer.zig` – D3D11 Renderer (Referenz)
- `libs/flow/src/tui/tui.zig` – TUI-App (Message-Verarbeitung)
- `libs/flow/src/renderer/vaxis/input.zig` – Key-Codes + Modifier
