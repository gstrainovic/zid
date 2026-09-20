#!/usr/bin/env python3
"""Headless-E2E für den Explorer: Fokus, Buchstaben-Kürzel, Tastaturnavigation,
Dialog per Tastatur, Papierkorb, Anlegen, Kopieren/Ausschneiden/Einfügen,
Mehrfachauswahl, Kontextmenü. Aufruf: python3 scripts/e2e_explorer.py

Papierkorb: XDG_DATA_HOME zeigt auf tmp/xdg, damit nichts im echten Papierkorb landet.
"""
import os, shutil, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e2e_open_folder import ROOT, rpc, result_json, wait_port, settle, bounds, click_center, check, shot, start_zid, stop_zid  # noqa: E402
from e2e_shortcuts import key, explorer, explorer_click, explorer_row_center, ui_state, dialog_open  # noqa: E402
from e2e_pdf_pager import pixel  # noqa: E402
from e2e_md_preview import differs  # noqa: E402

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
    # Pfad ist prozentkodiert; der Windows-Trenner "\" steht dort als %5C.
    sep = "/" if os.sep == "/" else "%5C"
    check("Path=" in info and f"e2e_fx2{sep}alpha.txt" in info, "trashinfo enthält den Originalpfad")
    wait_for(lambda: "alpha.txt" not in names(), "Explorer zeigt alpha.txt nicht mehr")
    # Nach dem Löschen lädt der Explorer neu; der Ordner muss aufgeklappt bleiben,
    # sonst verliert man seine Stelle im Baum.
    e = entry("e2e_fx2")
    check(e is not None and e["expanded"], f"e2e_fx2 bleibt nach dem Löschen aufgeklappt (entry={e})")


def cursor_to(name):
    """Cursor per ↑/↓ auf `name` bewegen. Der Explorer sortiert nicht, die Reihenfolge ist
    die des Dateisystems (ext4 Hash-Reihenfolge, NTFS alphabetisch)."""
    order = names()
    cur = next(e["name"] for e in explorer()["entries"] if e["cursor"])
    delta = order.index(name) - order.index(cur)
    for _ in range(abs(delta)):
        key("down" if delta > 0 else "up")
    return abs(delta)


def step_navigation():
    print("--- Tastaturnavigation ↑↓←→ Enter")
    explorer_click("beta.txt")
    order = names()
    below = order[order.index("beta.txt") + 1] if order.index("beta.txt") + 1 < len(order) else None
    if below:
        key("down")
        check(entry(below)["cursor"], f"↓ setzt den Cursor auf {below}")
    n = cursor_to("sub")
    check(entry("sub")["cursor"], f"{n}× ↑/↓ setzt den Cursor auf den Ordner sub")
    check(entry("sub")["selected"], "Ordner ist markiert (vorher markierte ein Klick keine Ordner)")
    key("right")
    check(entry("sub")["expanded"] and "inner.txt" in names(), "→ klappt den Ordner auf")
    key("right")
    check(entry("inner.txt")["cursor"], "→ auf offenem Ordner geht zum ersten Kind")
    key("left")
    check(entry("sub")["cursor"], "← geht zum Elternordner")
    key("left")
    check(not entry("sub")["expanded"], "← klappt den Ordner zu")
    cursor_to("beta.txt")
    key("enter")
    wait_for(lambda: result_json("get_active_tab")["editor_file"].endswith("beta.txt"), "Enter öffnet beta.txt")
    check(ui_state()["explorer_focused"], "Fokus bleibt nach Enter im Explorer")
    key("escape")
    check(not ui_state()["explorer_focused"], "Escape gibt den Fokus an den Editor")


def drawn_text(want):
    """Steht `want` unter den gezeichneten Textstücken? Liest den Command-Dump des
    Screenshots (ZID_DEBUG=1). Der Zustand über RPC genügt nicht: die Anlege-Zeile
    zeichnete einmal den Text einer Kopie, die Clay schon nicht mehr hatte."""
    shot("e2e_explorer_drawn.ppm")
    with open(os.path.join(ROOT, "tmp", "e2e_explorer.log"), errors="replace") as f:
        lines = [ln for ln in f if "cmd[" in ln and " text " in ln]
    return any(f'"{want}"' in ln for ln in lines[-200:])


