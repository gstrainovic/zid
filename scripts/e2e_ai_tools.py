#!/usr/bin/env python3
"""Headless-E2E: der Agent bedient den Editor über Werkzeuge.

Braucht das konfigurierte KI-Backend (Default llama-server + Qwen3-4B). Prüft:
1. Editor-Kommando per Chat (split_vertical) → Pane-Zahl steigt
2. Datei anlegen (write_file) → existiert; öffnen (open_file) → Tab aktiv
3. Datei lesen (read_file) → Antwort nennt den Inhalt
4. Überschreiben → Bestätigungsdialog; Deny → Datei unverändert, Agent meldet Ablehnung
5. Pfad außerhalb des Projekts wird abgelehnt
Aufruf: python3 scripts/e2e_ai_tools.py
"""
import os, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e2e_open_folder import ROOT, rpc, result_json, wait_port, settle, check, shot, click_center  # noqa: E402
from e2e_shortcuts import key, ui_state  # noqa: E402
from e2e_ai_chat import chat, wait_for, start, stop, send  # noqa: E402

FIXTURE_REL = "tmp/agent_e2e/hello.py"
FIXTURE = os.path.join(ROOT, FIXTURE_REL)


def tool_names(st):
    names = []
    for m in st["messages"]:
        for tc in m.get("tool_calls") or []:
            names.append(tc["function"]["name"])
    return names


def ask(text, timeout=180):
    """Frage senden, auf Ende der Runde warten (inkl. Werkzeugrunden), Zustand liefern."""
    before = len(chat()["messages"])
    send(text)
    st, dt = wait_for(lambda s: not s["loading"] and not s["pending_tools"] and not ui_state()["agent_confirm_pending"], timeout, f"Antwort auf {text!r}")
    return st, st["messages"][before:], dt


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
        panes = ui_state()["pane_count"]
        st, new, dt = ask("Teile den Editor vertikal.")
        check("command" in tool_names({"messages": new}), f"Modell ruft das command-Werkzeug ({dt:.1f}s)")
        check(ui_state()["pane_count"] == panes + 1, f"Pane-Zahl {panes} → {ui_state()['pane_count']}")
        check(new[-1]["role"] == "assistant" and not new[-1].get("tool_calls"), f"Abschließende Antwort: {new[-1]['content'][:70]!r}")

        print("--- 2. Datei anlegen und öffnen")
        st, new, dt = ask(f"Erstelle die Datei {FIXTURE_REL} mit einem Python-Programm, das nach dem Namen fragt und dann 'Hallo, <name>!' ausgibt. Öffne sie danach im Editor.")
        names = tool_names({"messages": new})
        check("write_file" in names, f"write_file aufgerufen ({names}, {dt:.1f}s)")
        check(os.path.exists(FIXTURE), "Datei existiert auf der Platte")
        content = open(FIXTURE).read() if os.path.exists(FIXTURE) else ""
        check("input(" in content and "print(" in content, f"Inhalt ist ein Python-Programm ({len(content)} Zeichen)")
        s = ui_state()
        check(any(p.endswith("hello.py") for p in s["all_tabs"]), "Datei ist als Tab geöffnet")
        check(s["tabs"][s["active_tab"]]["path"].endswith("hello.py"), "Datei-Tab liegt im anderen Pane und ist dort aktiv")
        shot("e2e_ai_tools_write.ppm")

        print("--- 3. Datei lesen")
        st, new, dt = ask(f"Lies {FIXTURE_REL} und nenne mir nur die erste Zeile, sonst nichts.")
        check("read_file" in tool_names({"messages": new}), f"read_file aufgerufen ({dt:.1f}s)")
        first_line = content.splitlines()[0].strip() if content else ""
        answer = new[-1]["content"]
        check(first_line[:12] in answer, f"Antwort enthält die erste Zeile: {answer[:80]!r}")

        print("--- 4. Überschreiben braucht Bestätigung; Deny lässt die Datei in Ruhe")
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

        print("--- 5. Pfad außerhalb des Projekts")
        st, new, dt = ask("Lies die Datei /etc/hostname und sag mir den Inhalt.")
        tools_msgs = [m for m in new if m["role"] == "tool"]
        check(tools_msgs and all("outside the project" in m["content"] for m in tools_msgs), f"Zugriff abgelehnt ({dt:.1f}s)")
        check(not any("hostname" in m["content"] and "outside" not in m["content"] for m in tools_msgs), "Kein Dateiinhalt durchgereicht")
        shot("e2e_ai_tools_done.ppm")
        print("ALL PASSED")
    finally:
        stop(proc, log)


if __name__ == "__main__":
    main()
