#!/bin/bash
# Screenshot-Skript für vulkan-ed
# Verwendung: ./screenshot.sh [datei] [output] [wait_time]
#   datei:      test_data/small.log oder test_data/app.log (default: small.log)
#   output:     output dateiname (default: screenshot.png)
#   wait_time:  wartezeit in sekunden (default: 8)

set -e

FILE=${1:-test_data/small.log}
OUT_FILE=${2:-screenshot.png}
WAIT=${3:-8}
SCREENSHOT_DIR="screenshots"

mkdir -p "$SCREENSHOT_DIR"
OUT_PATH="$SCREENSHOT_DIR/$OUT_FILE"

echo "=== Screenshot Test ==="
echo "File: $FILE"
echo "Output: $OUT_PATH"
echo "Wait: ${WAIT}s"

# xvfb prüfen
if ! command -v Xvfb &> /dev/null; then
    echo "ERROR: Xvfb nicht installiert."
    echo "Installieren mit: sudo apt install xvfb scrot"
    exit 1
fi

# App bauen
echo "Building..."
zig build

# App im Hintergrund starten
echo "Starting app with: $FILE"
Xvfb :99 -screen 0 1024x768x24 &
XVFB_PID=$!
export DISPLAY=:99

sleep 1

./zig-out/bin/vulkan-ed "$FILE" &
APP_PID=$!

# Warten auf Rendering
echo "Waiting ${WAIT}s for rendering..."
sleep $WAIT

# Screenshot machen
if command -v scrot &> /dev/null; then
    scrot "$OUT_PATH"
    echo "Screenshot saved: $OUT_PATH"
elif command -v import &> /dev/null; then
    import "$OUT_PATH"
    echo "Screenshot saved: $OUT_PATH"
else
    echo "WARNING: No screenshot tool found (scrot or imagemagick)"
fi

# Aufräumen
echo "Cleaning up..."
kill $APP_PID 2>/dev/null || true
kill $XVFB_PID 2>/dev/null || true

echo "=== Done ==="
