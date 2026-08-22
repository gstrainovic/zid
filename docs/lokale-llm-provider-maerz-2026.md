# Lokale LLM-Provider für den Pi-Agenten — konsolidiert

Zusammenführung dreier Dokumente vom 13.–15. März 2026 (Originale in
`archiv/`): `PI-PROVIDER-REFERENCE.md`, `PROVIDER-SETUP-COMPLETE.md` und
das ausführliche `readme.md` aus `~/agents/`. Konsolidiert am 20.08.2026.

**Aktueller Stand:** Dieses Setup ist überholt. Seit August 2026 ersetzt
`llama-server` (llama.cpp b10524, Vulkan) alle hier beschriebenen lokalen
Provider — Rezept und Messwerte in
`~/projects/bitnet-colibri-bench/CODING-AGENTEN.md`. Dieses Dokument ist
das Protokoll, wie es dazu kam, und bewahrt die noch gültigen Erkenntnisse.

## Chronik

- **Feb 2026:** Ollama-Phase, 17 Modelle gesammelt (Inventar:
  `modell-inventar-2026-08-20.md`; am 20.08.2026 gelöscht).
- **13.–14. März:** Pi-Agent an vier Provider angebunden (Groq, KoboldCpp,
  LM Studio, Ollama). Setup-Skripte, models.json, Troubleshooting.
- **15. März:** Modell-Cleanup auf kuratierte Qwen-Liste; Qwen3-4B mit
  Pi-Agent erfolgreich getestet.
- **20. Aug:** bitnet-colibri-bench quantifiziert die Modellwahl
  (Qwen3-4B 10/10 Werkzeugwahl) und ersetzt die Provider durch
  llama-server; Härtetest zeigt die Grenze der 3–4B-Klasse
  (Ein-Datei-Fix ja, Mehrdatei-Debugging nein).

## Befunde, die weiterhin gelten

1. **Tool-Calling ist das Nadelöhr, nicht der Durchsatz.** Ollama fiel
   wegen defektem Tool-Calling durch (Bugs #9632, #12557), Groq und
   KoboldCpp funktionierten. Heute misst `agent_eval.py` genau das.
2. **Qwen-Modelle sind die verlässlichsten der Kleinklasse.** Der
   März-Test („Qwen3-4B: Tool-Ausführung funktioniert perfekt", VRAM
   3284 MB) wurde im August mit 10/10 quantifiziert bestätigt.
3. **Die P1000 (4 GB) trägt 4B-Q4-Modelle vollständig; 7B nur im
   CPU/GPU-Split** (~10–15 tok/s, langsamer als 4B ganz auf der GPU).
4. **Vulkan ist der Weg zur Pascal-Karte.** Schon der März-KoboldCpp
   wurde mit `LLAMA_VULKAN=1` gebaut (`--usevulkan 1` = NVIDIA-Device);
   CUDA-13-Toolkit unterstützt Pascal nicht mehr.
5. **Pi-Bedienung:** `--print`/interaktiv funktioniert; `echo "…" | pi`
   war unzuverlässig. Provider in `~/.pi/agent/models.json`, nach
   Änderungen `/reload`.

## Was aus dem März-Setup wo liegt

| Artefakt | Ort | Status |
|---|---|---|
| Groq-Provider (API-Key!) | `~/.pi/agent/models.json`, `~/.bashrc` u. a. | funktionsfähig, Cloud |
| KoboldCpp | `~/.local/koboldcpp/` | ersetzt durch llama-server; Modell-Symlink zeigt auf LM Studio |
| LM-Studio-Modelle | `~/.lmstudio/models/` (23 GB, mit Duplikaten) | enthält Qwen3.5-4B/2B — Testkandidaten, siehe Inventar |
| Starter-Skript | `archiv/pi-start` | KoboldCpp-gebunden, historisch |
| llamacpp-lokal-Provider | `~/.pi/agent/models.json` | **aktueller Weg** (seit 20.08.) |
