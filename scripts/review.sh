#!/bin/bash
# Supervisor-Gate fuer vulkan-ed Phasen.
# Aufruf durch Qwen nach abgeschlossener Phase:
#     ./scripts/review.sh 6
#
# Exit-Codes:
#   0 = ACCEPT (Qwen darf weiter + ack-Tag setzen)
#   1 = REJECT (Qwen muss nachbessern)
#   2 = Infrastruktur-Fehler (Screenshot fehlt, claude CLI fehlt, etc.)

set -euo pipefail
shopt -s nullglob

PHASE="${1:-}"
if [[ -z "$PHASE" ]]; then
    echo "Usage: $0 <phase-number>" >&2
    exit 2
fi

cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"

PROMPT_FILE="$REPO_ROOT/.claude/reviewer-prompt.md"
if [[ ! -f "$PROMPT_FILE" ]]; then
    echo "ERROR: reviewer prompt missing: $PROMPT_FILE" >&2
    exit 2
fi

# ---- Vor-Check 1: Phasen-Screenshot existiert ueberhaupt? ----
PHASE_SHOTS=("$REPO_ROOT/screenshots/phase${PHASE}_"*.png)
if [[ ${#PHASE_SHOTS[@]} -eq 0 ]]; then
    cat <<EOF
{"verdict":"REJECT","reasons":["Keine screenshots/phase${PHASE}_*.png gefunden"],"required_fixes":["Screenshot der Phase ${PHASE} mit ./gui-screenshot.sh erzeugen"]}
EOF
    exit 1
fi

# ---- Vor-Check 2: Byte-identische Phasen-Screenshots (spart Claude-Tokens) ----
PREV_PHASE=$((PHASE - 1))
PREV_SHOTS=("$REPO_ROOT/screenshots/phase${PREV_PHASE}_"*.png)
if [[ ${#PREV_SHOTS[@]} -gt 0 ]]; then
    # Newest current phase shot
    NEW_SHOT=$(ls -t "${PHASE_SHOTS[@]}" | head -1)
    NEW_HASH=$(sha256sum "$NEW_SHOT" | awk '{print $1}')
    for PREV in "${PREV_SHOTS[@]}"; do
        PREV_HASH=$(sha256sum "$PREV" | awk '{print $1}')
        if [[ "$NEW_HASH" == "$PREV_HASH" ]]; then
            cat <<EOF
{"verdict":"REJECT","reasons":["phase${PHASE}-Screenshot ist byte-identisch zu $(basename "$PREV") — Phase wurde nicht echt implementiert"],"required_fixes":["Tatsaechliche visuelle Aenderung fuer Phase ${PHASE} implementieren und neuen Screenshot erzeugen"]}
EOF
            exit 1
        fi
    done
fi

# ---- Hauptsache: Claude als Reviewer aufrufen ----
if ! command -v claude &>/dev/null; then
    echo "ERROR: claude CLI nicht im PATH" >&2
    exit 2
fi

SCHEMA='{"type":"object","required":["verdict","reasons"],"additionalProperties":false,"properties":{"verdict":{"enum":["ACCEPT","REJECT"]},"reasons":{"type":"array","items":{"type":"string"},"minItems":1,"maxItems":5},"required_fixes":{"type":"array","items":{"type":"string"},"maxItems":5}}}'

SYSTEM_PROMPT=$(cat "$PROMPT_FILE")

USER_PROMPT="Review Phase ${PHASE} des vulkan-ed Projekts.

Repo-Root: ${REPO_ROOT}
Phase-Screenshots: screenshots/phase${PHASE}_*.png

Arbeitsschritte:
1. Lies todo.md und extrahiere NUR die Claims (Haken) aus Phase ${PHASE}.
2. git tag --list 'phase-*-ack' | sort -V | tail -1 fuer letzten ACK-Anker; falls leer, nutze den Commit vor dem ersten Phase-${PHASE}-bezogenen Commit.
3. git log und git diff seit diesem Anker.
4. Lies den neuesten screenshots/phase${PHASE}_*.png als Bild.
5. Prufe Claim-vs-Evidenz gemaess Reviewer-Prompt.
6. Antworte AUSSCHLIESSLICH mit JSON gemaess Schema."

# Response-Datei (stderr des Scripts bekommt claude-Meldungen, stdout = JSON)
RESPONSE=$(claude -p \
    --bare \
    --model sonnet \
    --effort medium \
    --max-budget-usd 0.30 \
    --output-format json \
    --json-schema "$SCHEMA" \
    --permission-mode default \
    --allowedTools "Read" "Glob" "Grep" "Bash(git log:*)" "Bash(git diff:*)" "Bash(git show:*)" "Bash(git tag:*)" "Bash(ls:*)" "Bash(sha256sum:*)" \
    --add-dir "$REPO_ROOT" \
    --append-system-prompt "$SYSTEM_PROMPT" \
    "$USER_PROMPT")

# claude --output-format json wraps the result; extract the model-produced JSON
# which is validated against our schema. Field name: "result".
VERDICT_JSON=$(printf '%s' "$RESPONSE" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("result") or d.get("content") or json.dumps(d))')

# Print the verdict JSON on stdout (consumable by Qwen)
printf '%s\n' "$VERDICT_JSON"

# Exit-Code aus verdict
VERDICT=$(printf '%s' "$VERDICT_JSON" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read()); print(d.get("verdict","REJECT"))')

if [[ "$VERDICT" == "ACCEPT" ]]; then
    exit 0
else
    exit 1
fi
