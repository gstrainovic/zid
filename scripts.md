# Scripts Overview

Sortiert nach Wichtigkeit. Obsolet = wird nicht mehr verwendet. Doppelt = ersetzt durch bessere Alternative.

---

## ESSENTIAL (aktiv in Verwendung)

| Script | Beschreibung |
|--------|--------------|
| `vscreenshot.py` | **AI Visual Debugging** – Screenshot → Gemini CLI, interaktiv oder one-shot |
| `describe-png.py` | **PNG beschreiben** – Screenshot → Ollama gemma4 vision → Text-Beschreibung |
| `sync.sh` | **Repo-Sync** – submodule update, mupdf, referenz-repos, push/pull |

---

## NÜTZLICH (regelmäßig verwendet)

| Script | Beschreibung |
|--------|--------------|
| `rpc_client.py` | RPC-Basis-Client für Kommunikation mit vulkan-ed über Sockets (JSON-RPC 2.0) |
| `rpc_open.py` | Dateien per RPC öffnen: `python3 rpc_open.py <file>` |
| `simulate_typing.py` | Tastatureingaben per RPC senden (--ctrl k, --enter, text) |
| `fix_zig_cache.py` | **Windows Symlink-Fix** – tree-sitter grammars ohne Admin-Rechte extrahieren |

---
