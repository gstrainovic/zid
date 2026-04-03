#!/bin/bash
# vulkan-ed GUI Screenshot via ydotool (GNOME Wayland).
# Startet vulkan-ed, wartet auf Rendering, macht Screenshot.
#
# Usage:
#   ./gui-screenshot.sh [output_path] [wait_seconds]
#
# Requires: ydotool, ydotoold, imagemagick (import)

set -euo pipefail

cd "$(dirname "$0")"

YDOTOOL_SOCKET="${YDOTOOL_SOCKET:-/tmp/.ydotool_socket}"
OUTPUT_PATH="${1:-screenshots/screenshot_gui.png}"
WAIT_SECONDS="${2:-5}"

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
BEFORE=$(ls -t "$SCREENSHOT_DIR"/*.png 2>/dev/null | head -1)

# Start app in background
echo "Starting vulkan-ed..."
./zig-out/bin/vulkan-ed test_data/small.log &
APP_PID=$!

# Wait for rendering
echo "Waiting ${WAIT_SECONDS}s for rendering..."
sleep "$WAIT_SECONDS"

# Take screenshot via ydotool (Shift+Print)
echo "Taking screenshot..."
ydotool key 42:1 99:1 99:0 42:0

# Wait for new file to appear
for i in $(seq 1 50); do
    sleep 0.1
    AFTER=$(ls -t "$SCREENSHOT_DIR"/*.png 2>/dev/null | head -1)
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

echo "Done."
