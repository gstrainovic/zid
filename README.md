# zid

Editor mit Vulkan/WGPU-Rendering, wio-Platform-Layer und Clay-UI. Unterstützt
Code-Editing, eingebettete Terminals (ghostty-vt + PTY/ConPTY), Bild- und
PDF-Anzeige (mupdf).

## Installation (Linux)

Fertiges Binary, kein Zig, kein Compiler. Läuft unter Wayland und X11.

### Alle Distributionen: Tarball

```bash
curl -LO https://github.com/gstrainovic/zid/releases/latest/download/zid-0.1.6-x86_64-linux.tar.xz
tar xf zid-0.1.6-x86_64-linux.tar.xz
cd zid-0.1.6-x86_64-linux
./install.sh            # nach ~/.local, ohne root
```

Danach startet `zid` aus dem Terminal, und der Eintrag steht im Anwendungsmenü.
Liegt `~/.local/bin` nicht im PATH, sagt `install.sh` es und nennt die Zeile für
die `~/.bashrc`. Systemweit: `sudo ./install.sh /usr/local`. Wieder weg:
`./install.sh --uninstall` (bzw. mit demselben Präfix).

### Fedora

```bash
sudo dnf copr enable gstrainovic/zid
sudo dnf install zid
```

Updates kommen mit `dnf upgrade`.

### Debian, Ubuntu, Mint

Einmal die apt-Quelle einrichten:

```bash
curl -fsSL https://gstrainovic.github.io/apt-zid/zid.gpg | sudo tee /usr/share/keyrings/zid.gpg >/dev/null
echo "deb [signed-by=/usr/share/keyrings/zid.gpg] https://gstrainovic.github.io/apt-zid stable main" \
  | sudo tee /etc/apt/sources.list.d/zid.list
sudo apt update && sudo apt install zid
```

Updates kommen danach mit `apt upgrade`. Braucht Debian 12 oder Ubuntu 22.04 und neuer.
Ohne Quelle geht auch das einzelne Paket:
`curl -LO https://github.com/gstrainovic/zid/releases/latest/download/zid_0.1.6-1_amd64.deb && sudo apt install ./zid_0.1.6-1_amd64.deb`.

### Arch Linux, Manjaro, EndeavourOS

Einmal die pacman-Quelle einrichten:

```bash
curl -fsSL https://gstrainovic.github.io/pacman-zid/zid.asc | sudo pacman-key --add -
sudo pacman-key --lsign-key E5E96FA53EB5B2226D438FB39C64B2A2A6DFA473
printf '\n[zid]\nServer = https://gstrainovic.github.io/pacman-zid/$arch\n' | sudo tee -a /etc/pacman.conf
sudo pacman -Syu zid
```

Updates kommen danach mit `pacman -Syu`.

### openSUSE und andere RPM-Distributionen

```bash
sudo zypper install https://github.com/gstrainovic/zid/releases/latest/download/zid-0.1.6-1.x86_64.rpm
```

### Snap

```bash
sudo snap install zid --classic
```

`--classic` wie bei VS Code: Terminal, git und die Suche laufen auf dem System, nicht in
einer Sandbox. Updates holt snapd selbst.

## Installation (Windows)

Am Release hängt `zid-0.1.6-x86_64-windows.zip` (gebaut von GitHub Actions).
Entpacken, `zid.exe` starten — Schrift und Shader stecken im Binary, `rg.exe`
(ripgrep, für die Suche im Projekt) liegt daneben.

Mit Scoop:

```powershell
scoop bucket add zid https://github.com/gstrainovic/scoop-zid
scoop install zid/zid
```

