#!/usr/bin/env bash
# Baut BitNet auf dem Stand 01eb415 (Referenz des Windows-Laufs) nach ~/ki/BitNet-ref.
# Der bestehende Build in ~/ki/BitNet bleibt unberuehrt.
set -euo pipefail

BENCH=~/projects/bitnet-colibri-bench
REF=~/ki/BitNet-ref

say() { printf '\n=== %s\n' "$*"; }

if [ ! -d "$REF" ]; then
    say "lokal klonen (kein Netz noetig fuer BitNet selbst)"
    git clone ~/ki/BitNet "$REF"
fi

cd "$REF"
say "auf 01eb415 stellen"
git checkout -q 01eb415

say "Submodul auf den damals gepinnten Stand holen"
git submodule sync --recursive
git submodule update --init --recursive

echo -n "llama.cpp jetzt bei: "; git ls-tree HEAD 3rdparty/llama.cpp | awk '{print $3}'

say "Patch anwenden (an diesem Commit noetig)"
if git apply --check "$BENCH/patches/bitnet-mad-const-y_col.patch" 2>/dev/null; then
    git apply "$BENCH/patches/bitnet-mad-const-y_col.patch"
    echo "angewendet"
else
    echo "uebersprungen (schon drin oder Quelle abweichend)"
fi

say "Kernel-Header erzeugen (an diesem Commit nicht eingecheckt)"
if [ ! -f include/bitnet-lut-kernels.h ]; then
    python3 utils/codegen_tl2.py --model bitnet_b1_58-3B \
        --BM 160,320,320 --BK 96,96,96 --bm 32,32,32
fi

say "bauen"
CC_BIN="$(command -v clang || command -v gcc)"
CXX_BIN="$(command -v clang++ || command -v g++)"
cmake -B build -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DBITNET_X86_TL2=OFF \
    -DCMAKE_C_COMPILER="$CC_BIN" \
    -DCMAKE_CXX_COMPILER="$CXX_BIN" \
    -DLLAMA_CURL=OFF \
    -DLLAMA_BUILD_COMMON=ON -DLLAMA_BUILD_TOOLS=ON -DLLAMA_BUILD_EXAMPLES=ON \
    -DLLAMA_BUILD_SERVER=ON
cmake --build build --config Release -j 6

say "fertig"
ls build/bin/ | grep -E '^llama-(server|bench|perplexity|cli)$' || true
