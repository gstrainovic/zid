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
    except: return None

# Erst warten bis App bereit
time.sleep(2)

text = "pub fn main() {\n    return 0;\n}"
print(f"Typing {len(text)} chars...")
for char in text:
    send_rpc("type_text", [char])
    time.sleep(0.05)
print("Done.")
