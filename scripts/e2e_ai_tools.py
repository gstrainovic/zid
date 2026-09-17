#!/usr/bin/env python3
"""Headless-E2E: der Agent bedient den Editor über Werkzeuge.

Braucht das konfigurierte KI-Backend (Default llama-server + Qwen3-4B). Prüft:
1. Editor-Kommando per Chat (toggle_explorer) → Explorer aus und wieder an
2. Datei anlegen und öffnen ohne zweites Pane → Split entsteht, Datei im neuen Pane,
   Fokus bleibt im Chat
3. Datei lesen (read_file) → Antwort nennt den Inhalt
4. Kleine Änderung (replace_text) → kein Dialog, offener Tab zeigt den neuen Inhalt
5. Überschreiben → Bestätigungsdialog; Deny → Datei unverändert, Agent meldet Ablehnung
6. Pfad außerhalb des Projekts wird abgelehnt
Aufruf: python3 scripts/e2e_ai_tools.py
"""
import os, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e2e_open_folder import ROOT, rpc, result_json, wait_port, settle, check, shot, click_center  # noqa: E402
from e2e_shortcuts import key, ui_state  # noqa: E402
from e2e_ai_chat import chat, wait_for, start, stop, send  # noqa: E402

FIXTURE_REL = "tmp/agent_e2e/hello.py"
FIXTURE = os.path.normpath(os.path.join(ROOT, FIXTURE_REL))  # Windows: file_text vergleicht den Pfad wörtlich, mit Backslashes


def tool_names(msgs):
    names = []
    for m in msgs:
        for tc in m.get("tool_calls") or []:
            names.append(tc["function"]["name"])
    return names


def ask(text, timeout=180):
    """Frage senden, auf Ende der Runde warten (inkl. Werkzeugrunden), neue Nachrichten liefern."""
    before = len(chat()["messages"])
    send(text)
    st, dt = wait_for(lambda s: not s["loading"] and not s["pending_tools"] and not ui_state()["agent_confirm_pending"], timeout, f"Antwort auf {text!r}")
    return st, st["messages"][before:], dt


def active_kind():
    s = ui_state()
    return s["tabs"][s["active_tab"]]["kind"] if s["active_tab"] is not None else None