Das Manifest liegt im Bucket [gstrainovic/scoop-zid](https://github.com/gstrainovic/scoop-zid)
und folgt neuen Releases selbst (Excavator, alle 4 Stunden).

### Voraussetzungen

Eine GPU mit Vulkan-Treiber und die üblichen Desktop-Bibliotheken (freetype,
harfbuzz, libpng, zlib, glib) — auf einer Desktop-Installation ist beides da.
Fehlt der Vulkan-Treiber, meldet zid das beim Start; unter Fedora liefert ihn
`mesa-vulkan-drivers`, unter Debian und Ubuntu `mesa-vulkan-drivers`, bei NVIDIA
der proprietäre Treiber.

Das Binary verlangt `GLIBC_2.35` oder neuer. Das deckt Ubuntu 22.04 LTS,
Debian 12, Fedora 37 und alles Jüngere ab.

Für die KI lädt zid beim ersten Gebrauch selbst, was es braucht: der Chat zeigt
einen Knopf, der llama-server (30 MB) und das Modell gemma-4-E2B (2,7 GB) ins
Benutzerverzeichnis holt. Ohne das läuft der Editor normal, nur der Chat bleibt leer.

## Build

Nur nötig, wenn du am Editor selbst arbeitest oder ihn portieren willst; zum
Benutzen reicht die Installation oben.

```bash
bash scripts/sync.sh   # Submodule + Referenzen aktualisieren
zig build run          # Debug-Build starten
```

### Linux — System-Pakete

Standardmäßig linkt das PDF-Rendering gegen System-`libmupdf` (`-Dmupdf=system`).
Der bundled Header darf dabei nicht mit hinein: `fz_new_context()` prüft
`FZ_VERSION` gegen die installierte `.so`.

Für Pakete und Releases stattdessen `-Dmupdf=bundled` nehmen (siehe unten):
das SONAME von `libmupdf` unterscheidet sich je Distribution, statisch gelinkt
läuft dasselbe Binary überall.

Fedora/RHEL:

```bash
sudo dnf install mupdf mupdf-devel \
                 wayland-devel libxkbcommon-devel libdecor-devel \
                 libX11-devel libXcursor-devel \
                 mesa-libEGL-devel vulkan-loader-devel \
                 freetype-devel harfbuzz-devel libpng-devel
```

Debian/Ubuntu (Paketnamen können leicht abweichen):

```bash
sudo apt install libmupdf-dev \
                 libwayland-dev libxkbcommon-dev libdecor-0-dev \
                 libx11-dev libxcursor-dev \
                 libegl1-mesa-dev libvulkan-dev \
                 libfreetype-dev libharfbuzz-dev libpng-dev
```

### Linux — MuPDF statisch (für Pakete und Releases)

`-Dmupdf=bundled` linkt die vendorte MuPDF 1.26.5 aus dem Submodul statisch. Die
Archive baut man einmalig; FreeType, HarfBuzz und zlib kommen weiter vom System
(ABI-stabil), libjpeg dagegen nicht — ihr SONAME wechselt je Distribution
(`.62` auf Debian und Fedora, `.8` auf Ubuntu und Arch). Tesseract, Leptonica,
ZXing und libcurl fallen ganz weg:

```bash
cd libs/fancy-cat/deps/mupdf
make -j$(nproc) libs HAVE_X11=no HAVE_GLUT=no HAVE_OBJCOPY=no tools=no apps=no \
     USE_SYSTEM_FREETYPE=yes USE_SYSTEM_HARFBUZZ=yes USE_SYSTEM_ZLIB=yes \
     USE_SYSTEM_LIBJPEG=no HAVE_LEPTONICA=no HAVE_TESSERACT=no HAVE_ZXINGCPP=no \
     XCFLAGS="-w -fPIC"
cd -
zig build -Dmupdf=bundled
```

Danach hängt das Binary nur noch an Bibliotheken, die auf jedem Desktop liegen
(libc, libm, libz, libjpeg, freetype, harfbuzz, png, Wayland/X11, EGL). Prüfen
mit `ldd zig-out/bin/zid`.

### Release-Tarball bauen (Linux)

```bash
packaging/build-release.sh          # podman, sonst docker
packaging/build-release.sh --engine docker
```

Baut in einem Debian-12-Container und legt `dist/zid-<version>-x86_64-linux.tar.xz`
ab. Der Container ist kein Selbstzweck: gegen die glibc der Entwicklungsmaschine
gelinkt verlangt zid `GLIBC_2.38` und startet auf älteren Distributionen nicht.
Debian 12 hat 2.36 und deckt damit Ubuntu 22.04 LTS mit ab. Auf altem System
gebaut läuft auf neuem, umgekehrt nicht.

Der Container baut MuPDF in ein eigenes `build/release-deb12` und nutzt einen
eigenen Zig-Cache, die Artefakte der Entwicklungsmaschine bleiben also liegen.

Im Tarball steckt ein `install.sh`:

```bash
tar xf zid-0.1.6-x86_64-linux.tar.xz
cd zid-0.1.6-x86_64-linux
./install.sh                 # nach ~/.local
./install.sh /usr/local      # systemweit (als root)
./install.sh --uninstall     # wieder entfernen
```

### Release veröffentlichen

Ein Befehl, von `main` mit sauberem Arbeitsbaum:

```bash
packaging/release.sh 0.1.2 "Search and replace across the project (Ctrl+Shift+F)."
```

Das Skript setzt die Version in `build.zig.zon`, AppStream, RPM-Spec und README,
committet, taggt `v0.1.6` und pusht. Der Text geht englisch
in AppStream und Release-Notiz; mehrere Punkte mit ` | ` trennen. `--dry-run`
ändert nur die Dateien.

Den Rest erledigt `.github/workflows/release.yml`:

* Linux-Tarball (`packaging/build-release.sh`, Debian-12-Container) und Windows-Zip
  (`windows-release.yml`) bauen, beide mit ripgrep. Aus dem Tarball ohne neuen Bau:
  `.deb` und `.rpm` (`packaging/nfpm.yaml`) und der Snap (`snap/snapcraft.yaml`).
* Release als Entwurf anlegen, alles anhängen, dann veröffentlichen.
* **Fedora:** SRPM bauen und an COPR `gstrainovic/zid` schicken. Braucht das Secret
  `COPR_CONFIG` (Inhalt von `~/.config/copr`, Token von
  <https://copr.fedorainfracloud.org/api/>, läuft nach 180 Tagen ab).
* **Debian/Ubuntu:** `apt.yml` legt das `.deb` in die apt-Quelle `gstrainovic/apt-zid`
  (GitHub Pages, behält die letzten drei Versionen) und installiert es danach zur Probe in
  Debian 12, Ubuntu 22.04 und 24.04. Braucht die Secrets `APT_SIGNING_KEY` (geheimer
  GPG-Schlüssel, Fingerabdruck `E5E9 6FA5 3EB5 B222 6D43 8FB3 9C64 B2A2 A6DF A473`) und
  `APT_DEPLOY_KEY` (Deploy-Key mit Schreibrecht auf apt-zid). Nachholen für eine Version:
  `gh workflow run apt.yml -f version=0.1.3`.
* **Arch:** `pacman.yml` legt das `.pkg.tar.zst` in die pacman-Quelle
  `gstrainovic/pacman-zid` (GitHub Pages, letzte drei Versionen), signiert Pakete und
  Datenbank mit demselben Schlüssel wie apt und installiert es danach zur Probe in
  `archlinux:latest`. Braucht `APT_SIGNING_KEY` und `PACMAN_DEPLOY_KEY`. Nachholen:
  `gh workflow run pacman.yml -f version=0.1.4`.
* **Snap Store:** Upload in den Kanal `stable`. Braucht das Secret
  `SNAPCRAFT_STORE_CREDENTIALS` (`snapcraft export-login -`) und einmalig die Freigabe
  für Classic-Confinement.
* **Scoop:** nichts zu tun, der Excavator im Bucket zieht innerhalb von 4 Stunden nach
  (sofort: `gh workflow run excavator.yml -R gstrainovic/scoop-zid`).

Fehlt ein Secret, überspringt der Job mit einer Warnung, der Rest läuft; nur `apt`
schlägt dann fehl, weil sonst eine eingerichtete Quelle still veraltet.
Fortschritt: `gh run watch`.

Warum Binärpakete statt Bauen aus den Quellen: zid verlangt exakt Zig 0.15.2,
die vendorte MuPDF aus einem Submodul und Netzzugang während des Builds. Das
passt nicht zu mock in COPR.

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

## Lizenz

AGPL-3.0-only, siehe `LICENSE`. zid linkt MuPDF (AGPL-3.0), daher ist eine
AGPL-kompatible Lizenz für zid verpflichtend.
