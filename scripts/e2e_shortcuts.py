#!/usr/bin/env python3
"""Headless-E2E für Tastenkürzel und Menüs (todo.md: Kürzel sichtbar machen).

Startet zid mit --headless --ai=off und prüft pro Punkt der todo.md,
dass Taste und Menüeintrag dasselbe tun. Aufruf: python3 scripts/e2e_shortcuts.py
"""
import os, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e2e_open_folder import ROOT, rpc, result_json, wait_port, settle, bounds, click_center, check, shot  # noqa: E402


def key(name, ctrl=False, shift=False):
    rpc("key_press_mods", [name, ctrl, shift])
    settle()


def menu_click(menu_id, item_id):
    """Menü öffnen, Eintrag anklicken (beide müssen im Layout stehen)."""
    click_center(menu_id)
    check(bounds(item_id)["found"], f"Menü zeigt {item_id}")
    click_center(item_id)


def picker_open():
    return result_json("folder_picker_state")["open"]


def item1_table_drives_ctrl_o():
    print("--- 1. Kürzel-Tabelle: Ctrl+O und Menüeintrag laufen über executeCommand")
    key("o", ctrl=True)
    check(picker_open(), "Ctrl+O öffnet den Ordner-Dialog")
    key("escape")
    check(not picker_open(), "Escape schließt ihn")
    menu_click("menu_file", "menu_item_open_folder")
    check(picker_open(), "Menü File → Open Folder… öffnet den Dialog")
    key("escape")


def explorer():
    return result_json("explorer_entries")


def explorer_row_center(name):
    """Zeilenmitte des Explorer-Eintrags `name`; scrollt ihn bei Bedarf in den Viewport.
    Schrittweite nach Abstand: tmp/ hat hunderte Einträge, feste 3 Zeilen je Versuch reichten nicht."""
    for _ in range(40):
        ex = explorer()
        rows = [e for e in ex["entries"] if e["name"] == name]
        if not rows:
            # Der Explorer lädt nach Löschen, Umbenennen und Verschieben neu und klappt
            # dabei kurz zu. Wer genau dann fragt, sieht nur die Wurzel — also nachfassen,
            # bevor wir aufgeben. Die Namen stehen in der Meldung, sonst sagt „nicht
            # sichtbar" nicht, ob der Explorer woanders steht oder der Eintrag fehlt.
            settle(6)
            ex = explorer()
            rows = [e for e in ex["entries"] if e["name"] == name]
            if not rows:
                have = [e["name"] for e in ex["entries"]]
                raise AssertionError(f"Explorer-Eintrag {name!r} nicht sichtbar; sichtbar: {have}")
        vp, rh = ex["viewport"], ex["row_height"]
        y = vp["y"] + rows[0]["index"] * rh + rh / 2 - ex["scroll"]
        if vp["y"] <= y < vp["y"] + vp["h"]:
            return vp["x"] + 60, y
        center = vp["y"] + vp["h"] / 2
        lines = max(3, int(abs(y - center) / rh))
        rpc("scroll", [vp["x"] + 60, center, -lines if y >= center else lines])
        settle()
    raise AssertionError(f"{name!r} nicht in den Viewport gescrollt")


def explorer_click(name, right=False):
    x, y = explorer_row_center(name)
    rpc("right_click" if right else "click", [x, y])
    settle()


def ui_state():
    return result_json("ui_state")


def dialog_open():
    return ui_state()["dialog"] is not None


def item2_explorer_f2_delete():
    print("--- 2. Explorer: F2 benennt um, Entf löscht (mit Dialog), nur mit Fokus im Explorer")
    fixture_dir = os.path.join(ROOT, "tmp", "e2e_fx")
    os.makedirs(fixture_dir, exist_ok=True)
    victim = os.path.join(fixture_dir, "victim.txt")
    with open(victim, "w") as f:
        f.write("bye\n")
    time.sleep(0.5)  # Watcher/Refresh
    # tmp → e2e_fx aufklappen, Datei markieren
    if not any(e["name"] == "e2e_fx" for e in explorer()["entries"]):
        explorer_click("tmp")
    if not any(e["name"] == "victim.txt" for e in explorer()["entries"]):
        explorer_click("e2e_fx")
    explorer_click("victim.txt")
    settle(10)

    key("f2")
    check(explorer()["renaming"], "F2 startet das Umbenennen des markierten Eintrags")
    key("escape")
    check(not explorer()["renaming"], "Escape bricht das Umbenennen ab")

    key("delete")
    check(dialog_open(), "Entf öffnet den Lösch-Dialog")
    click_center("Cancel")
    check(not dialog_open() and os.path.exists(victim), "Cancel: Datei bleibt")

    # Fokus im Editor: Entf darf nichts löschen
    rpc("click", [1100, 400])
    settle()
    key("delete")
    check(not dialog_open(), "Entf ohne Explorer-Fokus öffnet keinen Dialog")

    explorer_click("victim.txt")
    key("delete")
    check(dialog_open(), "Entf nach erneutem Klick im Explorer öffnet den Dialog")
    click_center("Delete")
    settle(10)
    check(not os.path.exists(victim), "Delete: Datei ist gelöscht")
    os.rmdir(fixture_dir)


