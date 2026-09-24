---
name: packaging
description: >
  Build und Auslieferung von zid: eingebettete Daten und Installation, MuPDF system/bundled, Windows-Build in CI, Release-Tarball im Debian-Container, Binärgröße und glibc. Use when touching build.zig, build.zig.zon, packaging/, .github/workflows/, MuPDF linking, release builds, or adding runtime data files.
---

Aus AGENTS.md hierher verschoben (21.09.2026), Wortlaut unverändert.

## Eingebettete Daten und Installation

- Schrift (`fonts/font_data.zig`), Logo (`assets/asset_data.zig`) und die WGSL-Shader
  (`shaders/shader_data.zig`) liegen im Binary. `build.zig` reicht sie als anonyme Module
  `builtin_font`, `builtin_assets` und `builtin_shaders` herein. Vorher las zid `fonts/…`,
  `assets/…` und `zig-out/share/*.wgsl` relativ zum Arbeitsverzeichnis und brach ausserhalb
  des Repos mit `FileNotFound` ab.
- Neue Laufzeitdaten deshalb einbetten, nicht über einen relativen Pfad lesen.
  `python3 scripts/e2e_installed_run.py` startet das Binary in einem leeren Ordner und
  prüft Glyphen, Screenshot und ein Log ohne `FileNotFound`.
- Schriftladen: `TextRenderer` nimmt `font_data` (Voreinstellung: eingebaute Schrift) und
  fällt nur auf `font_path` zurück, wenn das Backend keine Schrift aus dem Speicher kann
  (DirectWrite unter Windows).
- `zig build install --prefix <dir>` legt zusätzlich Starter, Icon und AppStream-Datei unter
  `share/` ab (`packaging/io.github.gstrainovic.zid.*`). Die App-ID ist
  `io.github.gstrainovic.zid`. Prüfen mit `desktop-file-validate` und `appstreamcli validate`.
- Die Version steht in `build.zig.zon` und kommt über die Build-Option `build_info.version`
  ins Binary (`zid --version`); AppStream-`<release>` von Hand nachziehen.

## MuPDF: system oder bundled

- `-Dmupdf=system` (Vorgabe) linkt System-`libmupdf`; der bundled Header darf dann nicht in
  den Include-Pfad, weil `fz_new_context()` `FZ_VERSION` gegen die `.so` prüft.
- `-Dmupdf=bundled` nimmt Header und `.a` aus `libs/fancy-cat/deps/mupdf` — für Pakete und
  Releases, weil das SONAME von libmupdf je Distribution anders ist. Die Archive gibt
  build.zig direkt als Objektdateien an: über `linkSystemLibrary` liefe es in Fedoras defekte
  `mupdf.pc` und der Linker suchte ein Verzeichnis `-lmupdf`.
- Die MuPDF-Font-Ressourcen kompiliert build.zig nur unter Windows mit: dort baut das
  Makefile mit `TOFU` und lässt sie aus dem Archiv. Die Linux-Archive (Bauanleitung im README)
  haben sie drin; ein zweites Mal übersetzt gibt `duplicate symbol: _binary_Dingbats_cff`,
  und zwar erst beim ReleaseSafe-Link, nicht im Debug-Build.
- E2E mit bundled MuPDF: `ZID_BUILD_ARGS=-Dmupdf=bundled python3 scripts/e2e_pdf_pager.py`.
  `ZID_BUILD_ARGS` reicht Build-Optionen an den `zig build`-Aufruf der Suiten durch.

## Windows: Zweige lokal prüfen, bauen in CI

- `zig build -Dtarget=x86_64-windows-gnu` übersetzt hier alle Windows-Zweige und scheitert
  erst beim Linken (MuPDF-Archive fehlen lokal, und Zig findet `OleAut32`/`Ole32` nur auf
  einem Dateisystem ohne Gross-/Kleinschreibung). Das reicht, um Tippfehler in Code zu
  finden, den Linux nie analysiert — so fiel `nativeWindow` auf (HWND ist bei wio optional).
- Gebaut wird in `.github/workflows/windows-release.yml` auf `windows-latest`, weil MuPDFs
  Makefile während des Bauens Hilfsprogramme ausführt.
