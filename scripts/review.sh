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

# ---- Hauptsache: Claude als Reviewer (Fallback: Gemini) aufrufen ----
CLAUDE_AVAIL=false
if command -v claude &>/dev/null; then
    CLAUDE_AVAIL=true
fi

GEMINI_AVAIL=false
if command -v gemini &>/dev/null; then
    GEMINI_AVAIL=true
fi

if [[ "$CLAUDE_AVAIL" == "false" && "$GEMINI_AVAIL" == "false" ]]; then
    echo "ERROR: Weder gemini noch claude CLI im PATH" >&2
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

RESPONSE_FILE=$(mktemp)
trap 'rm -f "$RESPONSE_FILE" "$RESPONSE_FILE.err"' EXIT

SUCCESS=false

# ---- PRIMAER: Gemini ----
if [[ "$GEMINI_AVAIL" == "true" ]]; then
    GEMINI_PROMPT="SYSTEM_PROMPT:
$SYSTEM_PROMPT

JSON_SCHEMA:
$SCHEMA

$USER_PROMPT"

    set +e
    gemini -p "$GEMINI_PROMPT" \
        --yolo \
        -o json \
        >"$RESPONSE_FILE" 2>"$RESPONSE_FILE.err"
    GEMINI_EXIT=$?
    set -e

    if [[ $GEMINI_EXIT -eq 0 ]]; then
        SUCCESS=true
    else
        echo "Gemini failed (exit $GEMINI_EXIT), trying Claude fallback..." >&2
    fi
fi

# ---- FALLBACK: Claude ----
if [[ "$SUCCESS" == "false" && "$CLAUDE_AVAIL" == "true" ]]; then
    set +e
    claude -p "$USER_PROMPT" \
        --model sonnet \
        --effort medium \
        --output-format json \
        --json-schema "$SCHEMA" \
        --dangerously-skip-permissions \
        --append-system-prompt "$SYSTEM_PROMPT" \
        --add-dir "$REPO_ROOT" \
        --allowedTools "Read" "Glob" "Grep" "Bash(git log:*)" "Bash(git diff:*)" "Bash(git show:*)" "Bash(git tag:*)" "Bash(ls:*)" "Bash(sha256sum:*)" \
        >"$RESPONSE_FILE" 2>"$RESPONSE_FILE.err"
    CLAUDE_EXIT=$?
    set -e

    if [[ $CLAUDE_EXIT -eq 0 ]]; then
        SUCCESS=true
    else
        echo "ERROR: claude CLI exit=$CLAUDE_EXIT" >&2
        cat "$RESPONSE_FILE.err" >&2
        cat <<EOF
{"verdict":"REJECT","reasons":["claude CLI Fehler exit=$CLAUDE_EXIT — siehe stderr"],"required_fixes":["Infrastruktur pruefen: claude --version, claude auth status"]}
EOF
        exit 2
    fi
fi

if [[ "$SUCCESS" == "false" ]]; then
    cat <<EOF
{"verdict":"REJECT","reasons":["Alle Reviewer-Dienste fehlgeschlagen"],"required_fixes":["Verbindung und Quotas fuer claude/gemini pruefen"]}
EOF
    exit 2
fi

# Parser fuer JSON-Ausgabe (unterstützt Claude und Gemini Format)
VERDICT_JSON=$(python3 - <<'PY' "$RESPONSE_FILE"
import json, sys, re
path = sys.argv[1]
with open(path) as f:
    raw = f.read()

# Robust JSON extraction (skip prefix/suffix text)
json_match = re.search(r'(\{.*\})', raw, re.DOTALL)
if not json_match:
    print(json.dumps({
        "verdict": "REJECT",
        "reasons": ["CLI Ausgabe enthielt kein gueltiges JSON-Objekt"],
        "required_fixes": ["Rohausgabe in stderr pruefen"],
        "_raw": raw[:500],
    }))
    sys.exit(0)

raw_json = json_match.group(1)
try:
    outer = json.loads(raw_json)
except json.JSONDecodeError:
    print(json.dumps({
        "verdict": "REJECT",
        "reasons": ["CLI Ausgabe war kein gueltiges JSON"],
        "required_fixes": ["Rohausgabe in stderr pruefen"],
        "_raw": raw_json[:500],
    }))
    sys.exit(0)

if outer.get("is_error"):
    print(json.dumps({
        "verdict": "REJECT",
        "reasons": [f"Reviewer Fehler: {outer.get('result','unbekannt')}"],
        "required_fixes": ["CLI auth status pruefen"],
    }))
    sys.exit(0)

# Claude with --json-schema puts result in 'structured_output', not 'result'
structured = outer.get("structured_output")
if isinstance(structured, dict) and "verdict" in structured:
    print(json.dumps(structured))
    sys.exit(0)

# Fallback: Claude uses 'result', Gemini uses 'response'
result = outer.get("result")
if result is None:
    result = outer.get("response", "")

# Strip markdown code fences if Claude/Gemini wrapped the JSON
cleaned = str(result).strip()
if cleaned.startswith("```"):
    lines = cleaned.split("\n")
    if lines[0].startswith("```"):
        lines = lines[1:]
    if lines and lines[-1].strip() == "```":
        lines = lines[:-1]
    cleaned = "\n".join(lines).strip()

try:
    inner = json.loads(cleaned)
    if "verdict" not in inner:
        raise ValueError("Missing 'verdict' in response")
    print(json.dumps(inner))
except (json.JSONDecodeError, TypeError, ValueError) as e:
    print(json.dumps({
        "verdict": "REJECT",
        "reasons": [f"Gueltiges JSON, aber Schema/Inhalt fehlerhaft: {str(e)}"],
        "required_fixes": ["Reviewer-Prompt kuerzen oder Budget erhoehen"],
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
