#!/usr/bin/env bash
# Schreibt die RUNPATHs der cmake-Builds unter engines/ auf $ORIGIN-relative Pfade um.
# Noetig, weil cmake absolute Build-Pfade einbrennt: nach dem Umzug der Engines von
# ~/projects/ki nach engines/ (06.09.2026) fanden llama-server und llama-bench ihre
# libllama.so nicht mehr. Idempotent; braucht patchelf.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
command -v patchelf >/dev/null || { echo "patchelf fehlt" >&2; exit 1; }

fix() {  # fix <datei> <runpath>
    readelf -d "$1" 2>/dev/null | grep -q "RUNPATH\|RPATH" || return 0
    # Kopie patchen und darueberschieben: ein laufender llama-server haelt die Datei
    # gemappt ("Text file busy"), behaelt aber seine alte Inode.
    cp -p "$1" "$1.rpath.tmp" && patchelf --set-rpath "$2" "$1.rpath.tmp" && mv -f "$1.rpath.tmp" "$1"
}

# llama.cpp-vulkan: alles liegt in build/bin
for f in "$REPO"/engines/llama.cpp-vulkan/build/bin/*; do
    [ -f "$f" ] && fix "$f" '$ORIGIN'
done

# BitNet: Programme in build/bin, Bibliotheken unter build/3rdparty/llama.cpp/{src,ggml/src}
B="$REPO/engines/BitNet/build"
for f in "$B"/bin/*; do
    [ -f "$f" ] && fix "$f" '$ORIGIN/../3rdparty/llama.cpp/src:$ORIGIN/../3rdparty/llama.cpp/ggml/src'
done
fix "$B/3rdparty/llama.cpp/src/libllama.so" '$ORIGIN/../ggml/src'
[ -f "$B/3rdparty/llama.cpp/examples/llava/libllava_shared.so" ] && \
    fix "$B/3rdparty/llama.cpp/examples/llava/libllava_shared.so" '$ORIGIN/../../src:$ORIGIN/../../ggml/src'
echo "RUNPATHs umgeschrieben"
