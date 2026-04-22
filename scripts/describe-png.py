#!/usr/bin/env python3
"""Describe PNG images using Ollama vision model.
Usage: python3 describe-png.py <png_path> [prompt]
If prompt is omitted, uses default: "Beschreibe was du siehst."
"""
import sys
import os
import http.client
import json
import subprocess
import time
import socket

OLLAMA_HOST = "localhost"
OLLAMA_PORT = 11434
MODEL = "gemma4:e2b"


def start_ollama():
    """Start ollama server if not running."""
    try:
        conn = http.client.HTTPConnection(OLLAMA_HOST, OLLAMA_PORT, timeout=2)
        conn.request("GET", "/")
        conn.getresponse()
        print("[describe-png] Ollama already running", file=sys.stderr)
        return True
    except (socket.error, ConnectionRefusedError):
        pass

    print("[describe-png] Starting ollama server...", file=sys.stderr)
    subprocess.Popen(["ollama", "serve"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for i in range(30):
        try:
            conn = http.client.HTTPConnection(OLLAMA_HOST, OLLAMA_PORT, timeout=2)
            conn.request("GET", "/")
            conn.getresponse()
            print(f"[describe-png] Ollama started after {i+1}s", file=sys.stderr)
            return True
        except (socket.error, ConnectionRefusedError):
            time.sleep(1)
    print("[describe-png] WARNING: Ollama did not start in time", file=sys.stderr)
    return False


def load_image_as_base64(path):
    """Load PNG as base64."""
    import base64
    with open(path, "rb") as f:
        return base64.b64encode(f.read()).decode("ascii")


def describe_png(png_path: str, prompt: str) -> str:
    """Send PNG to Ollama vision model and return description."""
    import base64

    image_b64 = load_image_as_base64(png_path)

    payload = {
        "model": MODEL,
        "messages": [
            {
                "role": "user",
                "content": prompt,
                "images": [image_b64]
            }
        ],
        "stream": False
    }

    body = json.dumps(payload).encode("utf-8")
    headers = {
        "Content-Type": "application/json",
        "Authorization": "Bearer dummy"  # Ollama doesn't need auth but server wants header
    }

    conn = http.client.HTTPConnection(OLLAMA_HOST, OLLAMA_PORT)
    try:
        conn.request("POST", "/api/chat", body, headers)
        resp = conn.getresponse()
        data = json.loads(resp.read().decode("utf-8"))
        return data["message"]["content"]
    finally:
        conn.close()


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 describe-png.py <png_path> [prompt]")
        print("Example: python3 describe-png.py /tmp/screenshot.png 'Siehst du einen Cursor?'")
        sys.exit(1)

    png_path = sys.argv[1]
    prompt = sys.argv[2] if len(sys.argv) > 2 else "Beschreibe was du siehst."

    if not os.path.exists(png_path):
        print(f"Error: File not found: {png_path}", file=sys.stderr)
        sys.exit(1)

    if not start_ollama():
        print("Error: Could not start Ollama", file=sys.stderr)
        sys.exit(1)

    print(f"[describe-png] Sending {png_path} to {MODEL}...", file=sys.stderr)
    result = describe_png(png_path, prompt)
    print(result)
