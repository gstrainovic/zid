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
    
    # Wait for RPC server to be ready
    max_retries = 10
    connected = False
    for i in range(max_retries):
        res = send_rpc("get_state")
        if res:
            connected = True
            break
        print(f"Waiting for RPC server... ({i+1}/{max_retries})")
        time.sleep(2)
    
    if not connected:
        print("Could not connect to RPC server.")
        return

    # 1. Open a markdown file
    md_file = os.path.abspath("scripts.md")
    print(f"Opening {md_file}...")
    send_rpc("open_file", [md_file])
    time.sleep(2)
    
    # 2. Right click in the editor area to open context menu
    # Assume editor is at center
    click_x, click_y = 800, 500
    print(f"Right-clicking at {click_x}, {click_y}...")
    send_rpc("right_click", [click_x, click_y])
    time.sleep(1)
    
    # 3. Click on "Md Preview" item
    # Context menu is 140 wide, items are ~36 high (20 font + 12 padding + some extra).
    # Cut, Copy, Paste, Md Preview.
    # Menu top-left is at click_x, click_y.
    # Item 3 center: x = click_x + 70, y = click_y + 4 (padding) + 3.5 * item_height
    item_height = 36 # font_size 24-2 + 12 padding
    item_x = click_x + 70
    item_y = click_y + 4 + (3 * item_height) + (item_height / 2)
    print(f"Clicking 'Md Preview' at {item_x}, {item_y}...")
    send_rpc("click", [item_x, item_y])
    time.sleep(2)
    
    # 4. Take screenshot (without building)
    print("Taking screenshot...")
    # screenshot_active.ps1 builds by default, we skip it by calling the screenshot logic directly if possible 
    # or just let it fail the build part and hope it still takes the shot.
    # Actually, I'll just use a simpler powershell command for the screenshot.
    subprocess.run(["powershell.exe", "-Command", "& { . ./scripts/screenshot_active.ps1; }"], shell=True)
    # The script above might still build. Let's rename the output if it worked.
    if os.path.exists("screenshots/screenshot_active.png"):
        if os.path.exists("screenshots/test_md_preview.png"): os.remove("screenshots/test_md_preview.png")
        os.rename("screenshots/screenshot_active.png", "screenshots/test_md_preview.png")
    
    print("Test finished. Check screenshots/test_md_preview.png")

if __name__ == "__main__":
    test_md_preview()
