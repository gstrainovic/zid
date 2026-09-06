"""Gemeinsame Aufgabendefinitionen für alle Testläufer.

Eine einzige Quelle, damit Windows- und Linux-Läufe wirklich dasselbe messen.
"""

# --- Teil 1: Fähigkeitsstichproben (qualitativ, werden von Hand beurteilt) ---

_TOOL_INTRO = "You are a tool-using agent. You have exactly these tools and no others:"

# Aufrufform -> Beschreibung. Reihenfolge ist Teil des Prompts.
_TOOLS = (
    ("read_file(path)", "read a file"),
    ("write_file(path, text)", "write a file"),
    ("list_dir(path)", "list a directory"),
    ("run_shell(cmd)", "run a shell command"),
    ("search(pattern, path)", "grep for a pattern"),
)

_TOOL_OUTRO = (
    'Reply with a single JSON object and nothing else:\n'
    '{"tool": "<one of the five names above>", "args": {...}}'
)

# Mehrzeilig, fuer alles mit OpenAI-Endpunkt. Der Text ist absichtlich auf
# Spalte 26 ausgerichtet und enthaelt zwei Leerzeilen: BitNet reagiert darauf
# messbar (siehe results/windows-i5-13500T.md). Nicht umformatieren.
TOOL_SYSTEM = (
    _TOOL_INTRO + "\n\n"
    + "".join(f"{call:<24} - {desc}\n" for call, desc in _TOOLS)
    + "\n" + _TOOL_OUTRO
)

# Einzeilig, fuer colibris olmoe: dort loest ein Zeilenumbruch im Chat-Modus
# sofort das Absenden aus. Die Werkzeuge werden mit Semikola getrennt statt die
# Umbrueche ersatzlos zu streichen — sonst laeuft die Liste zu einem Fliesstext
# ohne Trennzeichen zusammen ("read a file write_file(path, text) - ..."), was
# OLMoE zwei von zehn Aufgaben kostet. Wortgleich mit
# bench/windows/agent-eval-olmoe.ps1, damit Linux- und Windows-Lauf denselben
# Prompt sehen.
TOOL_SYSTEM_ONELINE = (
    _TOOL_INTRO + " "
    + "; ".join(f"{call} - {desc}" for call, desc in _TOOLS) + ". "
    + " ".join(_TOOL_OUTRO.split())
)

PROBES = [
    {
        "name": "1-tool-call-json",
        "system": TOOL_SYSTEM,
        "user": "Show me the contents of /etc/hosts.",
    },
    {
        "name": "2-code-python",
        "system": "You are a coding assistant. Output only code, no explanation, no markdown fences.",
        "user": "Write a Python function quicksort(a) that returns a new sorted list.",
    },
    {
        "name": "3-instruction-strict",
        "system": "Follow the format exactly.",
        "user": "Answer with exactly one word, uppercase, nothing else: "
                "what is the capital of Switzerland?",
    },
    {
        "name": "4-german",
        "system": "Du bist ein hilfreicher Assistent. Antworte auf Deutsch.",
        "user": "Erklaere in zwei Saetzen, was ein Index in einer relationalen Datenbank bewirkt.",
    },
    {
        "name": "5-reasoning",
        "system": "Think step by step, then give the final number after 'ANSWER:'.",
        "user": "A shop sells pens at 3 for 5 francs. I buy 21 pens and pay with a 50 franc note. "
                "How much change do I get?",
    },
    {
        "name": "6-agent-multistep",
        "system": "You are a coding agent. Available tools: read_file(path), "
                  "edit_file(path, old, new), run_tests().\n"
                  "Output a numbered plan of tool calls only, one per line, "
                  "format: N. tool(args). No prose.",
        "user": "The test suite fails because utils.py has a typo: 'lenght' should be 'length'. "
                "Fix it and verify.",
    },
]

# Erwartete Antwort auf 3 und 5, damit sich beides ohne Nachdenken prüfen lässt.
PROBE_EXPECTED = {
    "3-instruction-strict": "BERN",
    "5-reasoning": "15",
}


# --- Teil 2: Werkzeugwahl (quantitativ, 10 Aufgaben, wird automatisch gezählt) ---

AGENT_CASES = [
    ("What is inside README.md?", "read_file"),
    ("Which files are in the src folder?", "list_dir"),
    ("Create a file notes.txt containing the word hello.", "write_file"),
    ("Find every place where the string TODO appears under ./app.", "search"),
    ("Run the unit tests with pytest.", "run_shell"),
    ("Show me the contents of config/settings.yaml.", "read_file"),
    ("List everything in the current directory.", "list_dir"),
    ("Save the text 'build ok' into status.log.", "write_file"),
    ("Where is the function parse_args defined in this repo?", "search"),
    ("Install the dependencies with npm install.", "run_shell"),
]
