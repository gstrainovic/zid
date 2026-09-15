#!/usr/bin/env python3
"""Headless-E2E für den Explorer: Fokus, Buchstaben-Kürzel, Tastaturnavigation,
Dialog per Tastatur, Papierkorb, Anlegen, Kopieren/Ausschneiden/Einfügen,
Mehrfachauswahl, Kontextmenü. Aufruf: python3 scripts/e2e_explorer.py

Papierkorb: XDG_DATA_HOME zeigt auf tmp/xdg, damit nichts im echten Papierkorb landet.
"""
import os, shutil, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e2e_open_folder import ROOT, rpc, result_json, wait_port, settle, bounds, click_center, check, shot  # noqa: E402
from e2e_shortcuts import key, explorer, explorer_click, explorer_row_center, ui_state, dialog_open  # noqa: E402

FX = os.path.join(ROOT, "tmp", "e2e_fx2")
XDG = os.path.join(ROOT, "tmp", "xdg")
XDG_CONFIG = os.path.join(ROOT, "tmp", "xdg-config")
TRASH_FILES = os.path.join(XDG, "Trash", "files")


def names():
    return [e["name"] for e in explorer()["entries"]]


def entry(name):
    for e in explorer()["entries"]:
        if e["name"] == name:
            return e
    return None


def reveal(name, folder_chain):
    for f in folder_chain:
        if name not in names():
            if not entry(f) or not entry(f)["expanded"]:
                explorer_click(f)
    check(name in names(), f"{name} sichtbar")


def wait_for(cond, what, timeout=5):
    t0 = time.time()
    while time.time() - t0 < timeout:
        if cond():
            check(True, what)
            return
        time.sleep(0.05)
    check(False, what)


def setup_fixture():
    shutil.rmtree(FX, ignore_errors=True)
    shutil.rmtree(XDG, ignore_errors=True)
    shutil.rmtree(XDG_CONFIG, ignore_errors=True)
    os.makedirs(os.path.join(FX, "sub"))
    for n in ("alpha.txt", "beta.txt", "gamma.txt"):
        with open(os.path.join(FX, n), "w") as f:
            f.write(n + "\n")
    with open(os.path.join(FX, "sub", "inner.txt"), "w") as f:
        f.write("inner\n")
    time.sleep(0.5)


def step_focus_and_letters():
    print("--- Fokus: Klick im Explorer, Buchstaben gehen nicht in den Editor")
    reveal("alpha.txt", ["tmp", "e2e_fx2"])
    explorer_click("alpha.txt")
    check(ui_state()["explorer_focused"], "Klick im Explorer setzt den Fokus")
    check(entry("alpha.txt")["selected"] and entry("alpha.txt")["cursor"], "alpha.txt markiert (Cursor)")
    editor_before = result_json("editor_state")["text"]
    key("q")
    check(result_json("editor_state")["text"] == editor_before, "Buchstabe ohne Kürzel erreicht den Editor nicht")
    key("d")
    check(dialog_open() and ui_state()["dialog"] == "Move to Trash", "d öffnet den Papierkorb-Dialog")
    check(result_json("editor_state")["text"] == editor_before, "d hat den Editor nicht verändert")
    key("escape")
    check(not dialog_open(), "Escape schließt den Dialog")
    check(os.path.exists(os.path.join(FX, "alpha.txt")), "Datei bleibt nach Escape")


