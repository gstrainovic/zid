#!/usr/bin/env python3
"""Tests fuer die Prompt-Aufbereitung.

    cd bench && python3 -m unittest test_prompts -v

Hintergrund: olmoe hat im Chat-Modus keinen mehrzeiligen Prompt — eine neue
Zeile loest sofort das Absenden aus. Der Prompt muss deshalb auf eine Zeile
geglaettet werden. Die erste Fassung tat das mit " ".join(text.split()) und
loeschte die Zeilenumbrueche dabei ersatzlos: aus der Werkzeugliste wurde ein
Fliesstext ohne Trennzeichen. Das kostete OLMoE zwei von zehn Aufgaben
gegenueber dem PowerShell-Original, das die Werkzeuge von Hand mit Semikola
trennt.
"""

import unittest

from tasks import TOOL_SYSTEM, TOOL_SYSTEM_ONELINE

# Wortlaut des PowerShell-Originals, bench/windows/agent-eval-olmoe.ps1.
WINDOWS_WORDING = (
    "You are a tool-using agent. You have exactly these tools and no others: "
    "read_file(path) - read a file; "
    "write_file(path, text) - write a file; "
    "list_dir(path) - list a directory; "
    "run_shell(cmd) - run a shell command; "
    "search(pattern, path) - grep for a pattern. "
    'Reply with a single JSON object and nothing else: '
    '{"tool": "<one of the five names above>", "args": {...}}'
)


class OneLineFassung(unittest.TestCase):
    def test_entspricht_dem_powershell_original(self):
        """Die einzeilige Fassung muss dem Windows-Wortlaut gleichen.

        Sonst misst der Linux-Lauf eine andere Promptfassung als der
        Referenzlauf — genau das, was das Repo vermeiden will.
        """
        self.assertEqual(TOOL_SYSTEM_ONELINE, WINDOWS_WORDING)

    def test_werkzeuge_bleiben_getrennt(self):
        """Zwischen zwei Werkzeugen muss ein Trennzeichen stehen."""
        self.assertIn("read a file; write_file", TOOL_SYSTEM_ONELINE)
        self.assertIn("write a file; list_dir", TOOL_SYSTEM_ONELINE)
        self.assertIn("a directory; run_shell", TOOL_SYSTEM_ONELINE)
        self.assertIn("shell command; search", TOOL_SYSTEM_ONELINE)

    def test_ist_wirklich_einzeilig(self):
        """olmoe wuerde bei einem Zeilenumbruch vorzeitig absenden."""
        self.assertNotIn("\n", TOOL_SYSTEM_ONELINE)


class MehrzeiligeFassung(unittest.TestCase):
    def test_unveraendert(self):
        """TOOL_SYSTEM muss Byte fuer Byte bleiben, wie es war.

        Der Windows-Lauf zeigt, dass BitNet auf eine einzelne Leerzeile in
        diesem Text reagiert. Jede Aenderung entwertet den Vergleich.
        """
        erwartet = (
            "You are a tool-using agent. You have exactly these tools and no others:\n\n"
            "read_file(path)          - read a file\n"
            "write_file(path, text)   - write a file\n"
            "list_dir(path)           - list a directory\n"
            "run_shell(cmd)           - run a shell command\n"
            "search(pattern, path)    - grep for a pattern\n\n"
            'Reply with a single JSON object and nothing else:\n'
            '{"tool": "<one of the five names above>", "args": {...}}'
        )
        self.assertEqual(TOOL_SYSTEM, erwartet)

    def test_beide_fassungen_nennen_dieselben_werkzeuge(self):
        for werkzeug in ("read_file", "write_file", "list_dir", "run_shell", "search"):
            self.assertIn(werkzeug, TOOL_SYSTEM)
            self.assertIn(werkzeug, TOOL_SYSTEM_ONELINE)


if __name__ == "__main__":
    unittest.main()
