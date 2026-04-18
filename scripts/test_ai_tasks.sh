#!/bin/bash
set -euo pipefail

echo "Stopping old instances..."
pkill -9 vulkan-ed || true
pkill -9 llama-server || true
sleep 1

echo "Removing model files to test download..."
rm -f *.gguf

export LLAMA_SERVER_PATH=/home/g/llama.cpp/build/bin/llama-server
export LLAMA_MODEL_PATH=$(pwd)/gemma-4-E2B-it-Q4_K_M.gguf
export GGML_VULKAN_DEVICE=1

echo "Starting vulkan-ed with E2E RPC server..."
./zig-out/bin/vulkan-ed --e2e &
PID=$!

sleep 3 # Wait for startup

echo "Toggling AI Chat..."
python3 scripts/simulate_typing.py --ctrl k
sleep 2

echo "Taking screenshot of Download Button..."
mkdir -p screenshots
./scripts/gui-screenshot.sh screenshots/phaseAI_1_download_button.png

# The AI Sidebar is 350px wide on the right. Window is 1200x800.
# Left edge of sidebar is 1200 - 350 = 850.
# Title is at the top. Download button is right next to it.
# Let's send a click at x=1000, y=30
echo "Clicking Download Button..."
python3 -c "
import socket, json
payload = {'jsonrpc': '2.0', 'method': 'click', 'params': [1000, 30], 'id': 1}
with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
    s.connect(('127.0.0.1', 9999))
    s.sendall((json.dumps(payload) + '\n').encode())
"
sleep 2
echo "Taking screenshot of Progress Bar..."
./scripts/gui-screenshot.sh screenshots/phaseAI_2_progress_bar.png

# Wait for download to finish (could take 1-2 mins, let's sleep 60s)
echo "Waiting for download..."
sleep 60

echo "Waiting for warmup..."
sleep 15

echo "Taking screenshot of Warmup/Ready state..."
./scripts/gui-screenshot.sh screenshots/phaseAI_3_ready.png

echo "Asking Gemma a question to trigger a tool..."
python3 scripts/simulate_typing.py "Read README.md and tell me what it says."
sleep 1
python3 scripts/simulate_typing.py --enter

# Wait for Gemma to read and respond
echo "Waiting for Gemma response..."
sleep 20

echo "Taking screenshot of response..."
./scripts/gui-screenshot.sh screenshots/phaseAI_4_response.png

echo "Shutting down..."
python3 -c "
import socket, json
payload = {'jsonrpc': '2.0', 'method': 'shutdown', 'params': [], 'id': 1}
try:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.connect(('127.0.0.1', 9999))
        s.sendall((json.dumps(payload) + '\n').encode())
except: pass
"

wait $PID || true
echo "Done!"