def step_create_rename():
    print("--- a/A legen an, r benennt um")
    explorer_click("beta.txt")
    key("a")
    check(explorer()["creating"], "a öffnet die Eingabe für eine neue Datei")
    rpc("type_text", ["neu.md"]); settle()
    check(drawn_text("neu.md"), "die Eingabezeile zeichnet den getippten Namen")
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
    print("--- Cursor im Umbenennen-Feld: Pos1, Links/Rechts, Entf")
    explorer_click("renamed.md")
    key("r")
    check(explorer()["renaming"], "r startet das Umbenennen erneut")
    key("home")
    rpc("type_text", ["x_"]); settle()
    shot("explorer_rename_caret.ppm")
    key("enter")
    wait_for(lambda: os.path.exists(os.path.join(FX, "x_renamed.md")), "Pos1 + Tippen ändert den Anfang des Namens")
    explorer_click("x_renamed.md")
    key("r")
    key("home")
    key("right")
    key("right")
    key("left")
    key("left")
    key("delete")
    key("delete")
    key("enter")
    wait_for(lambda: os.path.exists(os.path.join(FX, "renamed.md")), "Links/Rechts/Entf löschen das Präfix wieder")
    print("--- Klick ins Umbenennen-Feld setzt den Cursor")
    explorer_click("renamed.md")
    key("r")
    check(explorer()["renaming"], "r startet das Umbenennen")
    b = bounds("fx_rename_box")
    # Knapp hinter dem linken Innenrand: Cursor landet am Anfang, Feld bleibt offen
    rpc("click", [b["x"] + 7, b["y"] + b["h"] / 2]); settle()
    check(explorer()["renaming"], "Klick ins Feld bricht das Umbenennen nicht ab")
    rpc("type_text", ["k_"]); settle()
    key("enter")
    wait_for(lambda: os.path.exists(os.path.join(FX, "k_renamed.md")), "Klick an den Anfang, Tippen ändert das Präfix")
    explorer_click("k_renamed.md")
    key("r")
    key("home")
    key("delete")
    key("delete")
    key("enter")
    wait_for(lambda: os.path.exists(os.path.join(FX, "renamed.md")), "Präfix wieder entfernt")


def step_clipboard():
    print("--- y/x/p kopieren, ausschneiden, einfügen; Ctrl+D dupliziert; c kopiert den Pfad")
    explorer_click("gamma.txt")
    key("c")
    check(ui_state()["clipboard_text"] == os.path.join(FX, "gamma.txt"), "c kopiert den absoluten Pfad")
    key("c", shift=True)
    rel = ui_state()["clipboard_text"]
    check(rel == os.path.join("tmp", "e2e_fx2", "gamma.txt"), f"Shift+C kopiert den Projekt-relativen Pfad ({rel})")
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
    key("home")
    rpc("type_text", ["x"]); settle()
    check(explorer()["filter"] == "xgam", f"Pos1 + Tippen ändert den Filteranfang: {explorer()['filter']}")
    key("delete")
    check(explorer()["filter"] == "xam", f"Entf löscht hinter dem Cursor: {explorer()['filter']}")
    key("backspace")
    rpc("type_text", ["g"]); settle()
    check(explorer()["filter"] == "gam" and "gamma.txt" in names(), "Backspace + g stellt 'gam' her, Treffer sind zurück")
    key("end")
    b = bounds("fx_filter_box")
    rpc("click", [b["x"] + 7, b["y"] + b["h"] / 2]); settle()
    rpc("type_text", ["y"]); settle()
    check(explorer()["filter_active"] and explorer()["filter"] == "ygam", f"Klick an den Feldanfang setzt den Cursor: {explorer()['filter']}")
    key("backspace")
    check(explorer()["filter"] == "gam", "Filter wieder 'gam'")
    key("enter")
    check(not explorer()["filter_active"] and explorer()["filter"] == "gam", "Enter behält den Filter, Fokus zurück zur Navigation")
    key("slash")
    key("escape")
    check(explorer()["filter"] == "" and "renamed.md" in names(), "Escape leert den Filter")


