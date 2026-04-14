#!/bin/bash
# vulkan-ed Image Screenshot via RPC and ydotool.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

IMAGE_PATH="${1:-screenshots/phase12A_verify.png}"
OUTPUT_PATH="${2:-screenshots/image_preview_test.png}"

# Ensure ydotoold is running
YDOTOOL_SOCKET="${YDOTOOL_SOCKET:-/tmp/.ydotool_socket}"
export YDOTOOL_SOCKET

# Build in worktree
echo "Building vulkan-ed in worktree..."
cd .worktree-images
zig build
cd ..

# Start app from worktree
APP_LOG=$(mktemp)
echo "Starting vulkan-ed --e2e..."
./.worktree-images/zig-out/bin/vulkan-ed --e2e > "$APP_LOG" 2>&1 &
APP_PID=$!

# Wait for ready
echo "Waiting for vulkan-ed ready..."
timeout 10 grep -q "vulkan-ed ready" <(tail -f "$APP_LOG") || true

# Send RPC to open image
echo "Sending RPC to open $IMAGE_PATH..."
sleep 2 # Extra Buffer
python3 scripts/rpc_client.py open_file "$IMAGE_PATH"

# Wait for rendering
sleep 2

# Take screenshot
echo "Taking screenshot..."
SCREENSHOT_DIR="$HOME/Bilder/Bildschirmfotos"
BEFORE=$(ls -t "$SCREENSHOT_DIR"/*.png 2>/dev/null | head -1 || echo "")
ydotool key 42:1 99:1 99:0 42:0

# Wait for file
for i in $(seq 1 100); do
    sleep 0.1
    AFTER=$(ls -t "$SCREENSHOT_DIR"/*.png 2>/dev/null | head -1 || echo "")
    if [[ -n "$AFTER" && "$AFTER" != "$BEFORE" ]]; then
        cp "$AFTER" "$OUTPUT_PATH"
        echo "Screenshot saved: $OUTPUT_PATH"
        break
    fi
done

# Cleanup
cat "$APP_LOG"
kill $APP_PID 2>/dev/null || true
rm -f "$APP_LOG"
