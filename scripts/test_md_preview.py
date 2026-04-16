import socket
import json
import time
import subprocess
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
            s.settimeout(5)
            s.connect(("127.0.0.1", 9999))
            s.sendall(msg.encode())
            response = s.recv(4096).decode()
            return json.loads(response)
    except Exception as e:
        print(f"RPC Error: {e}")
        return None

def test_md_preview():
    print("Starting Md Preview Test...")
    
    # 1. Open a markdown file
    md_file = os.path.abspath("scripts.md")
    print(f"Opening {md_file}...")
    send_rpc("open_file", [md_file])
    time.sleep(1)
    
    # 2. Right click in the editor area to open context menu
    # Assume editor is at center
    click_x, click_y = 600, 400
    print(f"Right-clicking at {click_x}, {click_y}...")
    send_rpc("right_click", [click_x, click_y])
    time.sleep(0.5)
    
    # 3. Click on "Md Preview" item
    # Context menu is 140 wide, items are ~36 high. 
    # Cut, Copy, Paste, Md Preview.
    # Menu top-left is at click_x, click_y.
    # "Md Preview" is at index 3 (0-based).
    item_x = click_x + 70
    item_y = click_y + 4 + (3 * 36) + 18
    print(f"Clicking 'Md Preview' at {item_x}, {item_y}...")
    send_rpc("click", [item_x, item_y])
    time.sleep(1)
    
    # 4. Take screenshot
    print("Taking screenshot...")
    subprocess.run(["powershell.exe", "-File", "scripts/screenshot_active.ps1", "-OutFile", "test_md_preview.png"])
    
    print("Test finished. Check screenshots/test_md_preview.png")

if __name__ == "__main__":
    test_md_preview()
