#!/usr/bin/env python3
"""Clay-Element-ID (Zahl aus „duplicate_id unter Elternelement id=…“) auf einen Namen zurückrechnen.

Port von Clay__HashString; probiert alle ID-Namen aus src/ mit Index 0..LIMIT (IDI) durch.
Zeiger-gesalzene IDs (IDI(name, @intFromPtr(...))) sind nicht rückrechenbar und werden als
„unbekannt“ gemeldet. Aufruf: python3 scripts/clay_id_decode.py <id> [<id> ...] [--parent <eltern-id>]
"""
import os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MASK = 0xFFFFFFFF
LIMIT = 5000


def clay_hash(key: bytes, offset: int, seed: int = 0) -> int:
    base = seed
    for c in key:
        base = (base + c) & MASK
        base = (base + (base << 10)) & MASK
        base ^= base >> 6
    h = (base + offset) & MASK
    h = (h + (h << 10)) & MASK
    h ^= h >> 6
    h = (h + (h << 3)) & MASK
    h ^= h >> 11
    h = (h + (h << 15)) & MASK
    return (h + 1) & MASK


def id_names():
    # Kein "-h": das ist bei ripgrep --help. Mit dem Flag gab rg die Hilfe aus, die
    # Namensliste blieb leer und jede ID galt als „unbekannt".
    res = subprocess.run(["rg", "-o", "--no-filename", r'ElementId\.(ID|IDI|localID|localIDI)\("[A-Za-z0-9_]+"', "src"],
                         cwd=ROOT, capture_output=True, text=True)
    if res.returncode not in (0, 1):
        print(f"rg fehlgeschlagen ({res.returncode}): {res.stderr.strip()[:200]}", file=sys.stderr)
    out = res.stdout
    names = set(re.findall(r'"([A-Za-z0-9_]+)"', out))
    # Dynamische Präfixe (allocPrint "md_run_…", "ai_msg_…", "menu_item_…") grob abdecken
    names |= {"md_run", "ai_msg", "menu_item_", "tab_menu_", "editor_menu_", "md_menu_", "term_menu_", "fx_menu_"}
    return sorted(names)


def main():
    args = [a for a in sys.argv[1:]]
    if not args:
        print(__doc__)
        return

    # `--parent N`: Clay salzt jede ID mit dem Elternelement (Clay__HashString(name, i, parent)).
    # Ohne den Wert lassen sich nur IDs unter der Wurzel zurückrechnen; das Log nennt beide
    # Zahlen ("duplicate_id id=… unter Elternelement id=…").
    parents = [0]
    if "--parent" in args:
        i = args.index("--parent")
        parents = [int(args[i + 1]), 0]
        del args[i:i + 2]

    targets = {int(a) for a in args}
    names = id_names()
    found = {}
    for name in names:
        key = name.encode()
        for parent in parents:
            for idx in range(LIMIT):
                h = clay_hash(key, idx, parent)
                if h in targets:
                    label = name if idx == 0 else f'IDI("{name}", {idx})'
                    if parent:
                        label += f" (unter Elternelement {parent})"
                    found.setdefault(h, []).append(label)
    for t in sorted(targets):
        print(f"{t}: {', '.join(found.get(t, ['unbekannt (zeiger-gesalzen oder dynamischer Name)']))}")


if __name__ == "__main__":
    main()