def item3_tabs():
    print("--- 3. Tabs: Ctrl+N neue Datei, Ctrl+Tab/Ctrl+Shift+Tab wechseln, Ctrl+W schließen")
    rpc("click", [1100, 400])  # Fokus in den Editor-Bereich
    settle()
    n0 = ui_state()["tab_count"]
    key("n", ctrl=True)
    st = ui_state()
    check(st["tab_count"] == n0 + 1 and st["tabs"][st["active_tab"]]["path"].endswith("New File.txt"),
          f"Ctrl+N öffnet 'New File.txt' als aktiven Tab ({st['tab_count']} Tabs)")

    rpc("explorer_open", [os.path.join(ROOT, "README.md")])
    settle(10)
    st = ui_state()
    n = st["tab_count"]
    check(n == n0 + 2, f"Zweite Datei geöffnet, {n} Tabs")
    # Ctrl+Tab geht nach "zuletzt benutzt", nicht zyklisch durch die Leiste:
    # ein einzelner Druck springt zwischen den zwei jüngsten Tabs hin und her.
    active = st["active_tab"]
    key("tab", ctrl=True)
    previous = ui_state()["active_tab"]
    check(previous != active, f"Ctrl+Tab verlässt den aktiven Tab ({active} → {previous})")
    key("tab", ctrl=True)
    check(ui_state()["active_tab"] == active,
          f"noch ein Ctrl+Tab springt zurück ({previous} → {active})")
    # Ctrl+Shift+Tab läuft die MRU-Liste andersherum. Vom jüngsten Eintrag aus
    # landet man deshalb beim ältesten, nicht beim zweitjüngsten.
    key("tab", ctrl=True, shift=True)
    st = ui_state()
    check(st["active_tab"] not in (active, previous),
          f"Ctrl+Shift+Tab springt zum ältesten Tab ({active} → {st['active_tab']})")

    key("w", ctrl=True)
    settle(5)
    st = ui_state()
    check(st["tab_count"] == n - 1 and st["dialog"] is None, f"Ctrl+W schließt den ungeänderten aktiven Tab ({st['tab_count']} Tabs)")

    # Geänderter Tab: Ctrl+W fragt nach, Cancel behält ihn
    while not ui_state()["tabs"][ui_state()["active_tab"]]["path"].endswith("New File.txt"):
        key("tab", ctrl=True)
    rpc("click", [700, 400])
    settle()
    rpc("type_text", ["abc"])
    settle(10)
    check(ui_state()["tabs"][ui_state()["active_tab"]]["modified"], "Tippen markiert den Tab als geändert")
    n = ui_state()["tab_count"]
    key("w", ctrl=True)
    check(ui_state()["dialog"] is not None, "Ctrl+W auf geändertem Tab öffnet die Speichern-Nachfrage")
    click_center("Cancel")
    check(ui_state()["dialog"] is None and ui_state()["tab_count"] == n, "Cancel behält den Tab")


def item4_view():
    print("--- 4. Ansicht: Ctrl+B Explorer, Ctrl+` Terminal, Ctrl+Shift+K Zeile löschen")
    key("b", ctrl=True)
    check(not ui_state()["show_file_explorer"], "Ctrl+B blendet den Explorer aus")
    key("b", ctrl=True)
    check(ui_state()["show_file_explorer"], "Ctrl+B blendet ihn wieder ein")

    n = ui_state()["tab_count"]
    key("grave", ctrl=True)
    settle(10)
    st = ui_state()
    check(st["tab_count"] == n + 1 and st["tabs"][st["active_tab"]]["kind"] == "terminal", "Ctrl+` öffnet einen Terminal-Tab")
    key("w", ctrl=True)
    settle(5)
    check(ui_state()["tab_count"] == n, "Ctrl+W schließt den Terminal-Tab wieder")

    # Zurück in den geänderten Text-Tab (New File.txt), drei Zeilen, eine löschen
    while not ui_state()["tabs"][ui_state()["active_tab"]]["path"].endswith("New File.txt"):
        key("tab", ctrl=True)
    rpc("click", [700, 400])
    settle()
    key("end", ctrl=True)
    key("enter"); rpc("type_text", ["zwei"]); key("enter"); rpc("type_text", ["drei"])
    settle(10)
    lines = int(rpc("editor_lines"))
    key("k", ctrl=True, shift=True)
    settle(5)
    after = int(rpc("editor_lines"))
    check(after == lines - 1, f"Ctrl+Shift+K löscht die aktuelle Zeile ({lines} → {after})")