def main():
    if os.path.exists(FIXTURE):
        os.remove(FIXTURE)
    proc, log = start([], "e2e_ai_tools.log")
    try:
        st, dt = wait_for(lambda s: s["status"] in ("ready", "failed", "model_missing", "none"), 120, "Agent-Warmup")
        check(st["status"] == "ready", f"Agent bereit ({st['title']}, {dt:.1f}s)")
        rpc("open_chat")
        settle(10)

        print("--- 1. Editor-Kommando per Chat")
        st, new, dt = ask("Blende den Datei-Explorer aus.")
        # gemma4:e2b ruft den Enum-Wert direkt als Werkzeug auf; zid führt ihn als command aus
        names = tool_names(new)
        check("command" in names or "toggle_explorer" in names, f"Modell ruft das command-Werkzeug ({names}, {dt:.1f}s)")
        check(not ui_state()["show_file_explorer"], "Explorer ist ausgeblendet")
        st, new, dt = ask("Blende den Datei-Explorer wieder ein.")
        check(ui_state()["show_file_explorer"], f"Explorer ist wieder da ({dt:.1f}s)")
        check(new[-1]["role"] == "assistant" and not new[-1].get("tool_calls"), f"Abschließende Antwort: {new[-1]['content'][:70]!r}")

        print("--- 2. Datei anlegen und öffnen: Split entsteht, Chat bleibt im Fokus")
        check(ui_state()["pane_count"] == 1, "Start mit einem Pane")
        st, new, dt = ask(f"Erstelle die Datei {FIXTURE_REL} mit einem Python-Programm, das nach dem Namen fragt und dann 'Hallo, <name>!' ausgibt. Öffne sie danach im Editor.")
        names = tool_names(new)
        check("write_file" in names and "open_file" in names, f"write_file + open_file aufgerufen ({names}, {dt:.1f}s)")
        check(os.path.exists(FIXTURE), "Datei existiert auf der Platte")
        content = open(FIXTURE).read() if os.path.exists(FIXTURE) else ""
        check("input(" in content and "print(" in content, f"Inhalt ist ein Python-Programm ({len(content)} Zeichen)")
        s = ui_state()
        check(s["pane_count"] == 2, f"Editor wurde automatisch geteilt ({s['pane_count']} Panes)")
        check(any(p.endswith("hello.py") for p in s["all_tabs"]), "Datei ist als Tab geöffnet")
        check(active_kind() == "chat", f"Fokus bleibt im Chat (aktiver Tab: {active_kind()})")
        ft = result_json("file_text", [FIXTURE])
        check(ft["open"] and ft["text"].strip() == content.strip(), "Buffer im Nachbar-Pane ist geladen (ohne Fokuswechsel)")
        shot("e2e_ai_tools_write.ppm")

        print("--- 3. Datei lesen")
        st, new, dt = ask(f"Lies {FIXTURE_REL} und nenne mir nur die erste Zeile, sonst nichts.")
        check("read_file" in tool_names(new), f"read_file aufgerufen ({dt:.1f}s)")
        first_line = content.splitlines()[0].strip() if content else ""
        check(first_line[:12] in new[-1]["content"], f"Antwort enthält die erste Zeile: {new[-1]['content'][:80]!r}")

        print("--- 4. Kleine Änderung: kein Dialog, offener Tab lädt neu")
        st, new, dt = ask(f"Ersetze in {FIXTURE_REL} das Wort Hallo durch Servus. Nutze replace_text mit old='Hallo' und new='Servus'.")
        check("replace_text" in tool_names(new), f"replace_text aufgerufen ({dt:.1f}s)")
        check(not ui_state()["agent_confirm_pending"], "Kein Bestätigungsdialog für eine kleine Änderung")
        content = open(FIXTURE).read()
        check("Servus" in content, "Datei enthält die Änderung")
        ft = result_json("file_text", [FIXTURE])
        check(ft["open"] and "Servus" in ft["text"], "Offener Tab zeigt den neuen Inhalt")
        check(not any(t["path"].endswith("hello.py") and t["modified"] for t in ui_state()["tabs"]), "Tab gilt nicht als ungespeichert")

        print("--- 5. Überschreiben braucht Bestätigung; Deny lässt die Datei in Ruhe")
        before_content = content
        send(f"Überschreibe {FIXTURE_REL} mit genau einer Zeile: print('ersetzt')")
        st, dt = wait_for(lambda s: ui_state()["agent_confirm_pending"] or (not s["loading"] and not s["pending_tools"]), 120, "Bestätigungsdialog")
        u = ui_state()
        check(u["agent_confirm_pending"] and u["dialog"] == "AI agent", f"Dialog 'AI agent' offen ({dt:.1f}s)")
        shot("e2e_ai_tools_confirm.ppm")
        click_center("Deny")
        st, dt = wait_for(lambda s: not s["loading"] and not s["pending_tools"], 120, "Antwort nach Deny")
        check(open(FIXTURE).read() == before_content, "Datei unverändert")
        last_tool = [m for m in st["messages"] if m["role"] == "tool"][-1]
        check("denied" in last_tool["content"], f"Werkzeugergebnis meldet Ablehnung: {last_tool['content'][:60]!r}")

        print("--- 6. Pfad außerhalb des Projekts")
        st, new, dt = ask("Lies die Datei /etc/hostname und sag mir den Inhalt.")
        # Qwen3 ruft read_file und bekommt die Ablehnung; gemma4 lehnt selbst ab, ohne Werkzeug.
        tools_msgs = [m for m in new if m["role"] == "tool"]
        check(all("outside the project" in m["content"] for m in tools_msgs), f"Zugriff abgelehnt ({len(tools_msgs)} Werkzeugaufrufe, {dt:.1f}s)")
        shot("e2e_ai_tools_done.ppm")
        print("ALL PASSED")
    finally:
        stop(proc, log)


if __name__ == "__main__":
    main()
