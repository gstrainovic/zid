#!/usr/bin/env python3
"""Headless-Repro für Use-after-free im Text der Render-Commands.

Fährt Ordnerwechsel in einen erzeugten Baum unter tmp/e2e_uaf, Bilder aus dem Explorer
(per Klick und per RPC), Tooltip-Hover, Picker (Ctrl+P / Ctrl+E) mit Mausklick,
Tab-Wechsel und Tab-Schließen.
Mit `--page-alloc` meldet die Text-Probe im Headless-Loop jeden Render-Command, dessen
Text auf freigegebenen Speicher zeigt, samt Stack-Trace der Freigabe.
Aufruf: python3 scripts/e2e_repro_text_uaf.py [--page-alloc] [--ai=on]
"""
import os, shutil, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e2e_fixtures import write_png
from e2e_open_folder import rpc, result_json, wait_port, settle, click_center, start_zid, stop_zid, ROOT

TREE = os.path.join(ROOT, "tmp", "e2e_uaf")
ROOT_NAME = os.path.basename(TREE)
JOBS_NAME = "bilder"
IMG_SUBDIR = "portraits"
JOBS_DIR = os.path.join(TREE, JOBS_NAME, IMG_SUBDIR)
IMAGES = ["portrait-hoch.png", "portrait-quadrat.png"]

PROC = None
LOG_PATH = os.path.join(ROOT, "tmp", "e2e_repro_text_uaf.log")


def make_tree():
    """Baum mit Bildern und genug Nachbarordnern, dass der Explorer scrollen muss."""
    shutil.rmtree(TREE, ignore_errors=True)
    write_png(os.path.join(JOBS_DIR, IMAGES[0]), 120, 160)
    write_png(os.path.join(JOBS_DIR, IMAGES[1]), 128, 128)
    with open(os.path.join(TREE, JOBS_NAME, "notizen.md"), "w", encoding="utf-8") as f:
        f.write("# Notizen\n")
    for i in range(30):
        sub = os.path.join(TREE, f"ordner-{i:02d}", "unter")
        os.makedirs(sub)
        with open(os.path.join(sub, "datei.txt"), "w") as f:
            f.write(f"{i}\n")


def alive(what):
    if PROC.poll() is not None:
        print(f"CRASH nach: {what} (exit {PROC.returncode})")
        print(open(LOG_PATH, errors="replace").read()[-8000:])
        sys.exit(1)
    print("ok:", what)


def key(name, ctrl=False):
    rpc("key_press", [name, ctrl])


def explorer_rows():
    e = result_json("explorer_entries")
    return e, e["viewport"], e["row_height"], e["scroll"]


def row_center(e, vp, rh, sc, name):
    for row in e["entries"]:
        if row.get("name") == name:
            y = vp["y"] + row["index"] * rh + rh / 2 - sc
            if vp["y"] <= y <= vp["y"] + vp["h"]:
                return vp["x"] + 80, y
    raise AssertionError(f"Explorer-Zeile {name!r} nicht sichtbar")


def locate_row(name, max_scroll=40):
    """Zeile suchen, bei Bedarf schrittweise nach unten scrollen."""
    for _ in range(max_scroll):
        e, vp, rh, sc = explorer_rows()
        try:
            return row_center(e, vp, rh, sc, name)
        except AssertionError:
            rpc("scroll", [vp["x"] + 60, vp["y"] + 100, -5]); settle(8)
    e, vp, rh, sc = explorer_rows()
    st = result_json("ui_state")
    raise AssertionError(
        f"Explorer-Zeile {name!r} nicht gefunden; sichtbar: {[r['name'] for r in e['entries']]} "
        f"scroll={sc} viewport={vp} explorer_shown={st.get('explorer_visible')} dialog={st.get('dialog')}"
    )


def open_folder(target_input, target):
    click_center("menu_file")
    click_center("menu_item_open_folder")
    picker = result_json("folder_picker_state")
    for _ in range(len(picker["path"])):
        key("backspace")
    rpc("type_text", [target_input])
    settle()
    key("enter")
    settle(40)
    alive("open folder")
    state = result_json("get_state")
    assert state["root"] == target, state["root"]


def scroll_top():
    e, vp, rh, sc = explorer_rows()
    while sc > 0:
        rpc("scroll", [vp["x"] + 60, vp["y"] + 100, 20]); settle(5)
        e, vp, rh, sc = explorer_rows()


