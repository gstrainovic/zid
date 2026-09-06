#!/usr/bin/env python3
"""Headless-E2E: große und merkwürdige Dateien dürfen den Editor nicht abschießen.

Legt unter tmp/ eine Binärdatei ohne Zeilenumbruch (ungültiges UTF-8, NUL-Bytes),
eine Datei mit 5000-Zeichen-Zeile und eine 5-MB-Textdatei an, öffnet sie headless
(--headless --ai=off), bewegt den Cursor, tippt, macht Screenshots und prüft, dass
der Prozess sauber beendet. Aufruf: python3 scripts/e2e_odd_files.py

Grenze: headless rendert keinen GPU-Text; der 256-Glyphen-Absturz in
gpu_renderer.renderText ist nur per Unit-Test (glyph_layout.zig) abgedeckt.
"""
import os, random, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e2e_open_folder import ROOT, rpc, result_json, wait_port, settle, check, shot  # noqa: E402

TMP = os.path.join(ROOT, "tmp")


def make_fixtures():
    os.makedirs(TMP, exist_ok=True)
    rnd = random.Random(7)
    binary = bytes(rnd.randrange(256) for _ in range(3000)).replace(b"\n", b"\x00")
    with open(os.path.join(TMP, "odd_binary.bin"), "wb") as f:
        f.write(binary)
    with open(os.path.join(TMP, "odd_long_line.txt"), "w") as f:
        f.write("x" * 5000 + "\n" + "abc " * 150 + "\n" + "kurz\n")
    with open(os.path.join(TMP, "odd_big.txt"), "w") as f:
        for i in range(100_000):
            f.write(f"line {i:06d} " + "lorem ipsum dolor sit amet " + "\n")
    return ["odd_binary.bin", "odd_long_line.txt", "odd_big.txt"]


def open_and_poke(name):
    path = os.path.join(TMP, name)
    t0 = time.time()
    rpc("open_file", [path])
    tab = {}
    while time.time() - t0 < 30:
        tab = result_json("get_active_tab")
        if tab.get("editor_file") == path:
            break
        time.sleep(0.05)
    check(tab.get("editor_file") == path, f"{name}: Editor zeigt die Datei nach {time.time() - t0:.2f}s")
    for k in ("end", "down", "down", "right"):
        rpc("key_press", [k, False])
    rpc("key_press", ["end", True])
    settle()
    t1 = time.time()
    rpc("type_text", ["Z"])
    st = {}
    while time.time() - t1 < 30:
        st = result_json("editor_state")
        if "Z" in st.get("text", ""):
            break
        time.sleep(0.05)
    check("Z" in st.get("text", ""), f"{name}: getipptes Zeichen sichtbar nach {time.time() - t1:.2f}s")
    check(st["lines"] >= 1, f"{name}: Editor meldet {st['lines']} Zeilen, Cursor {st.get('cursor')}")
    shot(f"e2e_odd_{name}.ppm")
    check(os.path.getsize(os.path.join(TMP, f"e2e_odd_{name}.ppm")) > 1000, f"{name}: Screenshot geschrieben")
    if name == "odd_long_line.txt":
        # Riesenzeile: Ansicht folgt dem Cursor horizontal, Ausschnitt statt ganzer Zeile
        rpc("key_press", ["home", True]); settle()
        st = result_json("editor_state")
        check(st["view_col"] == 0 and st["view_cols"] > 20, f"Ctrl+Home: view_col 0, {st['view_cols']} sichtbare Spalten")
        rpc("key_press", ["end", False]); settle()
        st = result_json("editor_state")
        check(st["view_col"] > 0 and st["col"] >= st["view_col"], f"End auf der 5000er-Zeile scrollt horizontal (view_col {st['view_col']})")
        shot("e2e_odd_long_line_end.ppm")


def check_binary_tab():
    """Binärdatei: Hinweis-Tab statt Editor, kein Buffer, Tippen ändert nichts."""
    path = os.path.join(TMP, "odd_binary.bin")
    before = result_json("get_active_tab")["editor_file"]
    rpc("open_file", [path])
    tab = {}
    t0 = time.time()
    while time.time() - t0 < 10:
        tab = result_json("get_active_tab")
        if any(t["name"] == "odd_binary.bin" for t in tab["tabs"]):
            break
        time.sleep(0.05)
    kinds = {t["name"]: t["kind"] for t in tab["tabs"]}
    check(kinds.get("odd_binary.bin") == "binary", f"odd_binary.bin ist ein Binär-Tab ({kinds.get('odd_binary.bin')})")
    settle(10)
    tab = result_json("get_active_tab")
    check(tab["editor_file"] == before, f"Editor-Buffer unverändert ({os.path.basename(tab['editor_file'])})")
    rpc("type_text", ["Z"])
    settle(10)
    tab = result_json("get_active_tab")
    check(not any(t["modified"] for t in tab["tabs"]), "Tippen macht keinen Tab dirty")
    shot("e2e_odd_binary_tab.ppm")


def main():
    names = make_fixtures()
    log = open(os.path.join(TMP, "e2e_odd_files.log"), "w")
    proc = subprocess.Popen(
        ["zig", "build", "run", "--", "--headless", "--ai=off"],
        cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
    )
    try:
        wait_port(proc)
        settle(20)
        check_binary_tab()
        for name in names[1:]:
            open_and_poke(name)
        state = result_json("ui_state")
        check(len(state["tabs"]) >= 3, f"{len(state['tabs'])} Tabs offen")
        try:
            rpc("shutdown")  # antwortet nicht mit JSON, Prozess beendet sich
        except Exception:
            pass
        code = proc.wait(timeout=30)
        check(code == 0, f"Prozess beendet sauber (Code {code})")
    finally:
        if proc.poll() is None:
            proc.kill()
        log.close()
    print("OK")


if __name__ == "__main__":
    main()
