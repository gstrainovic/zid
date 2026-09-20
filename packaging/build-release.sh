#!/usr/bin/env bash
# Release-Tarball für Linux bauen — in einem Debian-12-Container, damit das Binary
# gegen eine alte glibc (2.36) linkt und auch auf älteren Distributionen startet.
# Auf der Entwicklungsmaschine gebaut verlangt zid GLIBC_2.38 und scheitert dort.
#
# Aufruf:  packaging/build-release.sh [--engine podman|docker]
# Ergebnis: dist/zid-<version>-x86_64-linux.tar.xz
#
# Der Container fasst nur zwei Dinge außerhalb des Repos an: seinen eigenen
# Zig-Cache und sein eigenes MuPDF-Build-Verzeichnis (build/release-deb12), damit
# die Artefakte der Entwicklungsmaschine unberührt bleiben.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
engine=""
image="docker.io/library/debian:12"
zig_version="0.15.2"
mupdf_out="build/release-deb12"

while [ $# -gt 0 ]; do
    case "$1" in
        --engine) engine="$2"; shift 2 ;;
        *) echo "Unbekanntes Argument: $1" >&2; exit 2 ;;
    esac
done

if [ -z "$engine" ]; then
    if command -v podman >/dev/null 2>&1; then engine=podman
    elif command -v docker >/dev/null 2>&1; then engine=docker
    else echo "Weder podman noch docker gefunden." >&2; exit 1
    fi
fi

version="$(sed -n 's/.*\.version = "\([^"]*\)".*/\1/p' "$root/build.zig.zon" | head -1)"
[ -n "$version" ] || { echo "Version nicht aus build.zig.zon lesbar." >&2; exit 1; }

echo "== zid $version, Build in $image über $engine"

# Der Container baut als root — apt und /opt brauchen das. Unter rootless podman
# ist Container-root bereits der aufrufende Benutzer, die erzeugten Dateien gehören
# also ihm. Unter docker läuft der Container wirklich als root, deshalb gibt er die
# erzeugten Pfade am Ende zurück (chown).
chown_back=no
[ "$engine" = docker ] && chown_back=yes

# --security-opt label=disable: unter SELinux (Fedora) scheitert der Container sonst
# an den Labels des gemounteten Repos ("make: stat: Makefile: Permission denied").
# Ein :z-Mount würde stattdessen das ganze Repo auf dem Host umlabeln.
"$engine" run --rm -i --security-opt label=disable \
    -v "$root:/src:rw" -w /src \
    -e ZIG_VERSION="$zig_version" -e MUPDF_OUT="$mupdf_out" -e VERSION="$version" \
    -e CHOWN_BACK="$chown_back" -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
    "$image" bash -euo pipefail -s <<'CONTAINER'
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    build-essential git curl ca-certificates xz-utils python3 pkg-config \
    libwayland-dev libxkbcommon-dev libdecor-0-dev libegl1-mesa-dev libvulkan-dev \
    libx11-dev libxcursor-dev libfreetype-dev libharfbuzz-dev libpng-dev \
    libjpeg-dev zlib1g-dev > /dev/null

# Zig fest gepinnt: build.zig.zon verlangt 0.15.2, neuere Versionen brechen ab.
zig_dir="/opt/zig-$ZIG_VERSION"
if [ ! -x "$zig_dir/zig" ]; then
    mkdir -p "$zig_dir"
    curl -sSL "https://ziglang.org/download/$ZIG_VERSION/zig-x86_64-linux-$ZIG_VERSION.tar.xz" \
        | tar -xJ -C "$zig_dir" --strip-components=1
fi
export PATH="$zig_dir:$PATH"
zig version

# MuPDF statisch, in ein eigenes OUT. FreeType, HarfBuzz und zlib bleiben
# System-Bibliotheken (ABI-stabil); libjpeg nicht, weil deren SONAME je Distribution
# wechselt (.62 auf Debian, .8 auf Ubuntu und Arch). Tesseract, Leptonica, ZXing und
# libcurl fallen ganz weg.
cd libs/fancy-cat/deps/mupdf
# Immer von vorn: make sieht geänderte Flags nicht. Ein OUT aus einem Lauf mit
# USE_SYSTEM_LIBJPEG=yes behielt sein leeres jmemcust.o und der Link scheiterte an
# `undefined symbol: jpeg_mem_init`.
rm -rf "$MUPDF_OUT"
make -j"$(nproc)" libs OUT="$MUPDF_OUT" \
    HAVE_X11=no HAVE_GLUT=no HAVE_OBJCOPY=no tools=no apps=no \
    USE_SYSTEM_FREETYPE=yes USE_SYSTEM_HARFBUZZ=yes USE_SYSTEM_ZLIB=yes \
    USE_SYSTEM_LIBJPEG=no HAVE_LEPTONICA=no HAVE_TESSERACT=no HAVE_ZXINGCPP=no \
    XCFLAGS="-w -fPIC" > /tmp/mupdf.log 2>&1 || { tail -30 /tmp/mupdf.log; exit 1; }
cd /src

out="/tmp/zid-install"
rm -rf "$out"
zig build install \
    --cache-dir /tmp/zig-cache --global-cache-dir /tmp/zig-global \
    -Dmupdf=bundled -Dmupdf-lib-dir="libs/fancy-cat/deps/mupdf/$MUPDF_OUT" \
    -Doptimize=ReleaseSafe --prefix "$out"

strip -s "$out/bin/zid"
# Testdaten aus dem Entwicklungsbaum gehören nicht ins Paket.
rm -f "$out/share/app.log" "$out/share/syntax_test.md"
cp packaging/install.sh "$out/install.sh"
cp README.md LICENSE "$out/"
chmod +x "$out/install.sh"

stage="/tmp/zid-$VERSION-x86_64-linux"
rm -rf "$stage"
mv "$out" "$stage"
mkdir -p /src/dist
tar -C /tmp -cJf "/src/dist/zid-$VERSION-x86_64-linux.tar.xz" "zid-$VERSION-x86_64-linux"

echo "== Ergebnis"
ls -la "/src/dist/zid-$VERSION-x86_64-linux.tar.xz"
echo "== Höchste benötigte glibc-Version"
objdump -T "$stage/bin/zid" | grep -oE 'GLIBC_[0-9.]+' | sort -V | uniq | tail -1
echo "== Dynamische Abhängigkeiten"
ldd "$stage/bin/zid"

if [ "$CHOWN_BACK" = yes ]; then
    chown -R "$HOST_UID:$HOST_GID" /src/dist "/src/libs/fancy-cat/deps/mupdf/$MUPDF_OUT"
fi
CONTAINER

echo "== Fertig: dist/zid-$version-x86_64-linux.tar.xz"
