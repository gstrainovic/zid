#!/usr/bin/env python3
"""Headless-E2E für die Tab-Leiste: Vorschau-Tabs, Mittelklick, Kontextmenü, Ctrl+Shift+T,
Ctrl+1…9, Ctrl+PgUp/PgDn, Anpinnen, Drag-Umordnen, aktiver Tab im Sichtbereich, Reveal in Explorer.
Aufruf: python3 scripts/e2e_tabs.py
"""
import os, shutil, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e2e_open_folder import ROOT, rpc, result_json, wait_port, settle, bounds, click_center, check, shot, start_zid, stop_zid  # noqa: E402
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
    shutil.rmtree(os.path.join(ROOT, "tmp", "xdg-config"), ignore_errors=True)  # gemerkte Optionen zurücksetzen
    os.makedirs(os.path.join(FX, "a"))
    os.makedirs(os.path.join(FX, "b"))
    for n in ("one.txt", "two.txt", "three.txt", "four.txt", "five.txt", "notes.md"):
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
    print("--- Jede Datei bekommt ihren eigenen Tab")
    reveal_fixture()
    explorer_click("five.txt")
    check("five.txt" in tab_names() and active_name() == "five.txt", "Einfachklick öffnet five.txt")
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


def step_recent_switch_and_picker():
    print("--- Ctrl+Tab in „zuletzt benutzt“-Reihenfolge, Ctrl+E Tab-Picker")
    reveal_fixture()
    for name in ("one.txt", "two.txt", "three.txt"):
        explorer_click(name)
    key("space")
    check(ui_state()["explorer_focused"], "Fokus im Explorer")
    # Cursor zu four.txt: der Explorer sortiert nicht, die Reihenfolge ist die des
    # Dateisystems (ext4 Hash-Reihenfolge, NTFS alphabetisch).
    order = [e["name"] for e in explorer()["entries"]]
    cur = next(e["name"] for e in explorer()["entries"] if e["cursor"])
    step = "down" if order.index("four.txt") > order.index(cur) else "up"
    for _ in range(abs(order.index("four.txt") - order.index(cur))):
        key(step)
    key("enter")
    settle(10)
    check(active_name() == "four.txt", "Enter öffnet four.txt")
    key("escape")
    rpc("click", [700, 400]); settle()
    # Reihenfolge jetzt: four, three, two, one (jüngster zuerst)
    key("tab", ctrl=True)
    check(active_name() == "three.txt", "Ctrl+Tab wechselt zum zuletzt benutzten Tab (three.txt)")
    key("tab", ctrl=True)
    check(active_name() == "four.txt", "Ctrl+Tab erneut springt zurück (four.txt)")
    # Ctrl gehalten: zweimal Tab läuft zwei Positionen weiter, Loslassen wählt
    rpc("key_press_hold", ["tab", True, False, False]); settle()
    check(ui_state()["tab_switcher"] == 1, "Umschalter offen auf Position 1")
    rpc("key_press_hold", ["tab", True, False, False]); settle()
    check(ui_state()["tab_switcher"] == 2, "zweites Tab bei gehaltenem Ctrl: Position 2")
    shot("e2e_tabs_switcher.ppm")
    rpc("mods_release"); settle()
    check(ui_state()["tab_switcher"] == -1 and active_name() == "two.txt", f"Ctrl loslassen wählt den drittjüngsten Tab (two.txt), aktiv: {active_name()}")
    rpc("key_press_hold", ["tab", True, True, False]); settle()
    check(ui_state()["tab_switcher"] == len(tabs()) - 1, "Ctrl+Shift+Tab beginnt beim ältesten Tab")
    rpc("mods_release"); settle()
    # Picker über offene Tabs
    key("e", ctrl=True)
    st = result_json("picker_state")
    check(st["open"] and st["mode"] == "tabs" and st["matches"] == len(tabs()), f"Ctrl+E zeigt alle {len(tabs())} offenen Tabs")
    rpc("type_text", ["one"]); settle(10)
    check(result_json("picker_state")["selected_label"] == "one.txt", "Filter 'one' trifft one.txt")
    key("enter"); settle(10)
    check(active_name() == "one.txt", "Enter wechselt zu one.txt")
    # Für die nächsten Schritte: two/three/four bleiben offen, four.txt aktiv
    rpc("middle_click", [*tab_center("one.txt")]); settle(5)
    # four.txt kann rechts außerhalb des Fensters liegen (Streifen scrollt nur zum aktiven Tab):
    # Ctrl+<Position> statt Klick
    pos = tab_names().index("four.txt") + 1
    check(pos <= 9, f"four.txt per Ctrl+Ziffer erreichbar (Position {pos})")
    key(str(pos), ctrl=True); settle()
    check(active_name() == "four.txt", "four.txt aktiv")


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
    b_entries = [e for e in explorer()["entries"] if e["path"].endswith(os.sep + os.path.join("b", "mod.zig"))]
    if b_entries:
        rpc("explorer_open", [b_entries[0]["path"]]); settle(10)
    check(tab_names().count("mod.zig") == 2, "zwei Tabs mod.zig (a/ und b/) offen")
    shot("e2e_tabs_many.ppm")
    strip = bounds("tab_strip") if False else None
    b = tab_bounds(result_json("get_active_tab")["active_index"])
    check(b["found"] and b["x"] >= 250 and b["x"] + b["w"] <= 1200, f"aktiver Tab liegt im Fenster (x={b['x']:.0f}, w={b['w']:.0f})")
    # Links weggescrollte Tabs liegen unsichtbar unter „+“ und dem Explorer: ihre Bounding-Box
    # zählt dort nicht, ein Klick auf „+“ wechselt keinen Tab.
    active = result_json("get_active_tab")["active_index"]
    x = 270  # „+“ (Sidebar 250 + Innenabstand 4, Knopf 32 breit)
    hidden = [i for i in range(len(tab_names())) if (lambda t: t["x"] <= x < t["x"] + t["w"])(tab_bounds(i))]
    check(hidden and hidden[0] != active, f"ein weggescrollter Tab liegt unter „+“ (Tab {hidden})")
    rpc("click", [x, b["y"] + b["h"] / 2]); settle(10)
    check(result_json("get_active_tab")["active_index"] == active, "Klick auf „+“ wechselt nicht zum verdeckten Tab")
    rpc("click", [x, b["y"] + b["h"] / 2]); settle(10)  # Neu-Menü wieder zu
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


