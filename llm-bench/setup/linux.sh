#!/usr/bin/env bash
# Baut die gepinnte BitNet-Engine auf Linux und holt die Modelle, mit denen auf der
# Windows-Kiste gemessen wurde. Idempotent: was schon da ist, wird uebersprungen.
# Seit 06.09.2026 liegt alles im zid-Repo: Engine unter engines/BitNet
# (Submodul), Modelle flach unter models/ (colibri wurde geloescht).
#
#   ./setup/linux.sh [repo-wurzel]
#
# Vorher: build-essential (oder clang), cmake >= 3.22, ninja, git, python3.
# Braucht rund 5 GB Platte.
set -euo pipefail

BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="${1:-$(cd "$BENCH_DIR/.." && pwd)}"
MODELS="$ROOT/models"

mkdir -p "$ROOT/engines" "$MODELS/bitnet-b1.58-2B-4T"
cd "$ROOT/engines"

say() { printf '\n=== %s\n' "$*"; }

need() {
    command -v "$1" >/dev/null 2>&1 || { echo "fehlt: $1" >&2; exit 1; }
}
need git
need cmake
need python3

# --- BitNet ------------------------------------------------------------------

# Gepinnt, und das ist keine Vorsicht, sondern Notwendigkeit: der heutige
# Stand von microsoft/BitNet zeigt mit seinem llama.cpp-Submodul auf einen
# Fork-Branch (release-bitnet-embedding-0.6b-270m), mit dem BitNet-b1.58-2B-4T
# unbenutzbar ist — das Modell antwortet korrekt und hoert dann nicht mehr auf,
# die Perplexity steigt um Faktor 3.7. Der Durchsatz bleibt dabei unauffaellig,
# man merkt es also nicht, wenn man nur Geschwindigkeit misst.
# Belege: results/linux-i7-8850H.md, Abschnitt "Die Engine muss gepinnt werden".
BITNET_COMMIT=01eb415772c342d9f20dc42772f1583ae1e5b102   # 10.03.2026
LLAMACPP_COMMIT=1f86f058de0c3f4098dedae2ae8653c335c868a1 # b3962, 27.01.2026

say "BitNet holen (gepinnt auf ${BITNET_COMMIT:0:7})"
if [ ! -d BitNet ]; then
    git clone https://github.com/microsoft/BitNet.git
fi

cd BitNet

if [ "$(git rev-parse HEAD)" != "$BITNET_COMMIT" ]; then
    git fetch --all --tags
    git checkout "$BITNET_COMMIT"
fi
git submodule update --init --recursive

got_llama="$(git -C 3rdparty/llama.cpp rev-parse HEAD)"
if [ "$got_llama" != "$LLAMACPP_COMMIT" ]; then
    echo "WARNUNG: llama.cpp steht auf $got_llama, erwartet $LLAMACPP_COMMIT" >&2
    echo "Messungen mit einem anderen Stand sind nicht vergleichbar." >&2
fi

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
    # LLAMA_BUILD_COMMON/TOOLS/EXAMPLES muessen explizit an: llama.cpp setzt sie
    # als Submodul auf ${LLAMA_STANDALONE}, also OFF, und BitNets CMakeLists
    # erzwingt nur LLAMA_BUILD_SERVER. Ohne sie entstehen bloss die
    # Bibliotheken — kein llama-cli, kein llama-bench.
    cmake -B build \
        -G "$(command -v ninja >/dev/null && echo Ninja || echo 'Unix Makefiles')" \
        -DCMAKE_BUILD_TYPE=Release \
        -DBITNET_X86_TL2=OFF \
        -DCMAKE_C_COMPILER="$CC_BIN" \
        -DCMAKE_CXX_COMPILER="$CXX_BIN" \
        -DLLAMA_CURL=OFF \
        -DLLAMA_BUILD_COMMON=ON \
        -DLLAMA_BUILD_TOOLS=ON \
        -DLLAMA_BUILD_EXAMPLES=ON \
        -DLLAMA_BUILD_SERVER=ON
    cmake --build build --config Release -j "$(nproc)"
fi

for prog in llama-cli llama-server llama-bench llama-quantize; do
    [ -x "build/bin/$prog" ] || { echo "fehlt nach dem Bauen: build/bin/$prog" >&2; exit 1; }
done

say "Modelle holen (nach $MODELS)"
BITNET_GGUF="$MODELS/bitnet-b1.58-2B-4T/ggml-model-i2_s.gguf"
if [ ! -s "$BITNET_GGUF" ]; then
    curl -L --retry 3 -o "$BITNET_GGUF" \
        https://huggingface.co/microsoft/BitNet-b1.58-2B-4T-gguf/resolve/main/ggml-model-i2_s.gguf
fi
# Vergleichsmodell: gleiche Engine, gewoehnliche 4-Bit-Quantisierung.
if [ ! -s "$MODELS/Llama-3.2-3B-Instruct-Q4_K_M.gguf" ]; then
    curl -L --retry 3 -o "$MODELS/Llama-3.2-3B-Instruct-Q4_K_M.gguf" \
        https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf
fi
# BitNets eigene Skripte erwarten models/ im Engine-Ordner: zwei Symlinks auf models/
mkdir -p models
[ -e models/_compare ] || ln -s ../../../models models/_compare
[ -e models/BitNet-b1.58-2B-4T ] || ln -s ../../../models/bitnet-b1.58-2B-4T models/BitNet-b1.58-2B-4T

# Modell identifizieren, nicht nur "ist da". Beide bisherigen Laeufe haben
# genau diese Datei vermessen.
BITNET_SHA=4221b252fdd5fd25e15847adfeb5ee88886506ba50b8a34548374492884c2162
got_sha="$(sha256sum "$BITNET_GGUF" | cut -d' ' -f1)"
if [ "$got_sha" != "$BITNET_SHA" ]; then
    echo "WARNUNG: BitNet-GGUF hat sha256 $got_sha, erwartet $BITNET_SHA" >&2
    echo "Andere Datei — Zahlen sind nicht mit results/ vergleichbar." >&2
fi

say "Engine pruefen"
# Laedt die Engine i2_s richtig? Steht in der Modellspalte Q1_0 statt
# "I2_S - 2 bpw ternary", ist jede weitere Zahl wertlos.
if ./build/bin/llama-bench -m "$BITNET_GGUF" \
        -p 8 -n 8 -r 1 2>/dev/null | grep -q "I2_S"; then
    echo "  i2_s wird korrekt erkannt"
else
    echo "  FEHLER: Engine liest i2_s nicht korrekt — nicht messen!" >&2
    exit 1
fi

say "fertig"
cat <<EOF

Naechste Schritte — siehe README.md des Bench-Repos:

  # BitNet messen
  cd $ROOT/engines/BitNet
  ./build/bin/llama-bench -m $BITNET_GGUF \\
      -p 128 -n 64 -t 4,8,12,16 -r 2

  # Fragebogen: Server starten, dann die zwei Skripte.
  # --override-kv ist NICHT optional: dem GGUF fehlt tokenizer.ggml.pre,
  # ohne den Override zerfallen Werkzeugnamen und BitNet faellt von 8-9/10
  # auf 4/10. Siehe results/linux-i7-8850H.md.
  ./build/bin/llama-server -m $BITNET_GGUF \\
      -t 4 -tb 12 -c 4096 --port 8080 \\
      --override-kv tokenizer.ggml.pre=str:llama-bpe &
  python3 $BENCH_DIR/bench/agent_eval.py --port 8080 --label BitNet-2B-4T
  python3 $BENCH_DIR/bench/probe.py      --port 8080 --label BitNet-2B-4T
EOF