def step_dialog_keyboard_trash():
    print("--- Dialog per Tastatur, Löschen in den Papierkorb")
    explorer_click("alpha.txt")
    key("d")
    check(ui_state()["dialog_focused"] == 0, "Fokus startet auf dem ersten Button")
    key("tab")
    check(ui_state()["dialog_focused"] == 1, "Tab wandert zu Cancel")
    key("enter")
    check(not dialog_open() and os.path.exists(os.path.join(FX, "alpha.txt")), "Enter auf Cancel: Datei bleibt")
    key("d")
    key("enter")
    wait_for(lambda: not os.path.exists(os.path.join(FX, "alpha.txt")), "Enter auf Delete: Datei ist weg")
    wait_for(lambda: os.path.exists(os.path.join(TRASH_FILES, "alpha.txt")), "alpha.txt liegt im Papierkorb (tmp/xdg/Trash/files)")
    info = open(os.path.join(XDG, "Trash", "info", "alpha.txt.trashinfo")).read()
    check("Path=" in info and "e2e_fx2/alpha.txt" in info, "trashinfo enthält den Originalpfad")
    wait_for(lambda: "alpha.txt" not in names(), "Explorer zeigt alpha.txt nicht mehr")


def step_navigation():
    print("--- Tastaturnavigation ↑↓←→ Enter")
    explorer_click("beta.txt")
    key("down")
    check(entry("gamma.txt")["cursor"], "↓ setzt den Cursor auf gamma.txt")
    key("up")
    key("up")
    check(entry("sub")["cursor"], "↑↑ setzt den Cursor auf den Ordner sub")
    check(entry("sub")["selected"], "Ordner ist markiert (vorher markierte ein Klick keine Ordner)")
    key("right")
    check(entry("sub")["expanded"] and "inner.txt" in names(), "→ klappt den Ordner auf")
    key("right")
    check(entry("inner.txt")["cursor"], "→ auf offenem Ordner geht zum ersten Kind")
    key("left")
    check(entry("sub")["cursor"], "← geht zum Elternordner")
    key("left")
    check(not entry("sub")["expanded"], "← klappt den Ordner zu")
    key("down")
    key("enter")
    wait_for(lambda: result_json("get_active_tab")["editor_file"].endswith("beta.txt"), "Enter öffnet beta.txt")
    check(ui_state()["explorer_focused"], "Fokus bleibt nach Enter im Explorer")
    key("escape")
    check(not ui_state()["explorer_focused"], "Escape gibt den Fokus an den Editor")


def step_create_rename():
    print("--- a/A legen an, r benennt um")
    explorer_click("beta.txt")
    key("a")
    check(explorer()["creating"], "a öffnet die Eingabe für eine neue Datei")
    rpc("type_text", ["neu.md"]); settle()
    key("enter")
    wait_for(lambda: os.path.exists(os.path.join(FX, "neu.md")), "neu.md wurde angelegt")
    wait_for(lambda: result_json("get_active_tab")["editor_file"].endswith("neu.md"), "neu.md ist im Editor offen")
    check(entry("neu.md") and entry("neu.md")["selected"], "neu.md ist markiert")
    key("a", shift=True)
    check(explorer()["creating"], "Shift+A öffnet die Eingabe für einen Ordner")
    rpc("type_text", ["ordner"]); settle()
    key("enter")
    wait_for(lambda: os.path.isdir(os.path.join(FX, "ordner")), "Ordner wurde angelegt")
    explorer_click("neu.md")
    key("r")
    check(explorer()["renaming"], "r startet das Umbenennen")
    for _ in range(6):
        key("backspace")
    rpc("type_text", ["renamed.md"]); settle()
    key("enter")
    wait_for(lambda: os.path.exists(os.path.join(FX, "renamed.md")), "Datei umbenannt")
    wait_for(lambda: any(t["name"] == "renamed.md" for t in result_json("get_active_tab")["tabs"]), "Tab folgt dem neuen Namen")


