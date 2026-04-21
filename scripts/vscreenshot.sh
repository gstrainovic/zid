#!/bin/bash
# Vulkan-Editor Screenshot -> Gemini Script
# Aufruf: ./scripts/vscreenshot.sh "Deine Frage hier"
#
# Was es tut:
# 1. Startet vulkan-ed im Headless-Modus
# 2. Macht einen Screenshot (PPM)
# 3. Konvertiert PPM -> PNG via ImageMagick
# 4. Sendet PNG an Gemini mit der Frage

set -euo pipefail

# Args
QUESTION="${1:-}"
if [[ -z "$QUESTION" ]]; then
    echo "Usage: $0 \"Your question here\"" >&2
    exit 1
fi

cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"
TMP_DIR="/tmp/vscreenshot_$$"
mkdir -p "$TMP_DIR"
trap 'rm -rf "$TMP_DIR"' EXIT

PPM_FILE="$TMP_DIR/screenshot.ppm"
PNG_FILE="$TMP_DIR/screenshot.png"

echo "=== Vulkan Screenshot -> Gemini ==="
echo "Frage: $QUESTION"
echo ""

# 1. Baue und starte vulkan-ed
echo "[1/4] Baue vulkan-ed..."
cd "$REPO_ROOT"
zig build -Doptimize=ReleaseSafe 2>&1 | tail -3

echo "[2/4] Starte headless und mache Screenshot..."
# Starte vulkan-ed im Hintergrund
./zig-out/bin/vulkan-ed --headless &
VULKAN_PID=$!
trap 'kill $VULKAN_PID 2>/dev/null || true' EXIT

# Warte auf Server
sleep 3

# Screenshot via RPC
echo '{"jsonrpc":"2.0","method":"screenshot","id":1}' | nc --send-only localhost 9999
sleep 2

# Kopiere Screenshot
cp ./tmp/vulkan-screenshot.ppm "$PPM_FILE" 2>/dev/null || true

# Stoppe vulkan-ed
kill $VULKAN_PID 2>/dev/null || true
wait $VULKAN_PID 2>/dev/null || true

if [[ ! -s "$PPM_FILE" ]]; then
    echo "ERROR: Screenshot fehlgeschlagen oder leer" >&2
    exit 1
fi

echo "[3/4] Konvertiere PPM -> PNG..."
convert "$PPM_FILE" "$PNG_FILE"

if [[ ! -s "$PNG_FILE" ]]; then
    echo "ERROR: PNG Konvertierung fehlgeschlagen" >&2
    exit 1
fi

echo "[4/4] Sende an Gemini..."
echo ""

# Sende an Gemini
gemini -p "IMAGE: $PNG_FILE

Frage: $QUESTION

Antworte auf Deutsch mit einer detaillierten Beschreibung dessen was du im Bild siehst, insbesondere bezueglich:
- Layout und Struktur der UI
- Farben und Styling
- Code-Blöcke und deren Syntax-Highlighting
- Etwaige Probleme oder Bugs die du erkennst" \
    --yolo \
    2>&1

echo ""
echo "=== Fertig ==="
