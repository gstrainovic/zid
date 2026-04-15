#!/usr/bin/env python3
import socket
import json
import time
import subprocess
import os
import sys
import glob
import shutil

RPC_HOST = "127.0.0.1"
RPC_PORT = 9999

def send_rpc(method, params=[]):
    payload = {"jsonrpc": "2.0", "method": method, "params": params, "id": 1}
    try:
        with socket.create_connection((RPC_HOST, RPC_PORT), timeout=5) as sock:
            sock.sendall((json.dumps(payload) + "\n").encode())
            data = b""
            while not data.endswith(b"\n"):
                chunk = sock.recv(1024)
                if not chunk: break
                data += chunk
            return json.loads(data.decode())
    except Exception as e:
        print(f"RPC Error: {e}")
        return None

def main():
    binary = "./zig-out/bin/vulkan-ed"
    if not os.path.exists(binary):
        print(f"Error: {binary} not found. Run 'zig build' first.")
        sys.exit(1)

    print("--- Starting vulkan-ed in background ---")
    # Start with --e2e
    proc = subprocess.Popen([binary, "--e2e"])
    
    time.sleep(4) # Wait for UI and RPC server

    # Remember newest screenshot before taking one
    screenshot_dir = os.path.expanduser("~/Bilder/Bildschirmfotos")
    if not os.path.exists(screenshot_dir):
        # Fallback for systems with different naming
        screenshot_dir = os.path.expanduser("~/Pictures")
    
    files_before = glob.glob(os.path.join(screenshot_dir, "*.png"))
    before_latest = max(files_before, key=os.path.getmtime, default=None) if files_before else None

    try:
        print("--- Opening Terminal via RPC ---")
        send_rpc("open_terminal")
        time.sleep(1)

        print("--- Sending 'ls --color=always' ---")
        send_rpc("type_text", ["ls --color=always\n"])
        time.sleep(1)
        
        print("--- Sending 'seq 1 200' ---")
        send_rpc("type_text", ["seq 1 200\n"])
        time.sleep(3)

        print("--- Taking screenshot via ydotool ---")
        # Shift+Print (Scan codes: 42=Shift, 99=Print)
        env = os.environ.copy()
        env["YDOTOOL_SOCKET"] = "/tmp/.ydotool_socket"
        subprocess.run(["ydotool", "key", "42:1", "99:1", "99:0", "42:0"], env=env)
        
        # Wait for new file to appear
        screenshot_final = "terminal_rpc_test.png"
        found = False
        for _ in range(100):
            time.sleep(0.1)
            files_after = glob.glob(os.path.join(screenshot_dir, "*.png"))
            if not files_after: continue
            after_latest = max(files_after, key=os.path.getmtime)
            if after_latest != before_latest:
                shutil.copy(after_latest, screenshot_final)
                print(f"Screenshot saved to: {screenshot_final}")
                found = True
                break
        
        if not found:
            print("Warning: No new screenshot file detected in " + screenshot_dir)

    finally:
        print("--- Shutting down ---")
        try:
            send_rpc("shutdown")
            proc.wait(timeout=5)
        except:
            proc.terminate()

if __name__ == "__main__":
    main()
