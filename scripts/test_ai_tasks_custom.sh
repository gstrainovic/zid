#!/bin/bash
set -euo pipefail

echo "Stopping old instances..."
pkill -9 vulkan-ed || true
pkill -9 llama-server || true
sleep 1

echo "Removing model files to test download..."
rm -f *.gguf || true

echo "Building vulkan-ed..."
zig build

export LLAMA_SERVER_PATH=/home/g/llama.cpp/build/bin/llama-server
export LLAMA_MODEL_PATH=$(pwd)/gemma-4-E2B-it-Q4_K_M.gguf
export GGML_VULKAN_DEVICE=1

echo "Starting vulkan-ed with E2E RPC server..."
./zig-out/bin/vulkan-ed --e2e > editor.log 2>&1 &
PID=$!

echo "Waiting for vulkan-ed to be ready..."
for i in $(seq 1 300); do
    if grep -q "vulkan-ed ready" editor.log 2>/dev/null; then
        break
    fi
    sleep 0.1
done
echo "Editor is ready!"

YDOTOOL_SOCKET="${YDOTOOL_SOCKET:-/tmp/.ydotool_socket}"
if [[ ! -S "$YDOTOOL_SOCKET" ]]; then
    sudo ydotoold --socket-path "$YDOTOOL_SOCKET" --socket-perm 666 &
    sleep 1
fi
export YDOTOOL_SOCKET

mkdir -p screenshots
SCREENSHOT_DIR="$HOME/Bilder/Bildschirmfotos"
mkdir -p "$SCREENSHOT_DIR"

take_screenshot() {
    local out_path=$1
    local before=$(ls -t "$SCREENSHOT_DIR"/*.png 2>/dev/null | head -1 || echo "")
    ydotool key 42:1 99:1 99:0 42:0
    for i in $(seq 1 150); do
        sleep 0.1
        local after=$(ls -t "$SCREENSHOT_DIR"/*.png 2>/dev/null | head -1 || echo "")
        if [[ -n "$after" && "$after" != "$before" ]]; then
            cp "$after" "$out_path"
            echo "Screenshot saved to $out_path"
            return
        fi
    done
    echo "Warning: Screenshot failed."
}

echo "Toggling AI Chat..."
python3 scripts/simulate_typing.py --ctrl k
sleep 2

echo "Taking screenshot of Download Button..."
take_screenshot "screenshots/phaseAI_1_download.png"

echo "Clicking Download Button..."
python3 -c "
import socket, json
payload = {'jsonrpc': '2.0', 'method': 'click', 'params': [1000, 30], 'id': 1}
try:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.connect(('127.0.0.1', 9999))
        s.sendall((json.dumps(payload) + '\n').encode())
except Exception as e: print(e)
"
sleep 2

echo "Taking screenshot of Progress Bar..."
take_screenshot "screenshots/phaseAI_2_progress.png"

echo "Waiting for download to finish (up to 90s)..."
for i in $(seq 1 90); do
    if grep -q "Download complete" editor.log 2>/dev/null; then
        echo "Download finished!"
        break
    fi
    sleep 1
done

echo "Waiting for warmup..."
for i in $(seq 1 60); do
    if grep -q "AI Agent is warm and ready" editor.log 2>/dev/null; then
        echo "Warmup finished!"
        break
    fi
    sleep 1
done

echo "Taking screenshot of Ready state..."
take_screenshot "screenshots/phaseAI_3_ready.png"

echo "Asking Gemma a question..."
# First backspace the input buffer just in case
python3 scripts/simulate_typing.py --backspace --backspace --backspace --backspace --backspace --backspace --backspace --backspace
python3 scripts/simulate_typing.py "Read README.md and tell me about it."
sleep 1
python3 scripts/simulate_typing.py --enter

echo "Waiting for Gemma response..."
sleep 25

echo "Taking screenshot of response..."
take_screenshot "screenshots/phaseAI_4_response.png"

echo "Testing click-to-copy..."
python3 -c "
import socket, json
# Click on the latest message to copy it
payload = {'jsonrpc': '2.0', 'method': 'click', 'params': [1000, 500], 'id': 1}
try:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.connect(('127.0.0.1', 9999))
        s.sendall((json.dumps(payload) + '\n').encode())
except Exception as e: print(e)
"
sleep 1

echo "Taking screenshot of Copied state..."
take_screenshot "screenshots/phaseAI_5_copied.png"

echo "Shutting down..."
kill $PID || true
sleep 2

echo "Done running tests. Now invoking review.sh."
./scripts/review.sh --reviewer claude AI
