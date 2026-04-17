import socket
import json
import sys
import subprocess
import time
import os

def send_rpc(method, params=[]):
    payload = {
        "jsonrpc": "2.0",
        "method": method,
        "params": params,
        "id": 1
    }
    msg = json.dumps(payload) + "\n"
    
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.settimeout(5.0)
            s.connect(("127.0.0.1", 9999))
            s.sendall(msg.encode())
            response = s.recv(4096).decode()
            if not response:
                return {"result": "ok"} # Some commands like shutdown might not return before close
            return json.loads(response)
    except Exception as e:
        return {"error": str(e)}

def main():
    print("=== Split Flow Test ===")
    
    # Ensure screenshots dir exists
    if not os.path.exists("screenshots"):
        os.makedirs("screenshots")

    print("Building vulkan-ed...")
    subprocess.run(["zig", "build"], check=True)

    exe = os.path.join("zig-out", "bin", "vulkan-ed.exe")
    if not os.path.exists(exe):
        print(f"Error: {exe} not found!")
        return

    print(f"Starting {exe} with --e2e...")
    proc = subprocess.Popen([exe, "--e2e"])
    
    try:
        # Wait for RPC server to be ready
        print("Waiting for RPC server...")
        time.sleep(3)
        
        print("Step 1: Open a file...")
        res = send_rpc("open_file", ["src/main.zig"])
        print(f"Result: {res}")
        time.sleep(1)
        
        print("Step 2: Split pane vertically...")
        # Note: direction is a string parameter "v" or "h"
        res = send_rpc("split_pane", ["v"])
        print(f"Result: {res}")
        time.sleep(2) # Give it time to layout and render
        
        print("Step 3: Taking screenshot...")
        ps_cmd = [
            "powershell", 
            "-NoProfile", 
            "-ExecutionPolicy", "Bypass", 
            "-File", "scripts/screenshot_pid.ps1", 
            "-TargetPid", str(proc.pid), 
            "-OutFile", "split_test_rpc.png"
        ]
        subprocess.run(ps_cmd, check=True)
        
        print("Step 4: Cleanup (Shutdown)...")
        send_rpc("shutdown", [])
        time.sleep(1)
        
    except Exception as e:
        print(f"Test failed: {e}")
    finally:
        if proc.poll() is None:
            print("Terminating process...")
            proc.terminate()
            
    print("\nTest flow complete.")
    print("Check screenshots/split_test_rpc.png for results.")

if __name__ == "__main__":
    main()
