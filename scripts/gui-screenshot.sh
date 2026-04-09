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
WAIT_SECONDS="${2:-30}"

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

# Start app in background (pass extra args: --theme light/dark)
echo "Starting vulkan-ed ${@:3}..."
./zig-out/bin/vulkan-ed ${@:3} &
APP_PID=$!

# Wait for rendering
echo "Waiting ${WAIT_SECONDS}s for rendering..."
sleep "$WAIT_SECONDS"

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
