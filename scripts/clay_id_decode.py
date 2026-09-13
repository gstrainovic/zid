#!/usr/bin/env python3
"""Clay-Element-ID (Zahl aus „duplicate_id unter Elternelement id=…“) auf einen Namen zurückrechnen.

Port von Clay__HashString; probiert alle ID-Namen aus src/ mit Index 0..LIMIT (IDI) durch.
Zeiger-gesalzene IDs (IDI(name, @intFromPtr(...))) sind nicht rückrechenbar und werden als
„unbekannt“ gemeldet. Aufruf: python3 scripts/clay_id_decode.py <id> [<id> ...]
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
    out = subprocess.run(["rg", "-o", "-h", "--no-filename", r'ElementId\.(ID|IDI|localID|localIDI)\("[A-Za-z0-9_]+"', "src"],
                         cwd=ROOT, capture_output=True, text=True).stdout
    names = set(re.findall(r'"([A-Za-z0-9_]+)"', out))
    # Dynamische Präfixe (allocPrint "md_run_…", "ai_msg_…", "menu_item_…") grob abdecken
    names |= {"md_run", "ai_msg", "menu_item_", "tab_menu_", "editor_menu_", "md_menu_", "term_menu_", "fx_menu_"}
    return sorted(names)


def main():
    targets = {int(a) for a in sys.argv[1:]}
    if not targets:
        print(__doc__)
        return
    names = id_names()
    found = {}
    for name in names:
        key = name.encode()
        for idx in range(LIMIT):
            h = clay_hash(key, idx)
            if h in targets:
                found.setdefault(h, []).append(f'{name}' if idx == 0 else f'IDI("{name}", {idx})')
    for t in sorted(targets):
        print(f"{t}: {', '.join(found.get(t, ['unbekannt (zeiger-gesalzen oder dynamischer Name)']))}")


if __name__ == "__main__":
    main()
