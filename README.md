# zid

Editor mit Vulkan/WGPU-Rendering, wio-Platform-Layer und Clay-UI. Unterstützt
Code-Editing, eingebettete Terminals (ghostty-vt + PTY/ConPTY), Bild- und
PDF-Anzeige (mupdf).

## Build

```bash
bash scripts/sync.sh   # Submodule + Referenzen aktualisieren
zig build run          # Debug-Build starten
```

### Linux — System-Pakete

PDF-Rendering linkt gegen System-`libmupdf`, weil Fedora einen ABI-Versions-
Check in `fz_new_context()` erzwingt und ein gebundelter Header unweigerlich
mit der installierten `.so` auseinanderläuft.

Fedora/RHEL:

```bash
sudo dnf install mupdf mupdf-devel \
                 wayland-devel libxkbcommon-devel libdecor-devel \
                 mesa-libEGL-devel vulkan-loader-devel \
                 freetype-devel harfbuzz-devel libpng-devel
```

Debian/Ubuntu (Paketnamen können leicht abweichen):

```bash
sudo apt install libmupdf-dev \
                 libwayland-dev libxkbcommon-dev libdecor-0-dev \
                 libegl1-mesa-dev libvulkan-dev \
                 libfreetype-dev libharfbuzz-dev libpng-dev
```

### KI & Automatisierung (Abhängigkeiten)

*   **Zig 0.15.x:** Erforderlich für den Build des Editors.
*   **Vulkan SDK / Headers:** Für GPU-beschleunigtes Rendering und KI-Inferenz.
*   **llama.cpp (llama-server):** Erforderlich für den KI-Agenten. Muss mit Vulkan-Support kompiliert sein.
*   **Python 3:** Für RPC-Skripte und Automatisierung.

### KI-Setup

Der Editor benötigt ein GGUF-Modell. Standard ist **gemma-4-E2B-it Q4_0** von ggml-org
(`models/gemma-4-E2B-it-Q4_0.gguf`, siehe `src/ai/paths.zig`); die
Begründung steht in `.claude/skills/llm-local/SKILL.md`. Abweichende Pfade über
Umgebungsvariablen:

```bash
export LLAMA_SERVER_PATH=/pfad/zu/llama-server
export LLAMA_MODEL_PATH=/pfad/zu/anderes-modell.gguf
# Optional: NVIDIA GPU erzwingen (Index 1)
export GGML_VULKAN_DEVICE=1
```

### Windows

MuPDF wird statisch aus `libs/fancy-cat/deps/mupdf` gebaut (bundled Header +
bundled URW-Fonts). `scripts/sync.sh` klont das Submodul mit Tag `1.26.5`, da
der von fancy-cat gepinnte Commit upstream nicht mehr erreichbar ist.

`zig build` erwartet `libmupdf.a` und `libmupdf-third.a` unter
`libs/fancy-cat/deps/mupdf/build/release`; die baut man einmalig mit dem
mupdf-Makefile in Git Bash. Compiler ist `zig cc`, damit CRT-Header und
Import-Bibliotheken zum Zig-Ziel `x86_64-windows-gnu` passen — mit
winlibs-gcc gebaut fehlt beim Linken `__imp__setjmp`. `-msse4.1` braucht
`deskew_sse.h`, `TOFU`/`TOFU_CJK` lassen nur die URW-Fonts drin (die HTML- und
Story-Engine für den Marp-Export bleibt an):

```bash
cd libs/fancy-cat/deps/mupdf
make -j16 libs CC="zig cc" AR="zig ar" HAVE_X11=no HAVE_GLUT=no HAVE_OBJCOPY=no \
     tools=no apps=no XCFLAGS="-w -msse4.1 -DTOFU -DTOFU_CJK"
```

**Zig-Version:** Der Build braucht 0.15.x. Zig 0.16 kennt `Compile.linkLibC`
nicht mehr und bricht in `tree_sitter`/`flow_syntax` ab. Liegt unter scoop
mehr als eine Version, `current` prüfen (`scoop reset zig@0.15.2`) oder die
Binary direkt aufrufen: `~\scoop\apps\zig\0.15.2\zig.exe build run`.

**Symlinks ohne Admin/Entwicklermodus:** Der tree-sitter-Tarball enthält
Symlinks; `zig build` bricht dann mit `unable to create symlink ...
PermissionDenied` ab. Abhilfe: Paket einmalig symlink-frei entpacken, Zig
vertraut dem vorhandenen Cache-Ordner danach ohne Nachfrage.

```powershell
python scripts/fix_zig_cache.py add <ordnername-aus-dem-fehler> <tarball-url>
```

Ordnername ist der `.hash`-Wert aus der fehlgeschlagenen `build.zig.zon`
(z. B. `tree_sitter-0.26.7-z0Lhy...`), die URL steht direkt daneben. Bei
Zig 0.15 landet das Paket unter `%LOCALAPPDATA%\zig\p`, bei 0.16 im
projektlokalen `zig-pkg/`.
