#!/usr/bin/env python3
"""Headless-E2E für die Tab-Leiste: Vorschau-Tabs, Mittelklick, Kontextmenü, Ctrl+Shift+T,
Ctrl+1…9, Ctrl+PgUp/PgDn, Anpinnen, Drag-Umordnen, aktiver Tab im Sichtbereich, Reveal in Explorer.
Aufruf: python3 scripts/e2e_tabs.py
"""
import os, shutil, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e2e_open_folder import ROOT, rpc, result_json, wait_port, settle, bounds, click_center, check, shot  # noqa: E402
from e2e_shortcuts import key, explorer, explorer_click, ui_state, dialog_open  # noqa: E402

FX = os.path.join(ROOT, "tmp", "e2e_tabs")


def tabs():
    return result_json("get_active_tab")["tabs"]


def tab_names():
    return [t["name"] for t in tabs()]


def active_name():
    st = result_json("get_active_tab")
    idx = st["active_index"]
    return st["tabs"][idx]["name"] if idx is not None and idx < len(st["tabs"]) else None


def tab_bounds(i):
    return result_json("tab_bounds", [i])


def tab_center(name):
    for t in tabs():
        if t["name"] == name:
            b = tab_bounds(t["index"])
            return b["x"] + b["w"] / 2, b["y"] + b["h"] / 2
    raise AssertionError(f"Tab {name} fehlt")


def setup():
    shutil.rmtree(FX, ignore_errors=True)
    shutil.rmtree(os.path.join(ROOT, "tmp", "xdg-config"), ignore_errors=True)  # gemerkte Optionen (preview_tabs) zurücksetzen
    os.makedirs(os.path.join(FX, "a"))
    os.makedirs(os.path.join(FX, "b"))
    for n in ("one.txt", "two.txt", "three.txt", "four.txt", "five.txt"):
        with open(os.path.join(FX, n), "w") as f:
            f.write(n + "\n")
    for d in ("a", "b"):
        with open(os.path.join(FX, d, "mod.zig"), "w") as f:
            f.write("// " + d + "\n")
    time.sleep(0.5)


def reveal_fixture():
    if "e2e_tabs" not in [e["name"] for e in explorer()["entries"]]:
        explorer_click("tmp")
    if "one.txt" not in [e["name"] for e in explorer()["entries"]]:
        explorer_click("e2e_tabs")


def step_default_own_tab():
    print("--- Standard: jede Datei bekommt ihren eigenen Tab, kein Vorschau-Ersetzen")
    reveal_fixture()
    check(not ui_state()["preview_tabs"], "Vorschau-Tabs sind standardmäßig aus")
    explorer_click("five.txt")
    check(not [t for t in tabs() if t["name"] == "five.txt"][0]["preview"], "Einfachklick öffnet five.txt als festen Tab")
    explorer_click("one.txt")
    names = tab_names()
    check("five.txt" in names and "one.txt" in names, "zweiter Einfachklick öffnet one.txt zusätzlich (five.txt bleibt)")
    explorer_click("five.txt")
    check(tab_names().count("five.txt") == 1 and active_name() == "five.txt", "erneuter Klick wechselt zum offenen Tab statt einen zweiten zu öffnen")
    # "+" (Neu-Menü) sitzt ganz links vor dem ersten Tab
    b0 = tab_bounds(0)
    check(b0["x"] >= explorer()["width"] + 32, f"erster Tab beginnt rechts vom +-Knopf (x={b0['x']:.0f})")
    for name in ("five.txt", "one.txt"):
        rpc("middle_click", [*tab_center(name)]); settle(5)
    check("five.txt" not in tab_names() and "one.txt" not in tab_names(), "aufgeräumt")


