#!/usr/bin/env python3
"""
Vulkan-Editor Visual Debugging Interface

Usage:
    python3 vscreenshot.py "Frage an Gemini"
    python3 vscreenshot.py --interactive

Commands (interactive mode):
    s <frage>  - Screenshot + Gemini Frage
    r <method> - RPC call (z.B. r open_file <path>)
    q           - Quit

Examples:
    python3 vscreenshot.py "siehst du syntax highlighting im md-preview?"
    python3 vscreenshot.py --interactive
"""

import json
import socket
import subprocess
import sys
import os
import time
import tempfile
import argparse
from pathlib import Path

# === Config ===
HOST = "127.0.0.1"
PORT = 9999
REPO_ROOT = Path(__file__).parent.parent.resolve()
ZIG_BUILD = REPO_ROOT / "zig-out" / "bin" / "vulkan-ed"
TMP_DIR = REPO_ROOT / "tmp"
TMP_DIR.mkdir(exist_ok=True)

# === RPC Helper ===
def rpc_call(method: str, params: list = None) -> dict:
    """Send RPC call to vulkan-ed, return response."""
    if params is None:
        params = []

    payload = {
        "jsonrpc": "2.0",
        "method": method,
        "params": params,
        "id": 1
    }

    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(30)  # Increased timeout for screenshot
        s.connect((HOST, PORT))
        s.sendall((json.dumps(payload) + "\n").encode())
        # Wait for response with retry logic
        response = b""
        start = time.time()
        while time.time() - start < 30:
            try:
                chunk = s.recv(4096)
                if not chunk:
                    break
                response += chunk
                try:
                    return json.loads(response.decode())
                except json.JSONDecodeError:
                    continue
            except socket.timeout:
                # Check if we got anything
                if response:
                    try:
                        return json.loads(response.decode())
                    except:
                        pass
                time.sleep(0.1)
        # If we still have partial response, try to parse it
        if response:
            try:
                return json.loads(response.decode())
            except json.JSONDecodeError:
                return {"error": "incomplete JSON", "raw": response.decode(errors="replace")}
        return {"error": "no response received"}
    except Exception as e:
        return {"error": str(e)}

def wait_for_server(timeout: int = 15) -> bool:
    """Wait for RPC server to be ready."""
    start = time.time()
    while time.time() - start < timeout:
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
                s.settimeout(1)
                s.connect((HOST, PORT))
                return True
        except ConnectionRefusedError:
            time.sleep(0.5)
    return False

# === Screenshot ===
def take_screenshot(timeout: float = 10.0) -> tuple[bool, Path]:
    """Take screenshot via RPC, retry until success or timeout."""
    start = time.time()
    while time.time() - start < timeout:
        response = rpc_call("screenshot")
        if response and "result" in response:
            ppm_path = REPO_ROOT / response["result"]
            if ppm_path.exists() and ppm_path.stat().st_size > 0:
                return True, ppm_path
        time.sleep(0.2)
    return False, None

def convert_ppm_to_png(ppm_path: Path) -> Path | None:
    """Convert PPM to PNG using ImageMagick."""
    png_path = ppm_path.with_suffix(".png")
    try:
        subprocess.run(
            ["convert", str(ppm_path), str(png_path)],
            check=True,
            capture_output=True
        )
        return png_path
    except subprocess.CalledProcessError:
        return None

# === Gemini ===
def query_gemini(png_path: Path, question: str) -> str:
    """Send image + question to Gemini CLI."""
    prompt = f"""IMAGE: {png_path}

Frage: {question}

Antworte auf Deutsch. Beschreibe detailliert was du siehst, besonders:
- UI Layout und Struktur
- Farben und Styling
- Code-Blöcke und Syntax-Highlighting
- Etwaige Bugs oder Probleme"""

    try:
        result = subprocess.run(
            ["gemini", "-p", prompt, "--yolo"],
            capture_output=True,
            text=True,
            timeout=60
        )
        return result.stdout if result.returncode == 0 else f"Error: {result.stderr}"
    except subprocess.TimeoutExpired:
        return "Error: Gemini timeout"
    except FileNotFoundError:
        return "Error: Gemini CLI not found"

