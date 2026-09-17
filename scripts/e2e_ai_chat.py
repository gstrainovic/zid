#!/usr/bin/env python3
"""Headless-E2E für den KI-Chat.

Lauf A (Standard): zid ohne --ai=off gegen das konfigurierte Backend
(Default: llama-server + Qwen3-4B aus ~/projects/ki, sonst Ollama). Prüft:
Warmup, Streaming (erstes Textstück kommt schnell), Escape bricht ab,
kurze Frage wird vollständig beantwortet.
Lauf B (--ai=off): Senden liefert sofort eine Erklärung statt endlos "thinking".

Aufruf: python3 scripts/e2e_ai_chat.py [--only-off]
"""
import os, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e2e_open_folder import ROOT, rpc, result_json, wait_port, settle, check, shot, start_zid  # noqa: E402
from e2e_shortcuts import key, ui_state  # noqa: E402


def chat():
    return result_json("chat_state")


def wait_for(pred, timeout_s, what):
    t0 = time.time()
    while time.time() - t0 < timeout_s:
        st = chat()
        if pred(st):
            return st, time.time() - t0
        time.sleep(0.25)
    raise AssertionError(f"Timeout ({timeout_s}s): {what}; zuletzt {chat()}")


def start(extra_args, log_name):
    log = open(os.path.join(ROOT, "tmp", log_name), "w")
    proc = start_zid(["--headless"] + extra_args, log)
    wait_port(proc)
    settle(20)
    return proc, log


def stop(proc, log):
    try:
        rpc("shutdown")
    except Exception:
        pass
    try:
        proc.wait(timeout=15)
    except subprocess.TimeoutExpired:
        proc.kill()
    log.close()


def send(text):
    rpc("focus_chat")  # Agent-Aktionen (open_file) können das aktive Pane gewechselt haben
    settle()
    rpc("type_text", [text])
    settle(5)
    check(rpc("get_chat_input") == text, "Frage steht im Eingabefeld")
    key("enter")


def run_with_backend():
    print("--- A. Chat gegen das Backend: Warmup, Streaming, Escape, Antwort")
    proc, log = start([], "e2e_ai_chat.log")
    try:
        st, dt = wait_for(lambda s: s["status"] in ("ready", "failed", "model_missing", "none"), 120, "Agent-Warmup")
        check(st["status"] == "ready", f"Agent-Status nach Start: {st['status']} {st['detail']!r} (Warmup {dt:.1f}s)")
        print(f"     Backend: {st['title']}")

        rpc("open_chat")
        settle(10)
        s = ui_state()
        check(s["tabs"][s["active_tab"]]["kind"] == "chat", "Chat-Tab ist aktiv")

        # 1) Lange Antwort: Streaming muss schnell sichtbar werden, Escape bricht ab.
        # Vor dem ersten Delta steht die Prompt-Auswertung (System-Prompt plus Werkzeug-JSON,
        # ~1360 Token); auf reiner CPU sind das ~50 tok/s (i5-13500T, 8–14 Threads gleich),
        # also ~22 s mit Streuung bis nahe 30. Auf der GPU bleibt die Grenze eng. Die
        # Prompt-Grösse steht im zid-Log als `usage:`-Zeile.
        first_delta_s = 90 if st["title"].endswith("· CPU") else 30
        send("Erkläre ausführlich in etwa 400 Wörtern, was die Vulkan-Grafik-API ist.")
        st, dt = wait_for(lambda s: s["streaming_len"] > 0 or not s["loading"], first_delta_s, "erstes Streaming-Delta")
        check(st["loading"] and st["streaming_len"] > 0, f"Erstes Textstück nach {dt:.1f}s ({st['streaming_len']} Zeichen)")
        time.sleep(2.0)
        grown = chat()["streaming_len"]
        check(grown > st["streaming_len"], f"Antwort wächst weiter ({grown} Zeichen)")
        shot("e2e_ai_stream.ppm")
        key("escape")
        st, dt = wait_for(lambda s: not s["loading"], 20, "Abbruch nach Escape")
        last = st["messages"][-1]
        check(last["role"] == "assistant" and "abgebrochen" in last["content"], f"Escape bricht ab, Teilantwort bleibt ({len(last['content'])} Zeichen, {dt:.1f}s)")
        check(st["streaming_len"] == 0 and st["status"] == "ready", "Streaming-Puffer geleert, Agent weiter bereit")

        # 2) Kurze Frage läuft vollständig durch
        send("Antworte nur mit dem Wort PONG")
        st, dt = wait_for(lambda s: not s["loading"], 120, "Antwort")
        last = st["messages"][-1]
        check(last["role"] == "assistant" and "pong" in last["content"].lower(), f"Antwort erhalten: {last['content'].strip()[:60]!r} ({dt:.1f}s)")
        code_only_answer()
        shot("e2e_ai_chat.ppm")
    finally:
        stop(proc, log)


