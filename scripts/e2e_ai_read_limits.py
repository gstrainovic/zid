#!/usr/bin/env python3
"""Headless-Messung: wie große Dateien kann der Agent per read_file lesen?

Je Fall ein frischer zid-Prozess (leere Historie, gleiche Ausgangslage). Die Fixture ist
echter Zig-Code aus src/, auf N Zeichen gekürzt, mit Markern in der ersten und letzten Zeile.
Gefragt wird nach der ersten oder der letzten Zeile. Gemessen: richtig beantwortet?,
Kontextfehler?, Dauer der Frage, Prompt-Token und prompt_ms aus den `usage:`-Logzeilen.

Aufruf: python3 scripts/e2e_ai_read_limits.py [--out tmp/read_limits.json] [größe:first|last ...]
Ohne Fälle läuft die Standardreihe. Das Ergebnis-JSON dient als Vorher/Nachher-Vergleich.
"""
import glob, json, os, re, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e2e_open_folder import ROOT, rpc, settle  # noqa: E402
from e2e_ai_chat import chat, wait_for, start, stop, send  # noqa: E402

DEFAULT_CASES = [(4000, "first"), (4000, "last"), (12000, "first"), (12000, "last"),
                 (20000, "first"), (20000, "last"), (28000, "first"), (40000, "first")]
FIX_DIR_REL = "tmp/agent_read"


def source_text():
    parts = []
    for p in sorted(glob.glob(os.path.join(ROOT, "src", "**", "*.zig"), recursive=True)):
        with open(p, encoding="utf-8") as f:
            parts.append(f.read())
    return "\n".join(parts)


def make_fixture(size):
    """Echter Code, auf ganze Zeilen um `size` Zeichen gekürzt, Marker vorn und hinten."""
    text = source_text()
    first = f"// ERSTE-ZEILE-{size}"
    last = f"// LETZTE-ZEILE-{size}"
    body = text[: size - len(first) - len(last) - 2]
    body = body[: body.rfind("\n")]
    content = f"{first}\n{body}\n{last}\n"
    rel = f"{FIX_DIR_REL}/code_{size}.zig"
    path = os.path.join(ROOT, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)
    return rel, first[3:], last[3:], len(content)


def usage_lines(log_path):
    with open(log_path, encoding="utf-8", errors="replace") as f:
        return [(int(m.group(1)), int(m.group(2)), float(m.group(3)))
                for m in re.finditer(r"usage: prompt_tokens=(\d+) completion_tokens=(\d+) prompt_ms=([\d.]+)", f.read())]


def run_case(size, which):
    rel, first_marker, last_marker, n = make_fixture(size)
    log_name = f"e2e_read_{size}_{which}.log"
    proc, log = start([], log_name)
    try:
        st, _ = wait_for(lambda s: s["status"] in ("ready", "failed", "model_missing", "none"), 120, "Agent-Warmup")
        if st["status"] != "ready":
            raise AssertionError(f"Agent nicht bereit: {st['status']} {st['detail']!r}")
        rpc("open_chat")
        settle(10)
        what = "erste" if which == "first" else "letzte"
        question = f"Lies {rel} und nenne mir nur die {what} Zeile, sonst nichts."
        before = len(chat()["messages"])
        send(question)
        t0 = time.time()
        st, _ = wait_for(lambda s: not s["loading"] and not s["pending_tools"], 600, f"Antwort ({size}, {which})")
        dt = time.time() - t0
        new = st["messages"][before:]
    finally:
        stop(proc, log)
    answer = new[-1]["content"] if new else ""
    marker = first_marker if which == "first" else last_marker
    tool_results = [m["content"] for m in new if m["role"] == "tool"]
    usage = usage_lines(os.path.join(ROOT, "tmp", log_name))
    return {
        "size": n, "which": which,
        "correct": marker in answer,
        "context_error": "context window" in answer,
        "read_file_calls": sum(1 for m in new for tc in (m.get("tool_calls") or []) if tc["function"]["name"] == "read_file"),
        "tool_result_chars": [len(t) for t in tool_results],
        "seconds": round(dt, 1),
        "usage": [{"prompt_tokens": p, "completion_tokens": c, "prompt_ms": ms} for p, c, ms in usage],
        "answer": answer[:160],
    }


def main():
    args = sys.argv[1:]
    out = os.path.join(ROOT, "tmp", "read_limits.json")
    if "--out" in args:
        i = args.index("--out")
        out = os.path.join(ROOT, args[i + 1])
        del args[i:i + 2]
    cases = [(int(a.split(":")[0]), a.split(":")[1]) for a in args] or DEFAULT_CASES
    results = []
    for size, which in cases:
        r = run_case(size, which)
        results.append(r)
        prompt = "/".join(str(u["prompt_tokens"]) for u in r["usage"])
        print(f"{r['size']:>6} {which:<5} correct={r['correct']!s:<5} ctx_err={r['context_error']!s:<5} "
              f"{r['seconds']:>6}s prompt_tokens={prompt} answer={r['answer'][:60]!r}", flush=True)
        with open(out, "w", encoding="utf-8") as f:
            json.dump(results, f, indent=1, ensure_ascii=False)
    print(f"Ergebnis: {out}")


if __name__ == "__main__":
    main()
