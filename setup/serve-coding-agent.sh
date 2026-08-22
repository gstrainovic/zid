#!/usr/bin/env bash
# Startet llama-server als OpenAI-kompatiblen Endpunkt fuer Coding-Agenten,
# mit den in results/linux-i7-8850H-gpu-und-neue-modelle.md vermessenen
# Einstellungen. Siehe CODING-AGENTEN.md.
#
#   ./setup/serve-coding-agent.sh [qwen3|phi4|gemma3|llama] [gpu|cpu] [port]
#
# Vorgabe: qwen3 auf der GPU (P1000, Vulkan), Port 8080.
set -euo pipefail

MODELL="${1:-qwen3}"
GERAET="${2:-gpu}"
PORT="${3:-8080}"

ENGINE="$HOME/projects/ki/llama.cpp-vulkan/build/bin/llama-server"
MODELLE="$HOME/projects/ki/BitNet/models/_compare"

case "$MODELL" in
  qwen3)  DATEI="Qwen3-4B-Instruct-2507-Q4_K_M.gguf" ;;
  phi4)   DATEI="Phi-4-mini-instruct-Q4_K_M.gguf" ;;
  gemma3) DATEI="gemma-3-4b-it-Q4_K_M.gguf" ;;
  llama)  DATEI="Llama-3.2-3B-Instruct-Q4_K_M.gguf" ;;
  *) echo "Unbekanntes Modell: $MODELL (qwen3|phi4|gemma3|llama)" >&2; exit 1 ;;
esac

[ -x "$ENGINE" ] || { echo "Engine fehlt: $ENGINE — Build siehe results/linux-i7-8850H-gpu-und-neue-modelle.md" >&2; exit 1; }
[ -f "$MODELLE/$DATEI" ] || { echo "Modell fehlt: $MODELLE/$DATEI" >&2; exit 1; }

# -c 8192: passt bei den 4B-Modellen samt KV-Cache in die 4 GB der P1000.
case "$GERAET" in
  gpu) EXTRA=(-dev Vulkan1 -ngl 99 -c 8192) ;;
  cpu) EXTRA=(-dev none -ngl 0 -t 8 -tb 12 -c 8192) ;;
  *) echo "Unbekanntes Geraet: $GERAET (gpu|cpu)" >&2; exit 1 ;;
esac

"$ENGINE" -m "$MODELLE/$DATEI" --port "$PORT" --jinja "${EXTRA[@]}" &
SERVER=$!
trap 'kill "$SERVER" 2>/dev/null || true' EXIT

for _ in $(seq 1 120); do
  if curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
    echo
    echo "Bereit: $MODELL ($GERAET) auf http://127.0.0.1:$PORT/v1"
    echo "Pi-Agent: pi --provider llamacpp-lokal --model <id> --tools bash"
    echo "Beenden: Ctrl+C"
    wait "$SERVER"
    exit 0
  fi
  kill -0 "$SERVER" 2>/dev/null || { echo "llama-server hat sich beendet" >&2; exit 1; }
  sleep 1
done
echo "Server wurde nach 120 s nicht bereit" >&2
exit 1