- Beide Zig-Caches müssen dort im Workspace liegen: das Repo liegt auf `D:`, der globale
  Cache sonst auf `C:`, und über Laufwerksgrenzen bricht ein Run-Schritt von Zig mit
  `reached unreachable code` ab (`assert(!isAbsolute(child_cwd_rel))`).
- `zig build --fetch` läuft dort in drei Anläufen: Zig lädt die Pakete gleichzeitig, und
  einzelne Verbindungen reissen mit `HttpConnectionClosing` ab.
- DirectWrite lädt keine Schrift aus dem Speicher. Die Schrift liegt deshalb neben der exe,
  gesucht wird über `platform/asset_path.zig`.
- Programm-Icon: `packaging/windows/zid.rc` bettet `zid.ico` als Ressource `WIO_ICON` ein
  (`addWin32ResourceFile` in build.zig). wio lädt sie beim Registrieren der Fensterklasse
  (`hIcon`/`hIconSm`); das Exe-Icon allein reicht der Taskleiste nicht, sie nimmt das der
  Fensterklasse. Nach Änderung am SVG `python3
  packaging/windows/make_ico.py` (Inkscape, legt PNGs direkt ins ICO; ImageMagick schrieb
  BMP, 300 KiB statt 14).

## Release-Tarball: `packaging/build-release.sh`

- Baut in einem Debian-12-Container (podman, sonst docker) nach
  `dist/zid-<version>-x86_64-linux.tar.xz`. Grund ist die glibc: auf Fedora 43 gebaut
  verlangt zid `GLIBC_2.38`, aus Debian 12 nur `GLIBC_2.35`, damit läuft es auch auf
  Ubuntu 22.04. Auf altem System gebaut läuft auf neuem, nie umgekehrt.
- `--security-opt label=disable` ist Pflicht: unter SELinux scheitert der Container sonst
  am gemounteten Repo (`make: stat: Makefile: Permission denied`). Ein `:z`-Mount würde
  stattdessen das ganze Repo auf dem Host umlabeln.
- Der Container baut MuPDF nach `build/release-deb12` und **löscht das Verzeichnis vorher**:
  `make` sieht geänderte Flags nicht, ein OUT aus einem Lauf mit `USE_SYSTEM_LIBJPEG=yes`
  behielt sein leeres `jmemcust.o` und der Link scheiterte an `undefined symbol: jpeg_mem_init`.
- libjpeg gehört ins Binary, nicht ans System: Debian und Fedora liefern `libjpeg.so.62`,
  Ubuntu und Arch `libjpeg.so.8`. Mit System-libjpeg gebaut startete das Tarball auf
  Ubuntu 22.04 nicht (`libjpeg.so.62: cannot open shared object file`).
- Im Tarball liegt `packaging/install.sh` (Vorgabe `~/.local`, `--uninstall`, beliebiges
  Präfix als Argument).

## Release-Binary (Linux, `-Dmupdf=bundled -Doptimize=ReleaseSafe`)

- Größe: 212 MB, gestrippt 172 MB. Davon 22 MB MuPDF-Fonts (ohne `TOFU_CJK` gebaut, also
  inklusive CJK); der Rest verteilt sich auf wgpu_native, die tree-sitter-Parser und MuPDF.
- `ldd` zeigt 12 Bibliotheken: libc, libm, libz, freetype, harfbuzz, png, brotli (2x),
  graphite2, glib, pcre2. Wayland, X11, EGL und Vulkan fehlen dort, weil wio und wgpu
  sie per `dlopen` laden — die `linkSystemLibrary`-Einträge in build.zig braucht nur der
  Debug-Build wegen der extern-Deklarationen im Debug-Info.
- Höchste benötigte Symbolversion ist `GLIBC_2.38`. Ein hier gebautes Binary läuft damit auf
  Fedora 39+, Ubuntu 24.04 und Debian 13, aber nicht auf Ubuntu 22.04 (2.35). Wer weiter
  zurück will, baut auf einer älteren Distribution oder gegen musl.

## Veröffentlichen: `packaging/release.sh` + `release.yml`

