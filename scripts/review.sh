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
6. Antworte AUSSCHLIESSLICH mit reinem JSON gemaess Schema.

AUSGABE-REGELN (strikt):
- Keine Markdown-Fences (kein \`\`\`json, kein \`\`\`).
- Kein erklaerender Text vor oder nach dem JSON.
- Maximal 3 Eintraege in reasons, je max 200 Zeichen.
- Maximal 3 Eintraege in required_fixes, je max 200 Zeichen.
- Erste Zeichen deiner Antwort: { — letzte Zeichen: }."

# Hinweis zu --bare: Wir verwenden es NICHT, weil --bare OAuth/Keychain
# ignoriert und nur ANTHROPIC_API_KEY akzeptiert. Der User ist per OAuth
# eingeloggt, daher laufen wir im Normal-Modus und nehmen die etwas
# hoeheren Input-Tokens durch Auto-Memory/CLAUDE.md-Loading in Kauf.
RESPONSE_FILE=$(mktemp)
trap 'rm -f "$RESPONSE_FILE" "$RESPONSE_FILE.err"' EXIT

# WICHTIG: Positional prompt MUSS vor --allowedTools stehen, sonst schluckt
# das variadic Argument (<tools...>) den Prompt und claude meldet
# "Input must be provided either through stdin or as a prompt argument".
set +e
claude -p "$USER_PROMPT" \
    --model sonnet \
    --effort medium \
    --max-budget-usd 0.60 \
    --output-format json \
    --json-schema "$SCHEMA" \
    --permission-mode default \
    --append-system-prompt "$SYSTEM_PROMPT" \
    --add-dir "$REPO_ROOT" \
    --allowedTools "Read" "Glob" "Grep" "Bash(git log:*)" "Bash(git diff:*)" "Bash(git show:*)" "Bash(git tag:*)" "Bash(ls:*)" "Bash(sha256sum:*)" \
    >"$RESPONSE_FILE" 2>"$RESPONSE_FILE.err"
CLAUDE_EXIT=$?
set -e

if [[ $CLAUDE_EXIT -ne 0 ]]; then
    echo "ERROR: claude CLI exit=$CLAUDE_EXIT" >&2
    echo "--- stdout ---" >&2; cat "$RESPONSE_FILE" >&2
    echo "--- stderr ---" >&2; cat "$RESPONSE_FILE.err" >&2
    cat <<EOF
{"verdict":"REJECT","reasons":["claude CLI Fehler exit=$CLAUDE_EXIT — siehe stderr"],"required_fixes":["Infrastruktur pruefen: claude --version, claude auth status, OAuth-Login"]}
EOF
    exit 2
fi

# claude --output-format json wraps the result. Auf is_error pruefen, bevor
# wir versuchen "result" als JSON zu parsen.
VERDICT_JSON=$(python3 - <<'PY' "$RESPONSE_FILE"
import json, sys
path = sys.argv[1]
with open(path) as f:
    raw = f.read()
try:
    outer = json.loads(raw)
except json.JSONDecodeError:
    print(json.dumps({
        "verdict": "REJECT",
        "reasons": ["claude Ausgabe war kein gueltiges JSON"],
        "required_fixes": ["Rohausgabe in stderr pruefen"],
        "_raw": raw[:500],
    }))
    sys.exit(0)

if outer.get("is_error"):
    print(json.dumps({
        "verdict": "REJECT",
        "reasons": [f"claude Fehler: {outer.get('result','unbekannt')}"],
        "required_fixes": ["claude auth status pruefen; bei OAuth: interaktiv claude starten und /login"],
    }))
    sys.exit(0)

result = outer.get("result", "")
# Strip markdown code fences if Claude wrapped the JSON despite --json-schema
cleaned = str(result).strip()
if cleaned.startswith("```"):
    # remove leading ```json or ``` and trailing ```
    lines = cleaned.split("\n")
    if lines[0].startswith("```"):
        lines = lines[1:]
    if lines and lines[-1].strip() == "```":
        lines = lines[:-1]
    cleaned = "\n".join(lines).strip()

try:
    inner = json.loads(cleaned)
    print(json.dumps(inner))
except (json.JSONDecodeError, TypeError):
    print(json.dumps({
        "verdict": "REJECT",
        "reasons": ["Reviewer-Antwort war kein gueltiges Schema-JSON (evtl. abgeschnitten)"],
        "required_fixes": ["--max-budget-usd erhoehen oder Reviewer-Prompt kuerzen"],
        "_raw": cleaned[:800],
    }))
PY
)

printf '%s\n' "$VERDICT_JSON"

VERDICT=$(printf '%s' "$VERDICT_JSON" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read()).get("verdict","REJECT"))')

if [[ "$VERDICT" == "ACCEPT" ]]; then
    exit 0
else
    exit 1
fi
