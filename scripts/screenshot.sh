#!/bin/bash
# vulkan-ed Screenshot Script (Wayland + X11 kompatibel)
# Startet vulkan-ed, wartet, macht Screenshot, beendet App.
#
# Usage: ./scripts/screenshot.sh [output_path] [wait_seconds]

set -euo pipefail

cd "$(dirname "$0")/.."

OUTPUT_PATH="${1:-screenshots/screenshot.png}"
WAIT_SECONDS="${2:-3}"

mkdir -p "$(dirname "$OUTPUT_PATH")"

# Build
echo "🔨 Building vulkan-ed..."
zig build

# Start app in background
echo "🚀 Starting vulkan-ed..."
./zig-out/bin/vulkan-ed &
APP_PID=$!

# Wait for rendering
echo "⏳ Waiting ${WAIT_SECONDS}s for rendering..."
sleep "$WAIT_SECONDS"

# Take screenshot (Wayland-native grim preferred, fallbacks)
echo "📸 Taking screenshot..."
if command -v grim &> /dev/null; then
    grim "$OUTPUT_PATH"
elif command -v scrot &> /dev/null; then
    scrot "$OUTPUT_PATH"
elif command -v gnome-screenshot &> /dev/null; then
    gnome-screenshot -f "$OUTPUT_PATH"
elif command -v import &> /dev/null; then
    import -window root "$OUTPUT_PATH"
else
    echo "❌ No screenshot tool found. Install grim (Wayland), scrot, gnome-screenshot, or imagemagick."
    kill $APP_PID 2>/dev/null || true
    exit 1
fi

# Cleanup
echo "🧹 Cleaning up..."
kill $APP_PID 2>/dev/null || true
wait $APP_PID 2>/dev/null || true

if [ -f "$OUTPUT_PATH" ]; then
    echo "✅ Screenshot saved: $OUTPUT_PATH"
else
    echo "❌ Screenshot failed"
    exit 1
fi