# === Interactive Mode ===
def interactive_mode():
    """Interactive mode for taking multiple screenshots."""
    print("=== Vulkan Visual Debugger ===")
    print("Commands:")
    print("  s <frage>  - Screenshot + Gemini Frage")
    print("  r <method> [args...] - RPC call")
    print("  q           - Quit")
    print()

    # Build and start vulkan-ed
    print("[*] Building vulkan-ed...")
    build_result = subprocess.run(
        ["zig", "build", "-Doptimize=ReleaseSafe"],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True
    )
    if build_result.returncode != 0:
        print(f"[-] Build failed:\n{build_result.stderr[-500:]}")
        return 1

    print("[*] Starting vulkan-ed in headless mode...")
    proc = subprocess.Popen(
        [str(ZIG_BUILD), "--headless"],
        cwd=REPO_ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE
    )

    print("[*] Waiting for RPC server...")
    if not wait_for_server():
        print("[-] RPC server not responding")
        proc.terminate()
        return 1

    print("[+] RPC server ready!")
    print()

    while True:
        try:
            line = input("> ").strip()
        except (EOFError, KeyboardInterrupt):
            line = "q"

        if not line:
            continue

        parts = line.split(None, 1)
        cmd = parts[0].lower()

        if cmd == "q":
            break

        elif cmd == "s":
            if len(parts) < 2:
                print("Usage: s <frage>")
                continue

            question = parts[1]
            print("[*] Taking screenshot...")
            success, ppm_path = take_screenshot()
            if not success:
                print(f"[-] Screenshot failed: {rpc_call('screenshot')}")
                continue

            print(f"[+] Screenshot: {ppm_path}")

            print("[*] Converting to PNG...")
            png_path = convert_ppm_to_png(ppm_path)
            if not png_path:
                print("[-] PNG conversion failed (is ImageMagick installed?)")
                continue

            print(f"[+] PNG: {png_path}")

            print("[*] Querying Gemini...")
            answer = query_gemini(png_path, question)
            print("\n--- Gemini Response ---")
            print(answer)
            print("--- End ---\n")

        elif cmd == "r":
            if len(parts) < 2:
                print("Usage: r <method> [args...]")
                continue

            method_parts = parts[1].split()
            method = method_parts[0]
            args = method_parts[1:]

            # Parse int args
            parsed_args = []
            for a in args:
                try:
                    parsed_args.append(int(a))
                except ValueError:
                    parsed_args.append(a)

            print(f"[*] RPC: {method}({parsed_args})")
            response = rpc_call(method, parsed_args)
            print(f"[+] Response: {response}")

        else:
            print(f"Unknown command: {cmd}")
            print("Commands: s, r, q")

    print("[*] Shutting down...")
    proc.terminate()
    proc.wait(timeout=5)
    print("[+] Done")
    return 0

# === One-shot Mode ===
def oneshot_mode(question: str):
    """One-shot: build, screenshot, Gemini, exit."""
    print("[*] Building vulkan-ed...")
    build_result = subprocess.run(
        ["zig", "build", "-Doptimize=ReleaseSafe"],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True
    )
    if build_result.returncode != 0:
        print(f"[-] Build failed:\n{build_result.stderr[-500:]}")
        return 1

    print("[*] Starting vulkan-ed in headless mode...")
    proc = subprocess.Popen(
        [str(ZIG_BUILD), "--headless"],
        cwd=REPO_ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE
    )

    print("[*] Waiting for RPC server...")
    if not wait_for_server():
        print("[-] RPC server not responding")
        proc.terminate()
        return 1

    print("[+] RPC server ready!")

    # Small delay to ensure server is truly ready for RPC
    time.sleep(0.5)

    print("[*] Taking screenshot...")
    success, ppm_path = take_screenshot()
    if not success:
        print(f"[-] Screenshot failed")
        proc.terminate()
        return 1

    print(f"[+] Screenshot: {ppm_path}")

    print("[*] Converting to PNG...")
    png_path = convert_ppm_to_png(ppm_path)
    if not png_path:
        print("[-] PNG conversion failed")
        proc.terminate()
        return 1

    print(f"[+] PNG: {png_path}")

    print("[*] Querying Gemini...")
    answer = query_gemini(png_path, question)

    proc.terminate()
    proc.wait(timeout=5)

    print("\n--- Gemini Response ---")
    print(answer)
    print("--- End ---\n")

    return 0

# === Main ===
def main():
    parser = argparse.ArgumentParser(description="Vulkan Visual Debugger")
    parser.add_argument("question", nargs="?", help="Question for Gemini (one-shot mode)")
    parser.add_argument("-i", "--interactive", action="store_true", help="Interactive mode")
    args = parser.parse_args()

    if args.interactive or not args.question:
        return interactive_mode()
    else:
        return oneshot_mode(args.question)

if __name__ == "__main__":
    sys.exit(main() or 0)
