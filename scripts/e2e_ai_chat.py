#!/usr/bin/env python3
"""Headless-E2E für den KI-Chat.

Lauf A (Standard): vulkan-ed ohne --ai=off gegen das laufende Ollama. Chat öffnen,
Frage senden, Antwort erscheint, Lade-Zustand endet.
Lauf B (--ai=off): Senden liefert sofort eine Erklärung statt endlos "thinking".

Voraussetzung für Lauf A: Ollama läuft und das Modell (Default gemma4:e2b) ist
installiert (`ollama list`). Aufruf: python3 scripts/e2e_ai_chat.py [--only-off]
"""
import os, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e2e_open_folder import ROOT, rpc, result_json, wait_port, settle, check, shot  # noqa: E402
from e2e_shortcuts import key, ui_state  # noqa: E402


def chat():
    return result_json("chat_state")


def wait_for(pred, timeout_s, what):
    t0 = time.time()
    while time.time() - t0 < timeout_s:
        st = chat()
        if pred(st):
            return st
        time.sleep(0.5)
    raise AssertionError(f"Timeout ({timeout_s}s): {what}; zuletzt {chat()}")


def start(extra_args, log_name):
    log = open(os.path.join(ROOT, "tmp", log_name), "w")
    proc = subprocess.Popen(
        [os.path.join(ROOT, "zig-out", "bin", "vulkan-ed"), "--headless"] + extra_args,
        cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
    )
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


def open_chat_and_send(text):
    rpc("open_chat")
    settle(10)
    st = ui_state()
    check(st["tabs"][st["active_tab"]]["kind"] == "chat", "Chat-Tab ist aktiv")
    rpc("type_text", [text])
    settle(5)
    check(rpc("get_chat_input") == text, "Frage steht im Eingabefeld")
    key("enter")


def run_with_ollama():
    print("--- A. Chat gegen Ollama: Frage senden, Antwort kommt")
    proc, log = start(["--ai=off"] if False else [], "e2e_ai_chat.log")
    try:
        t0 = time.time()
        st = wait_for(lambda s: s["status"] in ("ready", "failed", "model_missing", "none"), 90, "Agent-Warmup")
        check(st["status"] == "ready", f"Agent-Status nach Start: {st['status']} {st['detail']!r} (Warmup {time.time() - t0:.1f}s)")
        open_chat_and_send("Antworte nur mit dem Wort PONG")
        st = chat()
        check(st["loading"] and st["messages"][-1]["role"] == "user", "Nach Enter: Frage im Verlauf, Antwort wird geladen")
        st = wait_for(lambda s: not s["loading"], 180, "Antwort von Ollama")
        last = st["messages"][-1]
        check(last["role"] == "assistant" and len(last["content"].strip()) > 0, f"Antwort erhalten: {last['content'].strip()[:60]!r}")
        check("pong" in last["content"].lower(), "Antwort enthält PONG")
        shot("e2e_ai_chat.ppm")
    finally:
        stop(proc, log)


def run_ai_off():
    print("--- B. --ai=off: Senden erklärt sofort, kein endloses Laden")
    proc, log = start(["--ai=off"], "e2e_ai_chat_off.log")
    try:
        st = chat()
        check(st["status"] == "none", f"Agent-Status mit --ai=off: {st['status']}")
        open_chat_and_send("hallo")
        st = chat()
        check(not st["loading"], "Kein Lade-Zustand ohne Agent")
        last = st["messages"][-1]
        check(last["role"] == "assistant" and "not connected" in last["content"].lower(), f"Erklärung im Chat: {last['content'][:70]!r}")
        shot("e2e_ai_chat_off.ppm")
    finally:
        stop(proc, log)


def main():
    if "--only-off" not in sys.argv:
        run_with_ollama()
    run_ai_off()
    print("ALL PASSED")


if __name__ == "__main__":
    main()