def code_only_answer():
    """Antwort, die nur aus einem Codeblock besteht (endet mit ``` ohne Newline): brachte
    zigdown zum Absturz (leerer Tag in handleLineCode). Der Chat muss danach noch leben."""
    send("Reply only with a zig code block for hello world, no explanation.")
    st, dt = wait_for(lambda s: not s["loading"], 120, "Codeblock-Antwort fertig")
    content = st["messages"][-1]["content"]
    check("```" in content, f"Antwort enthält einen Codeblock ({dt:.1f}s)")
    settle(10)
    check(chat()["status"] == "ready", "Chat lebt nach dem Rendern des Codeblocks weiter")


def input_newline_and_send():
    """Eingabefeld ist der CodeEditor: Shift+Enter bricht um, Enter sendet und leert das Feld."""
    rpc("focus_chat"); settle()
    rpc("type_text", ["zeile eins"]); settle(5)
    rpc("key_press_mods", ["enter", False, True]); settle(5)
    rpc("type_text", ["zeile zwei"]); settle(5)
    check(rpc("get_chat_input") == "zeile eins\nzeile zwei", f"Shift+Enter macht eine neue Zeile: {rpc('get_chat_input')!r}")
    # Klick in die erste Zeile des Eingabefelds setzt den Cursor dorthin (Editor kennt seine Box)
    bx, by, bw, bh = chat()["input_bounds"]
    rpc("click", [bx + bw - 40, by + 20]); settle(5)
    check(chat()["input_cursor"] == [0, len("zeile eins")], f"Klick rechts in Zeile 1 setzt den Cursor ans Zeilenende: {chat()['input_cursor']}")
    key("end")
    key("down")
    key("end")
    before = len(chat()["messages"])
    key("enter"); settle(10)
    check(rpc("get_chat_input") == "", "Enter leert das Eingabefeld")
    check(len(chat()["messages"]) > before and chat()["messages"][before]["content"] == "zeile eins\nzeile zwei", "mehrzeilige Nachricht wurde gesendet")


def select_in_bubble():
    """Text in einer Nachrichten-Bubble markieren: Ziehen ueber die erste Zeile der
    Assistant-Antwort liefert genau deren Anfang, Escape hebt auf."""
    print("--- Textauswahl in einer Chat-Bubble")
    msgs = chat()["messages"]
    idx = next(i for i, m in enumerate(msgs) if m["role"] == "assistant")
    l0 = result_json("chat_line_bounds", [idx, 0])
    check(l0["found"] and l0["h"] > 0, f"Zeile 0 der Antwort im Layout ({l0})")
    rpc("mouse_down", [l0["x"] + 1, l0["y"] + l0["h"] / 2]); settle(4)
    rpc("mouse_up", [l0["x"] + l0["w"] + 20, l0["y"] + l0["h"] / 2]); settle(6)
    got = result_json("md_selection")["text"]
    check(got and msgs[idx]["content"].startswith(got), f"Auswahl ist der Anfang der Antwort: {got!r}")
    key("escape")
    check(result_json("md_selection")["text"] is None, "Escape hebt die Auswahl auf")


def run_ai_off():
    print("--- B. --ai=off: Senden erklärt sofort, kein endloses Laden")
    proc, log = start(["--ai=off"], "e2e_ai_chat_off.log")
    try:
        st = chat()
        check(st["status"] == "none", f"Agent-Status mit --ai=off: {st['status']}")
        rpc("open_chat")
        settle(10)
        send("hallo")
        st = chat()
        check(not st["loading"], "Kein Lade-Zustand ohne Agent")
        last = st["messages"][-1]
        check(last["role"] == "assistant" and "not connected" in last["content"].lower(), f"Erklärung im Chat: {last['content'][:70]!r}")
        input_newline_and_send()
        shot("e2e_ai_chat_off.ppm")
        select_in_bubble()
    finally:
        stop(proc, log)


def main():
    if "--only-off" not in sys.argv:
        run_with_backend()
    run_ai_off()
    print("ALL PASSED")


if __name__ == "__main__":
    main()
