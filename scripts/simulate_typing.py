import socket
import json
import time
import sys
import subprocess

print("Building vulkan-ed...")
subprocess.run(["zig", "build"], check=True)

def send_rpc(method, params=[]):
    payload = {"jsonrpc": "2.0", "method": method, "params": params, "id": 1}
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.connect(("127.0.0.1", 9999))
            s.sendall((json.dumps(payload) + "\n").encode())
            return s.recv(4096)
    except Exception as e:
        print(f"Error: {e}")
        return None

# Wait for app to be ready if it was just started
# In our tests, we start vulkan-ed and wait in the bash script, so maybe we don't need a long delay here.
# But let's keep a small delay just in case.
time.sleep(0.5)

args = sys.argv[1:]

if not args:
    text = "pub fn main() {\n    return 0;\n}"
    print(f"Typing default {len(text)} chars...")
    send_rpc("type_text", [text])
    print("Done.")
    sys.exit(0)

i = 0
while i < len(args):
    arg = args[i]
    if arg == "--ctrl":
        key = args[i+1]
        print(f"Sending Ctrl+{key}...")
        send_rpc("key_press", [key, True])
        i += 2
    elif arg == "--enter":
        print("Sending Enter...")
        send_rpc("key_press", ["enter", False])
        i += 1
    elif arg == "--backspace":
        print("Sending Backspace...")
        send_rpc("key_press", ["backspace", False])
        i += 1
    else:
        text = arg
        print(f"Typing '{text}'...")
        send_rpc("type_text", [text])
        i += 1

print("Done.")