def step_md_preview_from_tab_menu():
    print("--- Tab-Kontextmenü: Markdown Preview nur bei .md, öffnet die Vorschau des angeklickten Tabs")
    # Erst aufräumen: mit vielen Tabs liegt der Zieltab sonst außerhalb der gescrollten Leiste
    # (tab_bounds liefert dann die alte Geometrie und der Rechtsklick trifft einen anderen Tab)
    st = result_json("get_active_tab")
    if st["active_index"] is not None:
        b = tab_bounds(st["active_index"])
        rpc("right_click", [b["x"] + b["w"] / 2, b["y"] + b["h"] / 2]); settle()
        click_center("tab_menu_close_all_tabs"); settle(10)
    check(len(tabs()) == 0, f"alle Tabs zu: {tab_names()}")
    reveal_fixture()
    explorer_click("notes.md"); explorer_click("notes.md")
    explorer_click("one.txt"); explorer_click("one.txt")
    key("escape")
    check(active_name() == "one.txt", "one.txt aktiv")
    # Textdatei zuerst: der Eintrag wurde in diesem Lauf noch nie gezeichnet, „nicht gefunden“ ist hier belastbar
    x, y = tab_center("one.txt")
    rpc("right_click", [x, y]); settle()
    check(bounds("tab_menu_close_tab")["found"], "Menü der Textdatei offen")
    check(not result_json("element_bounds", ["tab_menu_md_preview"])["found"], "Textdatei: kein Markdown Preview im Tab-Menü")
    key("escape")
    x, y = tab_center("notes.md")
    rpc("right_click", [x, y]); settle()
    check(bounds("tab_menu_md_preview")["found"], "Markdown-Tab: Menü zeigt Markdown Preview")
    check(abs(bounds("tab_menu_md_preview")["h"] - 30) < 0.5, "Menüzeile ist 30 px hoch wie im Editor- und Explorer-Menü")
    shot("e2e_tabs_menu_md.ppm")
    click_center("tab_menu_md_preview"); settle(10)
    previews = [t for t in tabs() if t["kind"] == "markdown_preview"]
    check(len(previews) == 1 and previews[0]["name"] == "notes.md", f"Vorschau-Tab für notes.md offen (nicht für den aktiven one.txt): {tab_names()}")
    for t in sorted(tabs(), key=lambda t: -t["index"]):
        if t["name"] in ("notes.md", "one.txt"):
            b = tab_bounds(t["index"])
            rpc("middle_click", [b["x"] + b["w"] / 2, b["y"] + b["h"] / 2]); settle(5)
    check("notes.md" not in tab_names(), "aufgeräumt")


def step_split_keeps_chat_and_terminal():
    """Split behält Chat- und Terminal-Tabs in der ursprünglichen Hälfte. cloneFrom lässt sie
    bewusst aus (sonst doppelt gezeichnet), splitActivePane klonte aber beide Hälften und
    verwarf die Quelle: Chat und Terminal waren nach jedem Split weg."""
    print("--- Split behält Chat und Terminal")
    # Eine Datei dazu, sonst bliebe die neue Hälfte leer und würde gleich wieder eingeklappt
    rpc("open_file", [os.path.join(FX, "one.txt")]); settle(10)
    rpc("open_chat"); settle(10)
    rpc("open_terminal"); settle(10)
    before = ui_state()
    chats = [p for p in before["all_tabs"] if p.startswith("Chat ")]
    terms = [p for p in before["all_tabs"] if p.startswith("Terminal ")]
    check(len(chats) == 1 and len(terms) == 1, f"Chat und Terminal offen: {before['all_tabs']}")
    panes = before["pane_count"]
    rpc("split_pane", ["v"])
    # Der Split wird vor dem nächsten Layout ausgeführt; headless entsteht das Layout beim Screenshot.
    shot("e2e_tabs_split.ppm")
    after = ui_state()
    check(after["pane_count"] == panes + 1, f"Split erzeugt ein Pane ({after['pane_count']})")
    for name in chats + terms:
        n = after["all_tabs"].count(name)
        check(n == 1, f"{name} bleibt genau einmal erhalten ({n}x): {after['all_tabs']}")


STEPS = [step_default_own_tab, step_recent_switch_and_picker, step_dot_and_middle_click, step_context_menu_and_reopen, step_drag_reorder, step_scroll_active_into_view, step_reveal, step_md_preview_from_tab_menu, step_split_keeps_chat_and_terminal]


def main():
    setup()
    log = open(os.path.join(ROOT, "tmp", "e2e_tabs.log"), "w")
    env = dict(os.environ, XDG_DATA_HOME=os.path.join(ROOT, "tmp", "xdg"), XDG_CONFIG_HOME=os.path.join(ROOT, "tmp", "xdg-config"))
    proc = start_zid(["--headless", "--ai=off"], log, env=env)
    try:
        wait_port(proc)
        settle(20)
        for step in STEPS:
            step()
        print("ALL PASSED")
    finally:
        stop_zid(proc)
        log.close()


if __name__ == "__main__":
    main()
