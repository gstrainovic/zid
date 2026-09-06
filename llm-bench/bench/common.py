"""Hilfsfunktionen ohne Fremdabhängigkeiten (nur Standardbibliothek)."""

import json
import re
import urllib.error
import urllib.request

_FENCE_OPEN = re.compile(r"^```[a-zA-Z]*\s*", re.S)
_FENCE_CLOSE = re.compile(r"\s*```\s*$", re.S)
_FIRST_OBJECT = re.compile(r"\{.*\}", re.S)


def chat(port, system, user, max_tokens=300, temperature=0.2, timeout=900):
    """Ein Aufruf gegen den OpenAI-kompatiblen Endpunkt von llama-server.

    Gibt (text, prompt_tokens, completion_tokens) zurück.
    """
    payload = {
        "model": "local",
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        "temperature": temperature,
        "max_tokens": max_tokens,
        "stream": False,
    }
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}/v1/chat/completions",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        body = json.loads(resp.read().decode("utf-8"))
    usage = body.get("usage", {})
    return (
        body["choices"][0]["message"]["content"],
        usage.get("prompt_tokens", 0),
        usage.get("completion_tokens", 0),
    )


def wait_for_server(port, attempts=60, delay=2.0):
    """Wartet, bis /health ok meldet. True, wenn der Server bereit ist."""
    import time

    for _ in range(attempts):
        try:
            with urllib.request.urlopen(
                f"http://127.0.0.1:{port}/health", timeout=5
            ) as resp:
                if json.loads(resp.read().decode("utf-8")).get("status") == "ok":
                    return True
        except (urllib.error.URLError, OSError, ValueError):
            pass
        time.sleep(delay)
    return False


def extract_tool(text):
    """Zieht den Werkzeugnamen aus einer Antwort.

    Gibt (ist_gueltiges_json, werkzeugname_oder_None) zurück. Markdown-Zaeune
    werden vorher entfernt, damit ein Modell nicht allein am ```json scheitert.
    """
    clean = _FENCE_CLOSE.sub("", _FENCE_OPEN.sub("", text.strip()))
    match = _FIRST_OBJECT.search(clean)
    if not match:
        return False, None
    try:
        obj = json.loads(match.group(0))
    except (json.JSONDecodeError, ValueError):
        return False, None
    if not isinstance(obj, dict):
        return False, None
    tool = obj.get("tool")
    return True, tool if isinstance(tool, str) else None


def shorten(text, width=110):
    flat = " ".join(text.split())
    return flat if len(flat) <= width else flat[:width] + "..."
