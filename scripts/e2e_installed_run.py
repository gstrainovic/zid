#!/usr/bin/env python3
"""Headless-E2E: zid laeuft ohne das Quellverzeichnis.

Ein installiertes zid steht irgendwo im PATH, das Arbeitsverzeichnis ist das des
Benutzers. Frueher las zid Schrift und Logo ueber relative Pfade (`fonts/…`,
`assets/…`) und brach ausserhalb des Repos mit FileNotFound ab. Der Test startet
das Binary aus einem leeren Ordner und prueft, dass es hochkommt, Glyphen
rastert und einen Screenshot liefert.

Aufruf: python3 scripts/e2e_installed_run.py
"""
import os
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e2e_open_folder import (  # noqa: E402
    ROOT, ZID, rpc, result_json, wait_port, settle, check, isolated_env, stop_zid,
)
import subprocess  # noqa: E402

WORKDIR = os.path.join(ROOT, "tmp", "e2e_installed_cwd")
LOG = os.path.join(ROOT, "tmp", "e2e_installed_run.log")


def main():
    shutil.rmtree(WORKDIR, ignore_errors=True)
    # Der Screenshot-RPC schreibt nach ./tmp und legt den Ordner nicht an.
    os.makedirs(os.path.join(WORKDIR, "tmp"))
    env = isolated_env("e2e_installed_run")
    with open(LOG, "w") as log:
        build_args = os.environ.get("ZID_BUILD_ARGS", "").split()
        build = subprocess.run(["zig", "build"] + build_args, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, env=env)
        if build.returncode != 0:
            raise RuntimeError(f"zig build fehlgeschlagen, siehe {LOG}")
        log.flush()
        # Fremdes, leeres Arbeitsverzeichnis: kein fonts/, kein assets/
        proc = subprocess.Popen([ZID, "--headless", "--ai=off"], cwd=WORKDIR,
                                stdout=log, stderr=subprocess.STDOUT, env=env)
        try:
            wait_port(proc)
            settle(20)
            # Headless rastert erst beim Rendern: Screenshot zuerst, dann messen.
            rpc("screenshot")
            settle(10)
            # Der Screenshot-RPC schreibt nach tmp/ im Arbeitsverzeichnis von zid.
            shot = os.path.join(WORKDIR, "tmp", "vulkan-screenshot.ppm")
            check(os.path.getsize(shot) > 1000, "Screenshot geschrieben")
            st = result_json("ui_state")
            check(st["glyph_rasterized"] > 0, f"Schrift geladen ({st['glyph_rasterized']} Glyphen)")
            check(st["clay_errors"] == 0, f"keine Clay-Fehler ({st['clay_errors']})")
        finally:
            stop_zid(proc)

    with open(LOG, encoding="utf-8", errors="replace") as f:
        text = f.read()
    check("FileNotFound" not in text, "kein FileNotFound im Log")
    print("ALL PASSED")


if __name__ == "__main__":
    main()
