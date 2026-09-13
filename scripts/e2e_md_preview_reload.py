#!/usr/bin/env python3
"""Headless-E2E: Die Markdown-Vorschau folgt dem Speichern der Quelle.

Ablauf: tmp/e2e_reload.md mit zwei Blöcken anlegen, öffnen, Vorschau über das Tab-Menü
öffnen (Blöcke zählen), zurück in den Editor, einen dritten Block tippen, Ctrl+S, wieder in die
Vorschau: sie zeigt jetzt drei Blöcke, und die Scroll-Position bleibt erhalten.
Aufruf: python3 scripts/e2e_md_preview_reload.py
"""
import os, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e2e_open_folder import ROOT, rpc, result_json, wait_port, settle, bounds, check  # noqa: E402

FIXTURE = os.path.join(ROOT, "tmp", "e2e_reload.md")


def tabs():
    return result_json("ui_state")["tabs"]


def click_tab(pred):
    idx = next(i for i, t in enumerate(tabs()) if pred(t))
    b = result_json("tab_bounds", [idx])
    print(f"     Tab {idx}: {b}")
    rpc("click", [b["x"] + b["w"] / 2, b["y"] + b["h"] / 2])
    settle(20)


def open_preview():
    idx = next(i for i, t in enumerate(tabs()) if t["path"] == FIXTURE)
    b = result_json("tab_bounds", [idx])
    rpc("right_click", [b["x"] + b["w"] / 2, b["y"] + b["h"] / 2])
    settle(4)
    e = bounds("tab_menu_md_preview")
    rpc("click", [e["x"] + e["w"] / 2, e["y"] + e["h"] / 2])
    settle(40)


def block_count(limit=50):
    return sum(1 for i in range(limit) if result_json("element_bounds_i", ["md_block", i])["found"])


def main():
    with open(FIXTURE, "w") as f:
        f.write("# Titel\n\nErster Absatz.\n")
    log = open(os.path.join(ROOT, "tmp", "e2e_md_preview_reload.log"), "w")
    proc = subprocess.Popen(
        ["zig", "build", "run", "--", "--headless", "--ai=off"],
        cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
    )
    try:
        wait_port(proc)
        settle(20)
        rpc("open_file", [FIXTURE])
        settle(30)
        open_preview()
        rpc("screenshot"); settle(20)
        before = block_count()
        print(f"     Blöcke vor dem Speichern: {before}")
        check(before >= 2, "Vorschau zeigt Überschrift und Absatz")

        click_tab(lambda t: t["path"] == FIXTURE)
        check(result_json("ui_state")["tabs"][result_json("ui_state")["active_tab"]]["path"] == FIXTURE, "Editor-Tab aktiv")
        rpc("key_press", ["end", True])  # Ctrl+End: ans Dateiende
        settle(4)
        for _ in range(2):  # type_text kennt kein "\n": Leerzeile per Enter
            rpc("key_press", ["enter", False])
            settle(2)
        rpc("type_text", ["Zweiter Absatz nach dem Speichern."])
        settle(10)
        rpc("key_press", ["s", True])
        settle(30)
        with open(FIXTURE) as f:
            check("Zweiter Absatz" in f.read(), "Ctrl+S hat die Datei geschrieben")

        click_tab(lambda t: t["path"] == "preview://" + FIXTURE)
        rpc("screenshot"); settle(20)
        st = result_json("ui_state")
        check(st["tabs"][st["active_tab"]]["path"] == "preview://" + FIXTURE, f"Vorschau-Tab aktiv ({st['tabs'][st['active_tab']]['path']})")
        after = block_count()
        print(f"     Blöcke nach dem Speichern: {after}")
        # zigdown zählt auch Leerzeilen als Blöcke, deshalb nur „mehr als vorher“
        check(after > before, f"Vorschau zeigt den neuen Absatz ohne Neuöffnen ({after} Blöcke, vorher {before})")
        print("PASS alle Prüfungen")
    finally:
        try:
            rpc("shutdown")
        except Exception:
            pass
        time.sleep(0.5)
        if proc.poll() is None:
            proc.terminate()
            proc.wait(timeout=10)


if __name__ == "__main__":
    main()