def rows_in_view(*paths):
    """Zeilenmitten mehrerer Einträge aus EINEM Snapshot, nach Pfad statt Name gesucht.
    Zwei getrennte explorer_row_center-Aufrufe scrollen je für sich: die erste Position
    stimmte dann nicht mehr, und der Drop traf eine Datei im Projekt-Root."""
    for _ in range(40):
        ex = explorer()
        by_path = {e["path"]: e["index"] for e in ex["entries"]}
        missing = [p for p in paths if p not in by_path]
        if missing:
            raise AssertionError(f"Explorer-Einträge fehlen: {missing}")
        vp, rh = ex["viewport"], ex["row_height"]
        ys = [vp["y"] + by_path[p] * rh + rh / 2 - ex["scroll"] for p in paths]
        if all(vp["y"] <= y < vp["y"] + vp["h"] for y in ys):
            return [(vp["x"] + 60, y) for y in ys], ex["scroll"]
        center = vp["y"] + vp["h"] / 2
        mid = (min(ys) + max(ys)) / 2
        lines = max(1, round(abs(mid - center) / 60))  # scrollLines: 60 px je Zeile
        rpc("scroll", [vp["x"] + 60, center, -lines if mid >= center else lines])
        settle()
    raise AssertionError(f"{paths} nicht gleichzeitig in den Viewport gescrollt")


def step_drag_drop():
    print("--- Drag & Drop verschiebt mit Bestätigung")
    explorer_click("gamma copy.txt")
    src_path, dst_path = os.path.join(FX, "gamma copy.txt"), os.path.join(FX, "sub")
    [(x0, y0), (x1, y1)], scroll = rows_in_view(src_path, dst_path)
    check(rows_in_view(src_path, dst_path)[1] == scroll, "Quelle und Ziel gleichzeitig sichtbar")
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


