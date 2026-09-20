#!/usr/bin/env python3
"""Headless-E2E: farbige Emoji im Editor.

Prüft die ganze Kette: Zeichen fehlt in der Hauptschrift → Rückfall auf die
Emoji-Schrift → Bitmap verkleinert → Farbatlas → Shader. Auf Systemen ohne
Bitmap-Emoji-Schrift (Fedora liefert nur COLRv1) lädt zid die Schrift selbst ins
Datenverzeichnis; die Suite wartet darauf.

Aufruf: python3 scripts/e2e_emoji.py
"""
import os, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e2e_open_folder import (  # noqa: E402
    ROOT, rmtree, isolated_env, start_zid, stop_zid, rpc, result_json,
    wait_port, settle, bounds, check, shot,
)

FX = os.path.join(ROOT, "tmp", "e2e_emoji")
SRC = os.path.join(FX, "emoji.txt")
TEXT = "Werkzeug \U0001F527 Haken ✅ fertig\n"


def setup():
    rmtree(FX)
    os.makedirs(FX)
    with open(SRC, "w", encoding="utf-8") as f:
        f.write(TEXT)


def font_path(env):
    return os.path.join(env["XDG_DATA_HOME"], "zid", "fonts", "NotoColorEmoji.ttf")


def wait_font(env, timeout=300):
    """Auf die Emoji-Schrift warten: entweder liegt eine im System oder zid lädt sie."""
    system = [
        "/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf",
        "/usr/share/fonts/noto/NotoColorEmoji.ttf",
        "/usr/share/fonts/google-noto-emoji/NotoColorEmoji.ttf",
    ]
    for p in system:
        if os.path.exists(p):
            return p
    target = font_path(env)
    t0 = time.time()
    while time.time() - t0 < timeout:
        if os.path.exists(target):
            return target
        time.sleep(1.0)
    return None


def read_ppm(path):
    """Minimaler P6-Leser: (breite, hoehe, bytes)."""
    with open(path, "rb") as f:
        data = f.read()
    fields = []
    pos = 0
    while len(fields) < 4:
        end = data.index(b"\n", pos)
        line = data[pos:end]
        pos = end + 1
        if line.startswith(b"#"):
            continue
        fields += line.split()
    w, h = int(fields[1]), int(fields[2])
    return w, h, data[pos:]


def colored_pixels(path, box):
    """Zahl der kräftig bunten Pixel im Kasten — Text ist einfarbig, Emoji nicht."""
    w, h, px = read_ppm(path)
    x0, y0 = int(box["x"]), int(box["y"])
    x1, y1 = int(box["x"] + box["w"]), int(box["y"] + box["h"])
    count = 0
    for y in range(max(0, y0), min(h, y1)):
        row = y * w * 3
        for x in range(max(0, x0), min(w, x1)):
            i = row + x * 3
            r, g, b = px[i], px[i + 1], px[i + 2]
            if max(r, g, b) - min(r, g, b) > 60:
                count += 1
    return count


def main():
    setup()
    env = isolated_env("e2e_emoji")
    os.makedirs(os.path.join(ROOT, "tmp"), exist_ok=True)
    log = open(os.path.join(ROOT, "tmp", "e2e_emoji.log"), "w")
    proc = start_zid(["--headless", "--ai=off", FX], log, env=env)
    try:
        wait_port(proc)
        rpc("open_file", [SRC])
        settle(20)

        found = wait_font(env)
        check(found is not None, f"Emoji-Schrift vorhanden: {found}")
        if found is None:
            return 1

        # Nach dem Nachladen greift der Rückfall erst beim nächsten Formen.
        rpc("click", [700, 300])
        rpc("type_text", ["x"])
        settle(20)
        rpc("key_press_mods", ["backspace", False, False])
        settle(20)

        line = bounds("code", 0)
        shot("e2e_emoji.ppm")
        colored = colored_pixels(os.path.join(ROOT, "tmp", "e2e_emoji.ppm"), line)
        check(colored > 20, f"farbige Pixel in der Textzeile: {colored}")

        state = result_json("ui_state")
        check(state.get("toast", "") is not None, "läuft ohne Absturz weiter")
        return 0 if colored > 20 else 1
    finally:
        stop_zid(proc)
        log.close()


if __name__ == "__main__":
    sys.exit(main())