- `packaging/release.sh <x.y.z> "notes | more notes"` setzt die Version in allen Dateien
  (Python, kein sed: freier Text mit `&`, `<`, `|`), committet, taggt und pusht.
  `--dry-run` ändert nur Dateien; ausprobieren in einer Kopie außerhalb des Repos.
- Der Tag startet `.github/workflows/release.yml`: `linux` (build-release.sh mit docker,
  danach `.deb`/`.rpm` per nfpm aus dem Tarball) und `windows` (ruft `windows-release.yml`
  per `workflow_call`) laufen parallel. `publish` legt
  das Release als Entwurf an, hängt alles an und veröffentlicht erst dann — Scoops
  Excavator sieht so nie ein Release ohne Zip. `copr` folgt nur mit Secret
  (`COPR_CONFIG`), sonst Warnung und weiter; `apt` und `pacman` ziehen ihre Quellen nach.
- `workflow_dispatch` von `release.yml` baut nur (Artefakte `zid-linux`, `zid-windows`),
  ohne zu veröffentlichen — so lässt sich der Bau ohne Tag prüfen.
- **Snap gibt es nicht mehr** (snapcraft.yaml am 23.09.2026 entfernt, die Jobs `snap` und
  `snapstore` am 24.09.2026): der erste Release-Lauf nach dem Entfernen (v0.1.6) scheiterte,
  weil `publish` noch am `snap`-Job hing. Wer einen Paketkanal streicht, muss Workflow,
  README, `.gitignore` und diese Skill im selben Commit mitziehen.
- `.deb`/`.rpm` (`packaging/nfpm.yaml`): rpm-Abhängigkeiten nach SONAME
  (`libfreetype.so.6()(64bit)`), damit dieselbe Datei auf Fedora und openSUSE passt; deb
  mit `libpng16-16 | libpng16-16t64` wegen der time64-Umbenennung ab Ubuntu 24.04.
- COPR baut aus einem SRPM (`rpmbuild -bs`, Source0 aus dem veröffentlichten Release);
  mit der Spec direkt baute COPR 0.1.1 nicht.
- apt (`.github/workflows/apt.yml`, `packaging/apt/publish.sh`): Pages-Repo
  gstrainovic/apt-zid, flache Quelle `stable main`, Index per `apt-ftparchive`, signiert als
  `InRelease` und `Release.gpg`. Das Repo trägt nur einen Commit (Orphan + Force-Push), im
  Pool bleiben drei Versionen — sonst wüchse es je Release um ~40 MB. Den privaten Schlüssel
  gibt es nur als Secret `APT_SIGNING_KEY`; geht er verloren, neuen erzeugen und Nutzer
  müssen `zid.gpg` neu holen. Lokal unter Windows: gpg aus Git-Bash braucht ein kurzes
  `--homedir` (der Agent-Socket-Pfad darf nicht zu lang sein und kein `C:` enthalten).
- pacman (`.github/workflows/pacman.yml`, `packaging/pacman/publish.sh`): statt AUR, dessen
  Registrierung für neue Konten geschlossen ist. nfpm baut `-p archlinux` aus dem Tarball,
  Pages-Repo gstrainovic/pacman-zid mit `x86_64/zid.db` von `repo-add --sign`. pacman
  verlangt signierte Pakete (`SigLevel Required`), daher je Paket eine `.sig`; Schlüssel ist
  `APT_SIGNING_KEY`, gepusht mit `PACMAN_DEPLOY_KEY`. Die Symlinks, die `repo-add` anlegt
  (`zid.db` usw.), ersetzt das Skript durch Kopien, weil Pages Symlinks nicht ausliefert.
  Lokal prüfen: Paket per nfpm bauen, im `archlinux`-Container `publish.sh` mit einem
  Wegwerf-Schlüssel, Ordner per `python -m http.server` ausliefern, wie im README einrichten.
- Scoop: `bucket/zid.json` im Repo gstrainovic/scoop-zid ist die einzige Kopie des
  Manifests. Dessen Excavator (`.github/workflows/excavator.yml`, ScoopInstaller/GithubActions)
  läuft alle 4 Stunden, `gh workflow run excavator.yml -R gstrainovic/scoop-zid` sofort.
