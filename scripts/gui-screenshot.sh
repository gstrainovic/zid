#!/bin/bash
# vulkan-ed GUI Screenshot via ydotool (GNOME Wayland).
# Startet vulkan-ed, wartet auf Rendering, macht Screenshot.
#
# Usage:
#   ./gui-screenshot.sh [output_path] [wait_seconds]
#
# Requires: ydotool, ydotoold

set -euo pipefail

# Wechsle ins Projekt-Root (Elternverzeichnis von scripts/)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

YDOTOOL_SOCKET="${YDOTOOL_SOCKET:-/tmp/.ydotool_socket}"
OUTPUT_PATH="${1:-screenshots/screenshot_gui.png}"
WAIT_TIMEOUT="${2:-30}"

# Ensure ydotoold is running
if [[ ! -S "$YDOTOOL_SOCKET" ]]; then
    if ! command -v ydotoold &>/dev/null; then
        echo "ERROR: ydotoold not found. Install ydotool." >&2
        exit 1
    fi
    echo "Starting ydotoold..."
    sudo ydotoold --socket-path "$YDOTOOL_SOCKET" --socket-perm 666 &
    sleep 1
    if [[ ! -S "$YDOTOOL_SOCKET" ]]; then
        echo "ERROR: Failed to start ydotoold" >&2
        exit 1
    fi
fi

export YDOTOOL_SOCKET

# Build
echo "Building vulkan-ed..."
zig build

# Remember newest screenshot before taking one
SCREENSHOT_DIR="$HOME/Bilder/Bildschirmfotos"
BEFORE=$(ls -t "$SCREENSHOT_DIR"/*.png 2>/dev/null | head -1 || echo "")

# Start app in background, capture output to detect readiness
APP_LOG=$(mktemp)
echo "Starting vulkan-ed ${@:3}..."
./zig-out/bin/vulkan-ed ${@:3} > "$APP_LOG" 2>&1 &
APP_PID=$!

# Wait for "vulkan-ed ready" in output (statt fixem sleep)
echo "Waiting for vulkan-ed to be ready (timeout: ${WAIT_TIMEOUT}s)..."
READY=false
for i in $(seq 1 "$((WAIT_TIMEOUT * 10))"); do
    if ! kill -0 "$APP_PID" 2>/dev/null; then
        echo "ERROR: vulkan-ed exited prematurely:" >&2
        cat "$APP_LOG" >&2
        rm -f "$APP_LOG"
        exit 1
    fi
    if grep -q "vulkan-ed ready" "$APP_LOG" 2>/dev/null; then
        READY=true
        break
    fi
    sleep 0.1
done

if ! $READY; then
    echo "ERROR: vulkan-ed did not become ready within ${WAIT_TIMEOUT}s:" >&2
    cat "$APP_LOG" >&2
    kill $APP_PID 2>/dev/null || true
    rm -f "$APP_LOG"
    exit 1
fi

# Extra kurz warten damit der erste Frame gerendert wird
sleep 1
echo "vulkan-ed ready (after ~$((i / 10))s). Taking screenshot..."

# Take screenshot via ydotool (Shift+Print)
echo "Taking screenshot..."
ydotool key 42:1 99:1 99:0 42:0

# Wait for new file to appear
for i in $(seq 1 150); do
    sleep 0.1
    AFTER=$(ls -t "$SCREENSHOT_DIR"/*.png 2>/dev/null | head -1 || echo "")
    if [[ -n "$AFTER" && "$AFTER" != "$BEFORE" ]]; then
        mkdir -p "$(dirname "$OUTPUT_PATH")"
        cp "$AFTER" "$OUTPUT_PATH"
        echo "Screenshot saved: $OUTPUT_PATH"
        break
    fi
done

# Cleanup
echo "Cleaning up..."
kill $APP_PID 2>/dev/null || true
wait $APP_PID 2>/dev/null || true
rm -f "$APP_LOG"

echo ""
echo "=========================================="
echo "PFLICHT: Screenshot JETZT visuell pruefen!"
echo "=========================================="
echo ""
echo "NAECHSTER SCHRITT (nicht ueberspringen!):"
echo "  Oeffne $OUTPUT_PATH mit ReadFile/Read-Tool als BILD."
echo "  Pruefe visuell:"
echo "    - Ist das neue Feature sichtbar?"
echo "    - Ist Text lesbar (nicht abgeschnitten/ueberlappt)?"
echo "    - Sind Farben und Positionen korrekt?"
echo "  Erst wenn alles stimmt: weiter mit todo.md + commit."
echo "  Falls nicht: Code fixen und erneut Screenshot machen."
echo ""
