# Paket aus dem offiziellen Release-Tarball. Aus den Quellen zu bauen ginge in
# COPR nur mit Netzzugang im Build (zid lädt Zig-Abhängigkeiten beim Bauen) und
# mit genau Zig 0.15.2 — beides passt nicht zu einem normalen mock-Build.
%global appid io.github.gstrainovic.zid
# Ein fertiges Binary: nichts zu debuggen, nichts zu strippen, nichts zu prüfen.
%global debug_package %{nil}
%global __strip /bin/true
%global __brp_check_rpaths %{nil}

Name:           zid
Version:        0.1.7
Release:        1%{?dist}
Summary:        GPU-beschleunigter Editor mit Markdown-Vorschau, PDF-Anzeige und lokaler KI

License:        AGPL-3.0-only
URL:            https://github.com/gstrainovic/zid
Source0:        %{url}/releases/download/v%{version}/zid-%{version}-x86_64-linux.tar.xz
ExclusiveArch:  x86_64

BuildRequires:  desktop-file-utils
BuildRequires:  appstream

# Dynamisch gelinkt; MuPDF, libjpeg, tree-sitter und wgpu stecken im Binary.
Requires:       freetype
Requires:       harfbuzz
Requires:       libpng
Requires:       zlib
Requires:       glib2
# Ohne Vulkan-Treiber startet das Rendering nicht.
Requires:       vulkan-loader
# Suche im Projekt (Ctrl+Shift+F). Das rg aus dem Tarball (libexec/zid) bleibt
# draussen, die Distribution liefert ihr eigenes.
Requires:       ripgrep

%description
zid ist ein in Zig geschriebener Editor. Er rendert über Vulkan, läuft unter
Wayland und X11 und bringt Markdown-Vorschau, Marp-Folien, PDF-Anzeige,
Bildanzeige, ein eingebettetes Terminal und Git-Ansichten mit. Der KI-Chat
spricht mit einem lokalen llama-server oder Ollama; es verlässt nichts den
Rechner.

%prep
%setup -q -n zid-%{version}-x86_64-linux

%build
# Nichts zu bauen: das Binary kommt fertig aus dem Release.

%install
install -Dm755 bin/zid %{buildroot}%{_bindir}/zid
install -Dm644 share/applications/%{appid}.desktop \
    %{buildroot}%{_datadir}/applications/%{appid}.desktop
install -Dm644 share/icons/hicolor/scalable/apps/%{appid}.svg \
    %{buildroot}%{_datadir}/icons/hicolor/scalable/apps/%{appid}.svg
install -Dm644 share/metainfo/%{appid}.metainfo.xml \
    %{buildroot}%{_datadir}/metainfo/%{appid}.metainfo.xml
install -Dm644 LICENSE %{buildroot}%{_datadir}/licenses/%{name}/LICENSE

%check
desktop-file-validate %{buildroot}%{_datadir}/applications/%{appid}.desktop
appstreamcli validate --no-net \
    %{buildroot}%{_datadir}/metainfo/%{appid}.metainfo.xml

%files
%license LICENSE
%{_bindir}/zid
%{_datadir}/applications/%{appid}.desktop
%{_datadir}/icons/hicolor/scalable/apps/%{appid}.svg
%{_datadir}/metainfo/%{appid}.metainfo.xml

%changelog
* Thu Sep 24 2026 gst <g.strainovic@waelli.ch> - 0.1.7-1
- Windows: deleting in the explorer moves files to the Recycle Bin; files on network shares and USB drives without a Recycle Bin are copied to a local drive first and recycled from there.
- Linux: deleting files on another partition or a USB drive copies them to the home trash instead of failing.
- Arch Linux package source (pacman).
- Snap package discontinued.

* Thu Sep 24 2026 gst <g.strainovic@waelli.ch> - 0.1.6-1
- Windows: deleting in the explorer moves files to the Recycle Bin; files on network shares and USB drives without a Recycle Bin are copied to a local drive first and recycled from there.
- Linux: deleting files on another partition or a USB drive copies them to the home trash instead of failing.
- Arch Linux package source (pacman).

* Tue Sep 22 2026 gst <g.strainovic@waelli.ch> - 0.1.5-1
- PDF preview: zoom (50-400 %, Ctrl+wheel, Ctrl+Plus/Minus/0), scrolling within the page and pages rendered sharp at the display scale.
- PDF preview: search with Ctrl+F, hits highlighted on the page, Enter/Shift+Enter jump across pages.
- Source control: commit field no longer clips its text, the graph loads faster, quitting aborts hanging git processes.
- Long input scrolls inside text fields; cursor visible in folder dialog and picker; the window starts maximized.
- Fixed a crash in text wrapping caused by a colliding measurement cache entry.

* Tue Sep 22 2026 gst <g.strainovic@waelli.ch> - 0.1.4-1
- apt-Quelle für Debian und Ubuntu
- fremde Repos nach Rückfrage in safe.directory eintragen
- Repo-Suche endet an der UNC-Freigabewurzel

* Tue Sep 22 2026 gst <g.strainovic@waelli.ch> - 0.1.3-1
- Windows: zid logo as program and taskbar icon.

* Mon Sep 21 2026 gstrainovic <g.strainovic@gmail.com> - 0.1.2-1
- Search and replace across the project (Ctrl+Shift+F / Ctrl+Shift+H), powered by ripgrep.
- Find (Ctrl+F) in the Markdown preview.
- Color emoji on Windows.
- New packages: .deb, .rpm and Snap.
- Release binaries run on every x86-64 CPU again (0.1.1 needed AVX2).
- Files with CRLF line endings no longer count as modified after opening; invalid UTF-8 no longer crashes zid.

* Sun Sep 20 2026 gstrainovic <g.strainovic@gmail.com> - 0.1.1-1
- Farbige Emoji, KI richtet Engine und Modell selbst ein, Ollama entfernt

* Sun Sep 20 2026 gstrainovic <g.strainovic@gmail.com> - 0.1.0-1
- Erstes Paket
