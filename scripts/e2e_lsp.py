#!/usr/bin/env python3
"""Headless-E2E: Sprung zur Definition über zls (LSP) in eine andere Datei.

Fixture: tmp/e2e_lsp mit a.zig (helper) und main.zig (ruft a.helper()). F12 auf `helper`
startet zls beim ersten Mal (Rückfall auf die Textmuster-Suche, solange zls noch nicht
bereit ist), danach öffnet der Sprung a.zig mit dem Cursor auf `helper`.
Braucht zls (ZLS_PATH, ~/.local/bin/zls oder im PATH). Aufruf: python3 scripts/e2e_lsp.py
"""
import os, shutil, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e2e_open_folder import ROOT, rpc, result_json, wait_port, settle, check  # noqa: E402
from e2e_shortcuts import key  # noqa: E402

FX = os.path.join(ROOT, "tmp", "e2e_lsp")
MAIN = os.path.join(FX, "main.zig")
A = os.path.join(FX, "a.zig")


def ed():
    return result_json("editor_state")


def ui():
    return result_json("ui_state")


def active_file():
    return result_json("get_active_tab")["editor_file"]


def setup():
    shutil.rmtree(FX, ignore_errors=True)
    os.makedirs(FX)
    with open(A, "w") as f:
        f.write("pub fn helper() void {}\n")
    with open(MAIN, "w") as f:
        f.write('const a = @import("a.zig");\n\npub fn main() void {\n    a.helper();\n}\n')
    time.sleep(0.3)


def wait_for(cond, what, timeout):
    t0 = time.time()
    while time.time() - t0 < timeout:
        if cond():
            check(True, f"{what} ({time.time() - t0:.1f}s)")
            return True
        time.sleep(0.1)
    check(False, what)
    return False


def main():
    setup()
    log = open(os.path.join(ROOT, "tmp", "e2e_lsp.log"), "w")
    env = dict(os.environ, XDG_DATA_HOME=os.path.join(ROOT, "tmp", "xdg"), XDG_CONFIG_HOME=os.path.join(ROOT, "tmp", "xdg-config"))
    proc = subprocess.Popen([os.path.join(ROOT, "zig-out", "bin", "zid"), "--headless", "--ai=off"],
                            cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, env=env)
    try:
        wait_port(proc)
        settle(20)
        rpc("open_folder", [FX]); settle(15)
        rpc("open_file", [MAIN]); settle(15)
        check(active_file() == MAIN, "main.zig ist offen")
        check(ui()["lsp"] == "off", "zls läuft noch nicht")
        rpc("click", [700, 300]); settle()
        key("g", ctrl=True); rpc("type_text", ["4"]); settle(); key("enter")
        key("end")
        for _ in range(4):
            key("left")
        st = ed()
        check(st["row"] == 3 and st["col"] == 11, f"Cursor steht in `helper` (Zeile {st['row'] + 1}, Spalte {st['col']})")
        key("f12")
        wait_for(lambda: ui()["lsp"] in ("starting", "ready"), "erstes F12 startet zls", 5)
        check(active_file() == MAIN, "ohne bereiten Server bleibt es bei main.zig (lokal gibt es keine Definition)")
        wait_for(lambda: ui()["lsp"] == "ready", "zls ist initialisiert", 20)
        key("f12")
        wait_for(lambda: active_file() == A, "F12 öffnet a.zig", 30)
        wait_for(lambda: ed()["row"] == 0 and ed()["col"] == 7, "Cursor steht auf `helper` in a.zig", 10)
        # Zurück in main.zig: Sprung innerhalb derselben Datei (main → Definition in Zeile 3)
        rpc("open_file", [MAIN]); settle(15)
        key("g", ctrl=True); rpc("type_text", ["4"]); settle(); key("enter")
        key("home")
        for _ in range(5):
            key("right")
        key("f12")
        wait_for(lambda: active_file() == A, "F12 auf `a` springt zur Import-Datei", 15)
        print("ALL PASSED")
    finally:
        try:
            rpc("shutdown")
        except Exception:
            pass
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
        log.close()


if __name__ == "__main__":
    main()
