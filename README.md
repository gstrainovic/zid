# zid

Editor mit Vulkan/WGPU-Rendering, wio-Platform-Layer und Clay-UI. Unterstützt
Code-Editing, eingebettete Terminals (ghostty-vt + PTY/ConPTY), Bild- und
PDF-Anzeige (mupdf).

## Installation (Linux)

Fertiges Binary, kein Zig, kein Compiler. Läuft unter Wayland und X11.

### Alle Distributionen: Tarball

```bash
curl -LO https://github.com/gstrainovic/zid/releases/latest/download/zid-0.1.1-x86_64-linux.tar.xz
tar xf zid-0.1.1-x86_64-linux.tar.xz
cd zid-0.1.1-x86_64-linux
./install.sh            # nach ~/.local, ohne root
```

Danach startet `zid` aus dem Terminal, und der Eintrag steht im Anwendungsmenü.
Liegt `~/.local/bin` nicht im PATH, sagt `install.sh` es und nennt die Zeile für
die `~/.bashrc`. Systemweit: `sudo ./install.sh /usr/local`. Wieder weg:
`./install.sh --uninstall` (bzw. mit demselben Präfix).

### Arch, Manjaro, EndeavourOS

```bash
mkdir zid-bin && cd zid-bin
curl -LO https://github.com/gstrainovic/zid/releases/latest/download/PKGBUILD
makepkg -si
```

Das PKGBUILD hängt am Release, ein AUR-Konto braucht es dafür nicht. Sobald das
Paket in der AUR steht, geht auch `paru -S zid-bin`.

### Fedora

```bash
sudo dnf copr enable gstrainovic/zid
sudo dnf install zid
```

## Installation (Windows)

Am Release hängt `zid-0.1.1-x86_64-windows.zip` (gebaut von GitHub Actions).
Entpacken, `zid.exe` starten — daneben braucht es nichts, Schrift und Shader
stecken im Binary.

Emoji bleiben unter Windows leere Kästchen: dort läuft der Text über DirectWrite,
und die Rückfall-Kette auf eine Emoji-Schrift gibt es bisher nur unter Linux.

Mit Scoop:

```powershell
scoop bucket add zid https://github.com/gstrainovic/scoop-zid
scoop install zid/zid
```

Das Manifest wird in diesem Repo gepflegt (`packaging/scoop/zid.json`) und bei
jedem Release nach `bucket/zid.json` im Repo
[gstrainovic/scoop-zid](https://github.com/gstrainovic/scoop-zid) kopiert.
Für WinGet liegen Manifeste unter `packaging/winget/`, eingereicht sind sie
nicht (Pull Request nach `microsoft/winget-pkgs`). Lokal prüfen:

```powershell
scoop install packaging\scoop\zid.json
winget validate --manifest packaging\winget
```

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
tar xf zid-0.1.1-x86_64-linux.tar.xz
cd zid-0.1.1-x86_64-linux
./install.sh                 # nach ~/.local
./install.sh /usr/local      # systemweit (als root)
./install.sh --uninstall     # wieder entfernen
```

### Release veröffentlichen

```bash
packaging/build-release.sh                       # dist/…tar.xz + .sha256
git tag -a v0.1.1 -m "zid 0.1.1" && git push origin v0.1.1
gh release create v0.1.1 dist/zid-0.1.1-x86_64-linux.tar.xz* \
    --title "zid 0.1.1" --notes "…"
```

Danach die beiden Distributionspakete auf die neue Version ziehen — beide
installieren das Release-Tarball, bauen also nichts nach:

* `packaging/aur/PKGBUILD` — `pkgver` und `sha256sums` (Wert aus der
  `.sha256`-Datei) anpassen, `.SRCINFO` neu erzeugen, beides ins AUR-Repository
  `zid-bin` pushen:

  ```bash
  git clone ssh://aur@aur.archlinux.org/zid-bin.git
  cp packaging/aur/PKGBUILD packaging/aur/.SRCINFO zid-bin/
  cd zid-bin && git commit -am "zid-bin 0.1.1" && git push
  ```

  `.SRCINFO` erzeugt `makepkg --printsrcinfo > .SRCINFO`; ohne Arch-Rechner:
  `podman run --rm -v "$PWD/packaging/aur:/b" archlinux bash -c 'pacman -Sy --noconfirm pacman-contrib && useradd -m b && chown -R b /b && su b -c "cd /b && makepkg --printsrcinfo > .SRCINFO"'`
* `packaging/rpm/zid.spec` — `Version` und `%changelog` anpassen, dann SRPM bauen
  und ins COPR-Projekt `gstrainovic/zid` schicken. `copr-cli build` nimmt ein SRPM
  oder eine URL, keine Spec-Datei:

  ```bash
  rpmbuild -bs --define "_topdir $PWD/tmp/rpm" --define "_sourcedir $PWD/dist" \
      packaging/rpm/zid.spec
  copr-cli build zid tmp/rpm/SRPMS/zid-<version>-1.fc*.src.rpm
  ```

  Das Tarball muss dafür in `dist/` liegen (Source0 wird von dort genommen, nicht
  geladen). Zugangsdaten holt `copr-cli` aus `~/.config/copr`, zu erzeugen unter
  <https://copr.fedorainfracloud.org/api/>.

Warum Binärpakete statt Bauen aus den Quellen: zid verlangt exakt Zig 0.15.2,
die vendorte MuPDF aus einem Submodul und Netzzugang während des Builds. Das
passt weder zu einem AUR-Build auf fremden Rechnern noch zu mock in COPR.

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