def item5_menus():
    print("--- 5. Menüleiste File/Edit/View/Help aus der Tabelle, Einträge führen Commands aus")
    for title in ("menu_file", "menu_edit", "menu_view", "menu_help"):
        check(bounds(title)["found"], f"Header zeigt {title}")
    click_center("menu_edit")
    check(ui_state()["open_menu"] == "Edit", "Klick auf Edit öffnet das Edit-Menü")
    rpc("move_mouse", [bounds("menu_view")["x"] + 10, bounds("menu_view")["y"] + 10]); settle()
    check(ui_state()["open_menu"] == "View", "Hover über View wechselt bei offenem Menü")
    key("escape")
    check(ui_state()["open_menu"] is None, "Escape schließt das Menü")

    # Breite kommt vom breitesten Eintrag. Mit der früheren festen Breite (380)
    # stieß "Toggle Line Comment" an sein Kürzel "Ctrl+/".
    widths = {}
    for name, title in (("File", "menu_file"), ("Edit", "menu_edit"), ("View", "menu_view")):
        click_center(title); settle(5)
        widths[name] = bounds("menu_dropdown")["w"]
        key("escape"); settle(3)
    for name, w in widths.items():
        check(w > 380, f"{name}-Menü ist breiter als das alte feste Maß ({w:.0f} > 380)")
    check(widths["Edit"] > widths["View"], "Edit braucht mehr Platz als View und bekommt ihn auch")

    # "New File.txt" ist aus Punkt 3 offen und geändert: New File wechselt dorthin,
    # Close Tab fragt nach, "Don't Save" schließt.
    menu_click("menu_file", "menu_item_new_file")
    st = ui_state()
    check(st["tabs"][st["active_tab"]]["path"].endswith("New File.txt") and st["open_menu"] is None,
          "File → New File aktiviert 'New File.txt' und schließt das Menü")
    n = st["tab_count"]
    menu_click("menu_file", "menu_item_close_tab")
    check(ui_state()["dialog"] == "Unsaved Changes", "File → Close Tab fragt bei Änderungen nach")
    click_center("Don't Save")
    settle(5)
    check(ui_state()["tab_count"] == n - 1, "Don't Save schließt den Tab")
    menu_click("menu_file", "menu_item_new_file")
    check(ui_state()["tab_count"] == n, "File → New File legt danach einen neuen Tab an")

    menu_click("menu_view", "menu_item_toggle_explorer")
    check(not ui_state()["show_file_explorer"], "View → Toggle Explorer blendet aus")
    menu_click("menu_view", "menu_item_toggle_explorer")
    check(ui_state()["show_file_explorer"], "View → Toggle Explorer blendet ein")

    # Edit → Delete Line im geänderten Text-Tab
    while not ui_state()["tabs"][ui_state()["active_tab"]]["path"].endswith("New File.txt"):
        key("tab", ctrl=True)
    rpc("click", [700, 400]); settle()
    before = int(rpc("editor_lines"))
    key("end", ctrl=True); key("enter"); rpc("type_text", ["extra"]); settle(5)
    menu_click("menu_edit", "menu_item_delete_line")
    settle(5)
    check(int(rpc("editor_lines")) == before, f"Edit → Delete Line löscht die neue Zeile (zurück auf {before})")
    menu_click("menu_edit", "menu_item_undo")
    settle(5)
    check(int(rpc("editor_lines")) == before + 1, "Edit → Undo holt sie zurück")
    click_center("menu_edit")
    shot("e2e_menu_edit.ppm")
    key("escape")


