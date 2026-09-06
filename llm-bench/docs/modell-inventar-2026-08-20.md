# Modell-Inventar vor dem Aufräumen — 20.08.2026

Erstellt vor der Löschung gemäss TODO (bitnet-colibri-bench/TODO.md):
erst Liste als Referenz/Inspiration, dann löschen.

## Ollama (`~/.ollama`, 6.7 GB real — Blobs teils dedupliziert) — GELÖSCHT

| Modell | Grösse laut ollama | Notiz / Inspiration |
|---|---|---|
| gemma4:e2b | 7.2 GB | multimodal; als GGUF+mmproj weiterhin in `~/projects/vulkan-ed/models/` |
| qwen2.5-coder:7b | 4.7 GB | Coder-7B; passt nicht ganz in 4 GB VRAM (März-Erfahrung: ~10–15 tok/s im Split) |
| qwen2.5-coder-fix:latest | 1.9 GB | eigener Modelfile-Fix (Tool-Calling-Workaround?) |
| qwen2.5-coder:3b | 1.9 GB | Code-3B |
| gemma:2b / gemma2:2b | 1.7 / 1.6 GB | alt |
| qwen3:4b | 2.5 GB | Vorgänger des Benchmark-Siegers |
| nemotron-mini | 2.7 GB | NVIDIA 4B |
| qwen3:1.7b | 1.4 GB | klein |
| **xlam-2-1b** (+16k-Variante) | 986 MB ×2 | **Tool-Calling-Spezialist → wird gerade als GGUF neu geholt und gebenchmarkt** |
| phi4-mini / phi4-mini-16k | 2.5 GB ×2 | 16k-Variante war die Kontextfenster-Idee — auf llama-server via `-c` abgedeckt |
| phi3.5:3.8b | 2.2 GB | alt |
| qwen2.5:3b | 1.9 GB | alt |
| **qwen3-vl:2b / qwen3-vl:4b** | 1.9 / 3.3 GB | **Vision — einzige Fähigkeit, die das jetzige llama-server-Setup nicht abdeckt; bei Bedarf als GGUF+mmproj neu holen** |

## HF-Cache (`~/.cache/huggingface`, nur noch 99 MB) — GELÖSCHT

Fast alles bereits im März geleert, übrig waren Verzeichnis-Skelette (4 KB)
mit historischem Wert als Liste: 1bitLLM/bitnet_b1_58-3B + -large,
HF1BitLLM- & brunopio-Llama3-8B-1.58, Falcon3-10B-1.58bit, microsoft/BitNet
— die 1.58-Bit-Vorexperimente vor bitnet-colibri-bench. Dazu
sentence-transformers/all-MiniLM-L6-v2 (88 MB, Embeddings) und
Xenova/llama-3-tokenizer — werden bei Bedarf automatisch neu geladen.

## LM Studio (`~/.lmstudio/models`, 23 GB) — NICHT gelöscht, Empfehlung

Grösster Platzfresser, ausserhalb des TODO-Umfangs. Enthält jede Datei
**doppelt** (`qwen-all/` und Einzelordner, echte Kopien, ~11 GB
Verschwendung) — und zwei Kandidaten, die neuer sind als der
Benchmark-Sieger:

- **Qwen3.5-4B-Q4_K_M (2.6 GB)** und **Qwen3.5-2B-Q4_K_M (1.2 GB)** — im
  März als „1 Woche alt" notiert. **Kandidaten für den Werkzeugwahl-Test**,
  bevor man sie löscht!
- Rest: Qwen3-4B (haben wir frisch), Qwen2.5-Familie 1.5–3B (überholt).

`~/.local/koboldcpp/models/` verlinkt hierher — KoboldCpp ist durch
llama-server ersetzt, der Symlink stirbt mit.

## Behalten (aktiv genutzt)

- `models/` im vulkan-ed-Repo (seit 06.09.2026; vorher `~/projects/ki/BitNet/models/`) — Benchmark-Modelle mit sha256 in `results/`
- `engines/llama.cpp-vulkan` (vorher `~/projects/ki/llama.cpp-vulkan`) — Engine b10524
- `~/projects/vulkan-ed/models/` — gemma-4-E2B für den Editor
