#!/bin/bash
# Screenshot tool for verifying vulkan-ed
# Usage: ./screenshot.sh [timeout_seconds]

TIMEOUT=${1:-5}
OUTPUT_DIR="screenshots"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

mkdir -p "$OUTPUT_DIR"

echo "📸 Taking screenshot in ${TIMEOUT}s..."
sleep "$TIMEOUT"

# Try different screenshot tools
if command -v gnome-screenshot &> /dev/null; then
    FILENAME="${OUTPUT_DIR}/vulkan-ed_${TIMESTAMP}.png"
    gnome-screenshot -f "$FILENAME"
    echo "✅ Screenshot saved: $FILENAME"
elif command -v scrot &> /dev/null; then
    FILENAME="${OUTPUT_DIR}/vulkan-ed_${TIMESTAMP}.png"
    scrot "$FILENAME"
    echo "✅ Screenshot saved: $FILENAME"
elif command -v import &> /dev/null; then
    FILENAME="${OUTPUT_DIR}/vulkan-ed_${TIMESTAMP}.png"
    import -window root "$FILENAME"
    echo "✅ Screenshot saved: $FILENAME"
else
    echo "❌ No screenshot tool found. Install gnome-screenshot, scrot, or imagemagick."
    exit 1
fi