def step_preview():
    print("--- Vorschau-Tabs (eingeschaltet): Einfachklick ersetzt, Doppelklick macht fest")
    key("p", ctrl=True, shift=True); settle()
    rpc("type_text", ["toggle preview tabs"]); settle(10)
    key("enter"); settle(10)
    check(ui_state()["preview_tabs"], "Toggle Preview Tabs schaltet ein")
    reveal_fixture()
    explorer_click("one.txt")
    t = [t for t in tabs() if t["name"] == "one.txt"][0]
    check(t["preview"], "Einfachklick öffnet one.txt als Vorschau")
    explorer_click("two.txt")
    names = tab_names()
    check("two.txt" in names and "one.txt" not in names, "zweiter Einfachklick ersetzt die Vorschau (one.txt weg, two.txt da)")
    explorer_click("two.txt")  # Doppelklick (zwei Klicks kurz nacheinander)
    check(not [t for t in tabs() if t["name"] == "two.txt"][0]["preview"], "Doppelklick macht two.txt fest")
    explorer_click("three.txt")
    check("two.txt" in tab_names() and "three.txt" in tab_names(), "fester Tab bleibt, three.txt kommt als Vorschau dazu")
    key("space")
    check(ui_state()["explorer_focused"], "Fokus im Explorer")
    key("down")  # four.txt
    key("enter")
    settle(10)
    t4 = [t for t in tabs() if t["name"] == "four.txt"]
    # Fest öffnen ersetzt keine Vorschau (wie VS Code): three.txt bleibt als Vorschau stehen
    check(t4 and not t4[0]["preview"] and "three.txt" in tab_names(), "Enter öffnet four.txt fest, die Vorschau three.txt bleibt")
    key("escape")


def step_dot_and_middle_click():
    print("--- Punkt für ungespeichert, Mittelklick schließt")
    rpc("click", [700, 400]); settle()
    rpc("type_text", ["x"]); settle(10)
    check([t for t in tabs() if t["name"] == "four.txt"][0]["modified"], "Tippen macht four.txt dirty")
    shot("e2e_tabs_dot.ppm")
    x, y = tab_center("two.txt")
    rpc("middle_click", [x, y]); settle(10)
    check("two.txt" not in tab_names(), "Mittelklick schließt two.txt")
    x, y = tab_center("four.txt")
    rpc("middle_click", [x, y]); settle(10)
    check(dialog_open() and ui_state()["dialog"] == "Unsaved Changes", "Mittelklick auf dirty Tab fragt nach")
    key("d")  # Don't Save (Anfangsbuchstabe)
    settle(10)
    check(not dialog_open() and "four.txt" not in tab_names(), "d = Don't Save schließt ohne Speichern")


def step_context_menu_and_reopen():
    print("--- Tab-Kontextmenü, Close Others, Ctrl+Shift+T, Ctrl+1, Ctrl+PgDn, Pin")
    reveal_fixture()
    for n in ("one.txt", "two.txt", "three.txt"):
        explorer_click(n); explorer_click(n)  # fest
    key("escape")
    check(all(n in tab_names() for n in ("one.txt", "two.txt", "three.txt")), "drei feste Tabs offen")
    x, y = tab_center("two.txt")
    rpc("right_click", [x, y]); settle()
    check(bounds("tab_menu_close_other_tabs")["found"], "Rechtsklick auf Tab zeigt das Menü")
    shot("e2e_tabs_menu.ppm")
    click_center("tab_menu_pin_tab"); settle()
    check([t for t in tabs() if t["name"] == "two.txt"][0]["pinned"], "Pin / Unpin pinnt two.txt")
    x, y = tab_center("one.txt")
    rpc("right_click", [x, y]); settle()
    click_center("tab_menu_close_other_tabs"); settle(10)
    names = tab_names()
    check("one.txt" in names and "two.txt" in names and "three.txt" not in names, "Close Others behält den Ziel-Tab und den angepinnten")
    key("t", ctrl=True, shift=True); settle(10)
    check("three.txt" in tab_names(), "Ctrl+Shift+T öffnet three.txt wieder")
    key("1", ctrl=True); settle()
    check(active_name() == tab_names()[0], "Ctrl+1 aktiviert den ersten Tab")
    before = active_name()
    key("page_down", ctrl=True); settle()
    check(active_name() != before, "Ctrl+PgDn wechselt zum nächsten Tab")
    x, y = tab_center("two.txt")
    rpc("right_click", [x, y]); settle()
    click_center("tab_menu_pin_tab"); settle()
    check(not [t for t in tabs() if t["name"] == "two.txt"][0]["pinned"], "Pin / Unpin löst den Pin")