def step_clipboard():
    print("--- y/x/p kopieren, ausschneiden, einfügen; Ctrl+D dupliziert; c kopiert den Pfad")
    explorer_click("gamma.txt")
    key("c")
    check(ui_state()["clipboard_text"] == os.path.join(FX, "gamma.txt"), "c kopiert den absoluten Pfad")
    key("c", shift=True)
    check(ui_state()["clipboard_text"] == "tmp/e2e_fx2/gamma.txt", "Shift+C kopiert den Projekt-relativen Pfad")
    key("y")
    explorer_click("ordner")
    key("p")
    wait_for(lambda: os.path.exists(os.path.join(FX, "ordner", "gamma.txt")), "p fügt die Kopie in den markierten Ordner ein")
    check(os.path.exists(os.path.join(FX, "gamma.txt")), "Quelle bleibt beim Kopieren")
    explorer_click("beta.txt")
    key("x")
    explorer_click("ordner")
    key("p")
    wait_for(lambda: os.path.exists(os.path.join(FX, "ordner", "beta.txt")) and not os.path.exists(os.path.join(FX, "beta.txt")), "x + p verschiebt beta.txt")
    explorer_click("gamma.txt")
    key("d", ctrl=True)
    wait_for(lambda: os.path.exists(os.path.join(FX, "gamma copy.txt")), "Ctrl+D dupliziert als 'gamma copy.txt'")


def step_multi_select():
    print("--- Mehrfachauswahl: Ctrl+Klick, Shift+Klick, Ctrl+A")
    explorer_click("gamma.txt")
    # Ctrl+Klick ist per RPC nicht auslösbar (Modifier gelten nur für key_press), deshalb Shift+↓
    key("down", shift=True)
    check(ui_state()["explorer_selection_count"] == 2, "Shift+↓ erweitert die Auswahl auf 2 Einträge")
    key("d")
    check(dialog_open(), "d bei Mehrfachauswahl öffnet den Dialog")
    key("escape")
    key("a", ctrl=True)
    check(ui_state()["explorer_selection_count"] >= 3, "Ctrl+A markiert alle sichtbaren Einträge")
    explorer_click("gamma.txt")
    check(ui_state()["explorer_selection_count"] == 1, "Einfacher Klick setzt die Auswahl zurück")


def step_context_menu():
    print("--- Kontextmenü aus der Kürzel-Tabelle")
    explorer_click("gamma.txt", right=True)
    check(explorer()["menu_open"], "Rechtsklick öffnet das Menü")
    for item in ("fx_menu_new_file_entry", "fx_menu_paste_entry", "fx_menu_copy_path", "fx_menu_open_in_terminal", "fx_menu_collapse_all"):
        check(bounds(item)["found"], f"Menü zeigt {item}")
    shot("e2e_explorer_menu.ppm")
    click_center("fx_menu_new_folder_entry")
    check(explorer()["creating"], "Menü → New Folder öffnet die Eingabe")
    key("escape")
    check(not explorer()["creating"], "Escape bricht das Anlegen ab")
    explorer_click("gamma.txt", right=True)
    click_center("fx_menu_collapse_all")
    check(not entry("tmp")["expanded"], "Collapse All klappt alles zu")


def step_hidden_and_filter():
    print("--- Versteckte Dateien (.), Filter (/)")
    with open(os.path.join(FX, ".secret"), "w") as f:
        f.write("s\n")
    reveal("gamma.txt", ["tmp", "e2e_fx2"])
    explorer_click("gamma.txt")
    key("r", shift=True)  # neu laden
    check(".secret" not in names(), "versteckte Datei ist standardmäßig weg")
    key("dot")
    wait_for(lambda: ".secret" in names(), ". zeigt versteckte Dateien")
    check(explorer()["show_hidden"], "show_hidden ist gesetzt")
    key("dot")
    wait_for(lambda: ".secret" not in names(), ". blendet sie wieder aus")
    key("slash")
    check(explorer()["filter_active"], "/ öffnet das Filterfeld")
    rpc("type_text", ["gam"]); settle()
    visible = names()
    check(explorer()["filter"] == "gam" and "gamma.txt" in visible and "renamed.md" not in visible, f"Filter 'gam' zeigt nur Treffer: {visible[-4:]}")
    check("e2e_fx2" in visible and "tmp" in visible, "Elternordner der Treffer bleiben sichtbar")
    shot("e2e_explorer_filter.ppm")
    key("enter")
    check(not explorer()["filter_active"] and explorer()["filter"] == "gam", "Enter behält den Filter, Fokus zurück zur Navigation")
    key("slash")
    key("escape")
    check(explorer()["filter"] == "" and "renamed.md" in names(), "Escape leert den Filter")