def ensure_expanded(name):
    """Ordnerzeile aufklappen, falls zu; Klick auf einen offenen Ordner würde ihn schließen."""
    x, y = locate_row(name)
    e, vp, rh, sc = explorer_rows()
    row = next(r for r in e["entries"] if r.get("name") == name)
    if not row["expanded"]:
        rpc("click", [x, y]); settle(30)
    alive("expand " + name)


def scenario_explorer_clicks():
    scroll_top()
    ensure_expanded(ROOT_NAME)  # Root kann nach Tastatur-Kürzeln zugeklappt sein
    ensure_expanded(JOBS_NAME)
    ensure_expanded(IMG_SUBDIR)
    for img in IMAGES:
        x, y = locate_row(img)
        rpc("move_mouse", [x, y]); settle(10)
        rpc("click", [x, y]); settle(40)
        alive("click " + img)
        # Hover für Tooltip (700 ms)
        rpc("move_mouse", [x + 5, y]); time.sleep(1.2)
        alive("tooltip " + img)
    # Ordner wieder zuklappen und aufklappen
    x, y = locate_row(JOBS_NAME)
    rpc("click", [x, y]); settle(20)
    rpc("click", [x, y]); settle(20)
    alive("collapse/expand")


def scenario_rpc_open():
    for img in IMAGES:
        rpc("explorer_open", [os.path.join(JOBS_DIR, img)])
        settle(40)
        alive("explorer_open " + img)


def scenario_tabs():
    for i in range(4):
        key("tab", ctrl=True); settle(20)
    alive("ctrl+tab")
    tabs = result_json("get_active_tab")["tabs"]
    for t in tabs:
        b = result_json("tab_bounds", [t["index"]])
        if b["found"]:
            rpc("click", [b["x"] + b["w"] / 2, b["y"] + b["h"] / 2]); settle(20)
    alive("tab clicks")
    # letzten Tab per Mittelklick schließen
    tabs = result_json("get_active_tab")["tabs"]
    if len(tabs) > 1:
        b = result_json("tab_bounds", [tabs[-1]["index"]])
        rpc("middle_click", [b["x"] + b["w"] / 2, b["y"] + b["h"] / 2]); settle(30)
        alive("middle click close")
    key("w", ctrl=True); settle(30)
    alive("ctrl+w")


def scenario_pickers():
    key("p", ctrl=True); settle(60)
    alive("ctrl+p open")
    rpc("type_text", ["portrait"]); settle(40)
    alive("ctrl+p typed")
    b = result_json("element_bounds_i", ["pk_row", 0])
    if b["found"]:
        rpc("move_mouse", [b["x"] + 20, b["y"] + b["h"] / 2]); settle(5)
        rpc("click", [b["x"] + 20, b["y"] + b["h"] / 2]); settle(40)
        alive("ctrl+p click row")
    else:
        key("escape"); settle(10)
    key("e", ctrl=True); settle(20)
    alive("ctrl+e open")
    b = result_json("element_bounds_i", ["pk_row", 1])
    if b["found"]:
        rpc("click", [b["x"] + 20, b["y"] + b["h"] / 2]); settle(40)
        alive("ctrl+e click row")
    else:
        key("escape"); settle(10)
    key("p", ctrl=True); settle(40)
    rpc("click", [600, 780]); settle(20)  # außerhalb → schließt
    alive("ctrl+p click outside")


def main():
    global PROC
    ai_on = "--ai=on" in sys.argv
    extra = [a for a in sys.argv[1:] if a != "--ai=on"]
    make_tree()
    target = os.path.realpath(TREE)  # zid löst Links/Junctions auf
    log = open(LOG_PATH, "w")
    env = dict(os.environ, XDG_CONFIG_HOME=os.path.join(ROOT, "tmp", "xdg-config"), XDG_DATA_HOME=os.path.join(ROOT, "tmp", "xdg"))
    args = ["--headless"] + ([] if ai_on else ["--ai=off"]) + extra
    PROC = start_zid(args, log, env=env)
    try:
        wait_port(PROC)
        settle(30)
        if ai_on:
            time.sleep(25)
        alive("start")
        open_folder(TREE, target)
        scenario_explorer_clicks()
        scenario_rpc_open()
        scenario_tabs()
        scenario_pickers()
        scenario_explorer_clicks()
        scenario_tabs()
        settle(60)
        alive("idle")
        print("NO CRASH")
    finally:
        stop_zid(PROC)
        log.close()


if __name__ == "__main__":
    main()
