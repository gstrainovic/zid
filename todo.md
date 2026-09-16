# Offene Punkte

## Windows: alle E2E-Suiten nachlaufen lassen

Auf Linux laufen alle 23 Suiten grün. Seit dem letzten Windows-Lauf haben sich die Suiten geändert:

- Testdaten kommen aus `scripts/fixtures/` bzw. `scripts/e2e_fixtures.py` (PDF, PNG).
- `start_zid` isoliert die Konfiguration unter `tmp/e2e_env/<log-name>`.
- `e2e_explorer`, `e2e_tabs`, `e2e_md_preview`, `e2e_marp_pdf`, `e2e_ai_chat` starten über `start_zid`.
- `e2e_explorer` misst Drag & Drop nach Pfad (`rows_in_view`); Pfadvergleiche mit Backslashes prüfen.
- `e2e_md_preview` öffnet alle `libs/zigdown/test/*.md` und prüft Pixel im Screenshot.

Auf dem Windows-Rechner vorher `./scripts/sync.sh` (Submodul `libs/zigdown` hat einen neuen Commit),
dann alle `scripts/e2e_*.py` laufen lassen.
