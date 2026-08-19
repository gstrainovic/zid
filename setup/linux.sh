#!/usr/bin/env bash
# Baut BitNet und colibri auf Linux und holt die Modelle, mit denen auf der
# Windows-Kiste gemessen wurde. Idempotent: was schon da ist, wird uebersprungen.
#
#   ./setup/linux.sh [zielverzeichnis]
#
# Vorher: build-essential (oder clang), cmake >= 3.22, ninja, git, python3.
# Braucht rund 25 GB Platte; OLMoE ist der grosse Posten.
set -euo pipefail

ROOT="${1:-$HOME/ki}"
BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

mkdir -p "$ROOT"
cd "$ROOT"

say() { printf '\n=== %s\n' "$*"; }

need() {
    command -v "$1" >/dev/null 2>&1 || { echo "fehlt: $1" >&2; exit 1; }
}
need git
need cmake
need python3

# --- BitNet ------------------------------------------------------------------

say "BitNet holen"
if [ ! -d BitNet ]; then
    git clone --recursive https://github.com/microsoft/BitNet.git
fi

cd BitNet

say "Patch anwenden (nur noetig, falls noch nicht drin)"
if git apply --check "$BENCH_DIR/patches/bitnet-mad-const-y_col.patch" 2>/dev/null; then
    git apply "$BENCH_DIR/patches/bitnet-mad-const-y_col.patch"
    echo "angewendet"
else
    echo "uebersprungen (bereits angewendet oder Quelle abweichend)"
fi

say "Kernel-Header erzeugen"
# Erzeugt include/bitnet-lut-kernels.h. Auch fuer den i2_s-Weg noetig, weil
# ggml-bitnet-lut.cpp den Header unbedingt einbindet. Parameter wie in
# setup_env.py fuer BitNet-b1.58-2B-4T.
if [ ! -f include/bitnet-lut-kernels.h ]; then
    if [ "$(uname -m)" = "aarch64" ] || [ "$(uname -m)" = "arm64" ]; then
        python3 utils/codegen_tl1.py --model bitnet_b1_58-3B \
            --BM 160,320,320 --BK 64,128,64 --bm 32,64,32
    else
        python3 utils/codegen_tl2.py --model bitnet_b1_58-3B \
            --BM 160,320,320 --BK 96,96,96 --bm 32,32,32
    fi
fi

say "Bauen"
# Nicht ueber setup_env.py: das erzwingt unter Windows den ClangCL-Generator und
# macht auf Linux ohnehin nur dieselben zwei cmake-Aufrufe.
if [ ! -x build/bin/llama-cli ]; then
    CC_BIN="$(command -v clang || command -v gcc)"
    CXX_BIN="$(command -v clang++ || command -v g++)"
    cmake -B build \
        -G "$(command -v ninja >/dev/null && echo Ninja || echo 'Unix Makefiles')" \
        -DCMAKE_BUILD_TYPE=Release \
        -DBITNET_X86_TL2=OFF \
        -DCMAKE_C_COMPILER="$CC_BIN" \
        -DCMAKE_CXX_COMPILER="$CXX_BIN" \
        -DLLAMA_CURL=OFF
    cmake --build build --config Release -j "$(nproc)"
fi

say "Modelle holen"
mkdir -p models/BitNet-b1.58-2B-4T models/_compare
if [ ! -s models/BitNet-b1.58-2B-4T/ggml-model-i2_s.gguf ]; then
    curl -L --retry 3 -o models/BitNet-b1.58-2B-4T/ggml-model-i2_s.gguf \
        https://huggingface.co/microsoft/BitNet-b1.58-2B-4T-gguf/resolve/main/ggml-model-i2_s.gguf
fi
# Vergleichsmodell: gleiche Engine, gewoehnliche 4-Bit-Quantisierung.
if [ ! -s models/_compare/Llama-3.2-3B-Instruct-Q4_K_M.gguf ]; then
    curl -L --retry 3 -o models/_compare/Llama-3.2-3B-Instruct-Q4_K_M.gguf \
        https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf
fi

cd "$ROOT"

# --- colibri -----------------------------------------------------------------

say "colibri holen und bauen"
if [ ! -d colibri ]; then
    git clone --depth 1 https://github.com/JustVugg/colibri.git
fi
cd colibri/c
[ -x ./colibri ] || make colibri ARCH=native
[ -x ./olmoe ]   || make olmoe   ARCH=native

cd "$ROOT/colibri"

say "OLMoE konvertieren (laedt und loescht Shard fuer Shard)"
if [ ! -d olmoe_merged ]; then
    python3 -m venv .venv-conv
    ./.venv-conv/bin/pip install --quiet --upgrade pip
    ./.venv-conv/bin/pip install --quiet torch --index-url https://download.pytorch.org/whl/cpu
    ./.venv-conv/bin/pip install --quiet safetensors huggingface_hub numpy
    ./.venv-conv/bin/python c/tools/convert_olmoe_merged.py \
        --repo allenai/OLMoE-1B-7B-0125-Instruct \
        --out ./olmoe_merged \
        --min-free-gb 20
fi

say "fertig"
cat <<EOF

Naechste Schritte — siehe README.md des Bench-Repos:

  # BitNet messen
  cd $ROOT/BitNet
  ./build/bin/llama-bench -m models/BitNet-b1.58-2B-4T/ggml-model-i2_s.gguf \\
      -p 128 -n 64 -t 4,8,12,16 -r 2

  # Fragebogen: Server starten, dann die zwei Skripte
  ./build/bin/llama-server -m models/BitNet-b1.58-2B-4T/ggml-model-i2_s.gguf \\
      -t 4 -tb 12 -c 4096 --port 8080 &
  python3 $BENCH_DIR/bench/agent_eval.py --port 8080 --label BitNet-2B-4T
  python3 $BENCH_DIR/bench/probe.py      --port 8080 --label BitNet-2B-4T

  # colibri
  python3 $BENCH_DIR/bench/olmoe_eval.py \\
      --engine $ROOT/colibri/c/olmoe --snap $ROOT/colibri/olmoe_merged
  python3 $BENCH_DIR/bench/olmoe_speed.py \\
      --engine $ROOT/colibri/c/olmoe --snap $ROOT/colibri/olmoe_merged
EOF