def step_scrollbar():
    print("--- Scrollbalken: Lage am Baum, Blättern, Ziehen, Pfeil-Cursor, gezeichnet")
    reveal("gamma.txt", ["tmp", "e2e_fx2"])  # tmp/ aufgeklappt: Baum ist viele Seiten lang
    explorer_click("gamma.txt")
    key("slash")  # Filterzeile offen, Filter leer: der Baum beginnt tiefer als die Sidebar
    check(explorer()["filter_active"], "/ öffnet das Filterfeld")
    vp = explorer()["viewport"]
    rpc("scroll", [vp["x"] + 60, vp["y"] + vp["h"] / 2, 10000]); settle()
    check(explorer()["scroll"] == 0, "ganz oben")
    track = bounds("file_explorer_scrollbar_track")
    thumb = bounds("file_explorer_scrollbar_thumb")
    check(abs(track["y"] - vp["y"]) < 1 and abs(track["h"] - vp["h"]) < 1,
          f"Track deckt genau den Baum ab (Track y={track['y']:.0f} h={track['h']:.0f}, Baum y={vp['y']:.0f} h={vp['h']:.0f})")
    check(abs(track["x"] + track["w"] - (vp["x"] + vp["w"])) < 1, "Track am rechten Rand des Baums")
    check(abs(thumb["y"] - track["y"]) < 1 and thumb["h"] < track["h"] / 2, "Thumb oben, kürzer als eine halbe Seite")
    # Cursorform: Pfeil über Thumb und Track
    rpc("move_mouse", [thumb["x"] + thumb["w"] / 2, thumb["y"] + thumb["h"] / 2]); settle()
    check(ui_state()["cursor"] == "arrow", f"Pfeil über dem Thumb ({ui_state()['cursor']})")
    rpc("move_mouse", [track["x"] + track["w"] / 2, track["y"] + track["h"] - 5]); settle()
    check(ui_state()["cursor"] == "arrow", f"Pfeil über dem Track ({ui_state()['cursor']})")
    tx = track["x"] + track["w"] / 2
    # Klick unten in den Track blättert eine Seite (wie Editor und Vorschau), springt nicht ans Ende
    def tree_snapshot():
        ex = explorer()
        return [(e["path"], e["expanded"], e["cursor"]) for e in ex["entries"]]
    before = tree_snapshot()
    rpc("click", [tx, track["y"] + track["h"] - 5]); settle()
    s1 = explorer()["scroll"]
    check(abs(s1 - vp["h"]) < 2, f"Klick unter dem Thumb blättert eine Seite ({s1:.0f}, Seite {vp['h']:.0f})")
    rpc("click", [tx, track["y"] + 3]); settle()
    check(explorer()["scroll"] == 0, f"Klick über dem Thumb blättert zurück ({explorer()['scroll']:.0f})")
    check(tree_snapshot() == before, "Klicks auf den Balken treffen keine Zeile darunter (Auswahl, Aufklappen)")
    # Thumb ziehen: halber freier Track = halber Scrollweg, Rückweg bis ganz oben klemmt auf 0
    thumb = bounds("file_explorer_scrollbar_thumb")
    free = track["h"] - thumb["h"]
    x0, y0 = tx, thumb["y"] + thumb["h"] / 2
    rpc("mouse_down", [x0, y0]); settle()
    for i in range(1, 6):
        rpc("move_mouse", [x0, y0 + free / 2 * i / 5]); settle(3)
    mid = explorer()["scroll"]
    # Beim Ziehen über die Vorschau hinaus bleibt der Pfeil (kein I-Beam des Textes darunter)
    rpc("move_mouse", [700, y0 + free / 2]); settle(3)
    check(ui_state()["cursor"] == "arrow", f"Pfeil beim Ziehen über der Vorschau ({ui_state()['cursor']})")
    rpc("move_mouse", [x0, y0 - 200]); settle(3)
    top = explorer()["scroll"]
    rpc("mouse_up", [x0, y0 - 200]); settle()
    rpc("move_mouse", [x0, y0 + 50]); settle()
    check(explorer()["scroll"] == top == 0, f"Ziehen über den Anfang klemmt auf 0 ({top:.0f})")
    thumb2 = bounds("file_explorer_scrollbar_thumb")
    check(mid > vp["h"] and abs(thumb2["y"] - track["y"]) < 1, f"Ziehen scrollt ({mid:.0f}), Thumb wieder oben")
    # Screenshot zuletzt: er schreibt nach tmp/, der Watcher lädt den Baum neu und scrollt zur
    # Auswahl (gamma.txt) — mitten im Step verschöbe das die Scrollposition.
    shot("e2e_explorer_scrollbar.ppm")
    on_thumb = pixel("e2e_explorer_scrollbar.ppm", tx, thumb2["y"] + thumb2["h"] / 2)
    on_track = pixel("e2e_explorer_scrollbar.ppm", tx, thumb2["y"] + thumb2["h"] + 40)
    check(differs(on_thumb, on_track), f"Thumb ist gezeichnet ({on_thumb} neben Track {on_track})")
    key("escape")


STEPS = [step_focus_and_letters, step_dialog_keyboard_trash, step_navigation, step_create_rename, step_clipboard, step_multi_select, step_context_menu, step_hidden_and_filter, step_drag_drop, step_gitignore, step_scrollbar, step_sidebar_width_persist]


def main():
    setup_fixture()
    log = open(os.path.join(ROOT, "tmp", "e2e_explorer.log"), "w")
    # ZID_DEBUG=1: jeder Screenshot listet die Render-Commands mit Text. Nur damit
    # sieht der Test, was wirklich gezeichnet wurde — der Zustand über RPC sagt es nicht.
    env = dict(os.environ, XDG_DATA_HOME=XDG, XDG_CONFIG_HOME=XDG_CONFIG, ZID_DEBUG="1")
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
