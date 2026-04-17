import subprocess
import time
import socket
import json
import os

def send_rpc(method, params=[]):
    msg = {
        "jsonrpc": "2.0",
        "method": method,
        "params": params,
        "id": 1
    }
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.connect(("127.0.0.1", 9999))
    s.sendall(json.dumps(msg).encode() + b"\n")
    data = s.recv(4096)
    s.close()
    return json.loads(data.decode())

def main():
    print("=== Split/Close Test ===")
    
    print("Building vulkan-ed...")
    subprocess.run(["zig", "build"], check=True)
    
    print("Starting zig-out\\bin\\vulkan-ed.exe with --e2e...")
    proc = subprocess.Popen(["zig-out\\bin\\vulkan-ed.exe", "--e2e"], 
                            stdout=subprocess.PIPE, 
                            stderr=subprocess.PIPE)
    
    print("Waiting for RPC server...")
    time.sleep(3)
    
    try:
        print("Step 1: Open a file...")
        res = send_rpc("open_file", ["src/main.zig"])
        print(f"Result: {res}")
        time.sleep(0.5)
        
        print("Step 2: Split pane...")
        # Split horizontal (side by side)
        res = send_rpc("split_pane", ["h"])
        print(f"Result: {res}")
        time.sleep(0.5)

        print("Step 3: Taking screenshot of split...")
        subprocess.run(["powershell", "-ExecutionPolicy", "Bypass", "-File", "scripts/screenshot_pid.ps1", str(proc.pid), "split_open_proof.png"])

        print("Step 4: Closing tab in the new split...")
        res = send_rpc("close_active_tab", [])
        print(f"Result: {res}")
        time.sleep(1.0)

        print("Step 5: Taking screenshot of closed split...")
        subprocess.run(["powershell", "-ExecutionPolicy", "Bypass", "-File", "scripts/screenshot_pid.ps1", str(proc.pid), "split_closed_proof.png"])

        print("Step 6: Cleanup (Shutdown)...")
        send_rpc("shutdown")
        
    except Exception as e:
        print(f"Error: {e}")
        out, err = proc.communicate()
        print(f"Stdout: {out.decode()}")
        print(f"Stderr: {err.decode()}")
        proc.terminate()
    
    out, err = proc.communicate()
    print(f"Final Stderr: {err.decode()}")
    proc.wait()
    print("\nTest flow complete.")
    print("Check screenshots/split_open_test.png and split_closed_test.png")

if __name__ == "__main__":
    main()
