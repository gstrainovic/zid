#!/usr/bin/env python3
"""Agent-Dateiwerkzeuge ohne Modell über den echten Hauptthread prüfen."""
import json
import os

from e2e_open_folder import ROOT, check, rpc, settle, start_zid, stop_zid, wait_port


def main():
    root = os.path.join(ROOT, "tmp", "e2e_agent_files")
    os.makedirs(root, exist_ok=True)
    listing = os.path.join(root, "listing")
    os.makedirs(listing, exist_ok=True)
    for name in ["z.txt", "a.txt", ".visible"]:
        with open(os.path.join(listing, name), "wb") as f:
            f.write(b"text")
    for name in [".git", ".zig-cache", "b"]:
        os.makedirs(os.path.join(listing, name), exist_ok=True)
    many = os.path.join(root, "many")
    os.makedirs(many, exist_ok=True)
    for n in range(204, -1, -1):
        with open(os.path.join(many, f"{n:03}.txt"), "wb") as f:
            f.write(b"text")
    for name, content in [("binary.bin", b"x" * 511 + b"\0"),
                          ("late.txt", b"x" * 512 + b"\0"),
                          ("text.txt", "Grösse\n".encode()), ("empty.txt", b"")]:
        with open(os.path.join(root, name), "wb") as f:
            f.write(content)
    with open(os.path.join(ROOT, "tmp", "e2e_agent_files.log"), "w") as log:
        proc = start_zid(["--headless", "--ai=off"], log)
        try:
            wait_port(proc)
            rpc("open_project", [root]); settle(20)
            def tool(name, path):
                return rpc("agent_tool", [name, json.dumps({"path": path})])
            entries = json.loads(tool("list_files", "listing"))["entries"]
            check(entries == [".visible", "a.txt", "b/", "z.txt"], f"Dateiliste sortiert und gefiltert: {entries}")
            limited = json.loads(tool("list_files", "many"))
            check(limited["entries"] == [f"{n:03}.txt" for n in range(200)], "Begrenzung liefert die alphabetisch ersten 200 Namen")
            check(limited.get("truncated") is True, "Abgeschnittene Liste ist gekennzeichnet")
            binary = json.loads(tool("read_file", "binary.bin"))
            check("binary" in binary.get("error", "").lower(), f"NUL an Byte 512 wird abgelehnt: {binary}")
            check(tool("read_file", "text.txt") == "Grösse\n", "UTF-8 bleibt unverändert")
            check(tool("read_file", "empty.txt") == "", "Leere Datei bleibt lesbar")
            check(tool("read_file", "late.txt") == "x" * 512 + "\0", "NUL nach dem Prüfbereich zählt nicht")
            print("ALL PASSED")
        finally:
            stop_zid(proc)


if __name__ == "__main__":
    main()