def step_drag_reorder():
    print("--- Drag & Drop ordnet Tabs um")
    names = tab_names()
    first, last = names[0], names[-1]
    x0, y0 = tab_center(first)
    x1, y1 = tab_center(last)
    rpc("mouse_down", [x0, y0]); settle()
    for step in range(1, 6):
        rpc("move_mouse", [x0 + (x1 - x0) * step / 5, y0]); settle(3)
    rpc("mouse_up", [x1, y1]); settle(10)
    check(tab_names()[-1] == first, f"{first} steht nach dem Ziehen ganz rechts: {tab_names()}")


def step_scroll_active_into_view():
    print("--- Aktiver Tab wird in den Sichtbereich gescrollt")
    reveal_fixture()
    for n in ("four.txt", "five.txt"):
        explorer_click(n); explorer_click(n)
    explorer_click("a"); explorer_click("mod.zig"); explorer_click("mod.zig")
    explorer_click("b")
    mods = [e for e in explorer()["entries"] if e["name"] == "mod.zig"]
    # zweites mod.zig (unter b) per Enter
    key("escape")
    key("escape")
    b_entries = [e for e in explorer()["entries"] if e["path"].endswith("/b/mod.zig")]
    if b_entries:
        rpc("explorer_open", [b_entries[0]["path"]]); settle(10)
    check(tab_names().count("mod.zig") == 2, "zwei Tabs mod.zig (a/ und b/) offen")
    shot("e2e_tabs_many.ppm")
    strip = bounds("tab_strip") if False else None
    b = tab_bounds(result_json("get_active_tab")["active_index"])
    check(b["found"] and b["x"] >= 250 and b["x"] + b["w"] <= 1200, f"aktiver Tab liegt im Fenster (x={b['x']:.0f}, w={b['w']:.0f})")
    key("1", ctrl=True); settle(10)
    b = tab_bounds(0)
    check(b["found"] and b["x"] >= 250, f"nach Ctrl+1 ist Tab 1 sichtbar (x={b['x']:.0f})")


def step_reveal():
    print("--- Reveal in Explorer")
    explorer_click("tmp")  # zuklappen
    check("one.txt" not in [e["name"] for e in explorer()["entries"]], "tmp zugeklappt")
    key("escape")
    key("1", ctrl=True); settle()
    x, y = tab_center(tab_names()[0])
    rpc("right_click", [x, y]); settle()
    click_center("tab_menu_reveal_in_explorer"); settle(10)
    sel = [e for e in explorer()["entries"] if e["selected"]]
    check(sel and sel[0]["name"] == tab_names()[0], f"Reveal markiert {tab_names()[0]} im Explorer")


STEPS = [step_default_own_tab, step_preview, step_dot_and_middle_click, step_context_menu_and_reopen, step_drag_reorder, step_scroll_active_into_view, step_reveal]


def main():
    setup()
    log = open(os.path.join(ROOT, "tmp", "e2e_tabs.log"), "w")
    proc = subprocess.Popen(
        [os.path.join(ROOT, "zig-out", "bin", "vulkan-ed"), "--headless", "--ai=off"],
        cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
        env=dict(os.environ, XDG_DATA_HOME=os.path.join(ROOT, "tmp", "xdg"), XDG_CONFIG_HOME=os.path.join(ROOT, "tmp", "xdg-config")),
    )
    try:
        wait_port(proc)
        settle(20)
        for step in STEPS:
            step()
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
