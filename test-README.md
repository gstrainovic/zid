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

Der Editor benötigt ein GGUF-Modell. Standard ist **Qwen3-4B-Instruct-2507**
(`models/Qwen3-4B-Instruct-2507-Q4_K_M.gguf`, siehe `src/ai/paths.zig`); die
Begründung steht in `.claude/skills/llm-local/SKILL.md`. Abweichende Pfade über
Umgebungsvariablen:

```bash
export LLAMA_SERVER_PATH=/pfad/zu/llama-server
export LLAMA_MODEL_PATH=/pfad/zu/Qwen3-4B-Instruct-2507-Q4_K_M.gguf
# Optional: NVIDIA GPU erzwingen (Index 1)
export GGML_VULKAN_DEVICE=1
```

### Windows

MuPDF wird statisch aus `libs/fancy-cat/deps/mupdf` gebaut (bundled Header +
bundled URW-Fonts). `scripts/sync.sh` klont das Submodul mit Tag `1.26.5`, da
der von fancy-cat gepinnte Commit upstream nicht mehr erreichbar ist.

### Windows

MuPDF wird statisch aus `libs/fancy-cat/deps/mupdf` gebaut (bundled Header +
bundled URW-Fonts). `scripts/sync.sh` klont das Submodul mit Tag `1.26.5`, da
der von fancy-cat gepinnte Commit upstream nicht mehr erreichbar ist.

### Windows

MuPDF wird statisch aus `libs/fancy-cat/deps/mupdf` gebaut (bundled Header +
bundled URW-Fonts). `scripts/sync.sh` klont das Submodul mit Tag `1.26.5`, da
der von fancy-cat gepinnte Commit upstream nicht mehr erreichbar ist.