def step_drag_drop():
    print("--- Drag & Drop verschiebt mit Bestätigung")
    explorer_click("gamma copy.txt")
    explorer_row_center("sub")  # scrollt bei Bedarf; danach beide Zeilen neu messen
    x0, y0 = explorer_row_center("gamma copy.txt")
    x1, y1 = explorer_row_center("sub")
    check(explorer_row_center("gamma copy.txt") == (x0, y0), "Quelle und Ziel gleichzeitig sichtbar")
    rpc("mouse_down", [x0, y0]); settle()
    for i in range(1, 6):
        rpc("move_mouse", [x0, y0 + (y1 - y0) * i / 5]); settle(3)
    rpc("mouse_up", [x1, y1]); settle(10)
    check(dialog_open() and ui_state()["dialog"] == "Move", "Drop auf einen Ordner fragt nach")
    key("enter")
    wait_for(lambda: os.path.exists(os.path.join(FX, "sub", "gamma copy.txt")), "Move verschiebt die Datei in den Ordner")
    check(not os.path.exists(os.path.join(FX, "gamma copy.txt")), "Quelle ist weg")


def step_gitignore():
    print("--- .gitignore-Einträge ausgegraut (tmp/ ist im Projekt ignoriert)")
    wait_for(lambda: entry("tmp") is not None and entry("tmp")["ignored"], "tmp gilt als ignoriert", timeout=10)
    check(entry("src") is not None and not entry("src")["ignored"], "src ist nicht ignoriert")
    reveal("gamma.txt", ["tmp", "e2e_fx2"])
    check(entry("gamma.txt")["ignored"], "Datei unter einem ignorierten Ordner ist ignoriert")
    shot("e2e_explorer_gitignore.ppm")


def step_sidebar_width_persist():
    print("--- Sidebar-Breite wird gemerkt, lange Namen mit Tooltip")
    st = explorer()
    x = st["viewport"]["x"] + st["viewport"]["w"]
    y = st["viewport"]["y"] + 100
    rpc("mouse_down", [x + 1, y]); settle()
    for i in range(1, 6):
        rpc("move_mouse", [x + 1 + 60 * i / 5, y]); settle(3)
    rpc("mouse_up", [x + 61, y]); settle(10)
    w = explorer()["width"]
    check(abs(w - (x + 61)) < 20 or w > st["width"] + 30, f"Splitter ziehen setzt die Breite ({st['width']:.0f} → {w:.0f})")
    state_file = os.path.join(XDG_CONFIG, "zid", "state")
    wait_for(lambda: os.path.exists(state_file) and f"sidebar_width={int(round(w))}" in open(state_file).read(), "Breite steht in der State-Datei")
    x0, y0 = explorer_row_center("gamma.txt")
    rpc("move_mouse", [x0, y0]); settle(10)
    time.sleep(0.9)
    settle(5)
    shot("e2e_explorer_tooltip.ppm")
    check(bounds("fx_tooltip")["found"], "Tooltip mit vollem Pfad nach 700 ms")


STEPS = [step_focus_and_letters, step_dialog_keyboard_trash, step_navigation, step_create_rename, step_clipboard, step_multi_select, step_context_menu, step_hidden_and_filter, step_drag_drop, step_gitignore, step_sidebar_width_persist]


def main():
    setup_fixture()
    log = open(os.path.join(ROOT, "tmp", "e2e_explorer.log"), "w")
    env = dict(os.environ, XDG_DATA_HOME=XDG, XDG_CONFIG_HOME=XDG_CONFIG)
    proc = subprocess.Popen(
        [os.path.join(ROOT, "zig-out", "bin", "zid"), "--headless", "--ai=off"],
        cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, env=env,
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