def item6_editor_context_menu():
    print("--- 6. Kontextmenüs (Editor, Markdown-Vorschau, Terminal) aus der Tabelle im gemeinsamen Stil")
    rpc("explorer_open", [os.path.join(ROOT, "README.md")]); settle(10)
    rpc("click", [700, 400]); settle()
    rpc("right_click", [700, 400]); settle()
    for item in ("editor_menu_cut", "editor_menu_copy", "editor_menu_paste", "editor_menu_md_preview", "editor_menu_split_vertical", "editor_menu_split_horizontal"):
        check(bounds(item)["found"], f"Kontextmenü zeigt {item}")
    # Gemeinsamer Stil: gleiche Zeilenhöhe wie das Tab- und Explorer-Menü (context_menu.zig)
    check(abs(bounds("editor_menu_cut")["h"] - 30) < 0.5, "Menüzeile ist 30 px hoch wie in allen Kontextmenüs")
    shot("e2e_editor_ctx.ppm")
    # Markdown Preview aus dem Editor-Menü öffnet die Vorschau; dort zeigt Rechtsklick das Vorschau-Menü
    click_center("editor_menu_md_preview"); settle(10)
    st = ui_state()
    check(st["tabs"][st["active_tab"]]["kind"] == "markdown_preview", "Editor-Menü → Markdown Preview öffnet den Vorschau-Tab")
    rpc("right_click", [700, 400]); settle()
    check(bounds("md_menu_split_vertical")["found"] and bounds("md_menu_split_horizontal")["found"], "Vorschau-Menü zeigt Split V/H")
    check(abs(bounds("md_menu_split_vertical")["h"] - 30) < 0.5, "Vorschau-Menüzeile ist 30 px hoch")
    shot("e2e_md_ctx.ppm")
    rpc("click", [700, 400]); settle()  # Klick neben das Menü schließt es
    key("w", ctrl=True); settle(10)
    # Terminal: eigene Einträge ohne Ctrl+C/V
    rpc("open_terminal"); settle(10)
    rpc("right_click", [700, 400]); settle()
    check(bounds("term_menu_terminal_copy")["found"] and bounds("term_menu_terminal_paste")["found"], "Terminal-Menü zeigt Copy/Paste")
    check(abs(bounds("term_menu_terminal_copy")["h"] - 30) < 0.5, "Terminal-Menüzeile ist 30 px hoch")
    shot("e2e_term_ctx.ppm")
    rpc("click", [700, 400]); settle()
    key("w", ctrl=True); settle(10)
    rpc("click", [1100, 700]); settle()


def item7_shortcuts_dialog():
    print("--- 7. Help → Keyboard Shortcuts: Dialog aus der Tabelle, F1 und Escape")
    key("f1")
    check(ui_state()["shortcuts_open"], "F1 öffnet den Shortcut-Dialog")
    check(bounds("sc_close")["found"], "Dialog hat einen Close-Button")
    shot("e2e_shortcuts_dialog.ppm")
    key("escape")
    check(not ui_state()["shortcuts_open"], "Escape schließt ihn")
    menu_click("menu_help", "menu_item_show_shortcuts")
    check(ui_state()["shortcuts_open"], "Help → Keyboard Shortcuts öffnet ihn")
    click_center("sc_close")
    check(not ui_state()["shortcuts_open"], "Close schließt ihn")


def editor_state():
    return result_json("editor_state")


def item8_find():
    print("--- 8. Ctrl+F: Suchleiste, Enter weiter, Shift+Enter zurück, Escape schließt")
    rpc("explorer_open", [os.path.join(ROOT, "README.md")]); settle(15)
    rpc("click", [700, 400]); settle()
    key("home", ctrl=True)
    key("f", ctrl=True)
    st = editor_state()
    check(st["find_open"], "Ctrl+F öffnet die Suchleiste")
    check(bounds("find_input")["found"], "Suchfeld wird gezeichnet")
    rpc("type_text", ["vulkan"]); settle(5)
    st = editor_state()
    lines = st["text"].split("\n")
    check(st["find_query"] == "vulkan", f"Suchbegriff im Feld: {st['find_query']!r}")
    hits = [i for i, l in enumerate(lines) if "vulkan" in l.lower()]
    check(st["row"] in hits and not st["find_not_found"], f"Tippen springt zum ersten Treffer (Zeile {st['row'] + 1})")
    first = st["row"]
    key("enter")
    st = editor_state()
    check(st["row"] in hits and (st["row"] != first or len(hits) == 1), f"Enter springt zum nächsten Treffer (Zeile {st['row'] + 1})")
    key("enter", shift=True)
    check(editor_state()["row"] == first, "Shift+Enter springt zurück")
    shot("e2e_find.ppm")
    for _ in range(6):
        key("backspace")
    rpc("type_text", ["qzqzqz"]); settle(5)
    check(editor_state()["find_not_found"], "Unbekannter Begriff meldet 'No results'")
    key("escape")
    check(not editor_state()["find_open"], "Escape schließt die Suchleiste")
    menu_click("menu_edit", "menu_item_find")
    check(editor_state()["find_open"], "Edit → Find öffnet sie ebenfalls")
    key("escape")


STEPS = [item1_table_drives_ctrl_o, item2_explorer_f2_delete, item3_tabs, item4_view, item5_menus,
         item6_editor_context_menu, item7_shortcuts_dialog, item8_find]


def main():
    log = open(os.path.join(ROOT, "tmp", "e2e_shortcuts.log"), "w")
    proc = subprocess.Popen(
        [os.path.join(ROOT, "zig-out", "bin", "zid"), "--headless", "--ai=off"],
        cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
        env=dict(os.environ, XDG_DATA_HOME=os.path.join(ROOT, "tmp", "xdg"), XDG_CONFIG_HOME=os.path.join(ROOT, "tmp", "xdg-config")),  # Papierkorb unter tmp/
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
