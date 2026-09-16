# Offene Punkte

## Fedora-Laptop: reproduzierbare Testdaten für die E2E-Suiten

Unter Windows (15.09.2026) laufen alle Suiten headless, bis auf drei, die an Daten hängen,
die nur auf dem Fedora-Laptop liegen. Ziel: jede Suite legt ihre Fixtures selbst an oder
nimmt sie aus dem Repo, auf jedem Rechner gleich.

- `scripts/e2e_marp_pdf.py` kopiert `test_data/marp_test.md`, `scripts/e2e_pdf_pager.py` öffnet
  `test_data/marp_test.pdf`. `test_data/` steht in `.gitignore` („too large for git“), die
  Dateien fehlen deshalb auf jedem frischen Checkout. Beide sind klein: das Deck ins Repo
  (z. B. `scripts/fixtures/marp_test.md`, nicht unter dem ignorierten `test_data/`) und das PDF
  im Test erzeugen — über den Export aus `e2e_marp_pdf.py` oder `mutool` — statt es
  einzuchecken. Dasselbe für `test_data/syntax_test.md`, die Default-Datei beim Start.
- `scripts/e2e_repro_text_uaf.py` braucht `~/projects/find-jobs/goran` mit Bildern und fährt den
  Ordnerwechsel nach `~/projects`. Das ist ein privates Repo auf dem Laptop. Stattdessen unter
  `tmp/e2e_uaf/` einen Baum mit einigen Unterordnern und erzeugten PNGs anlegen (Python ohne
  Fremdbibliothek, wie `pixel()` in `e2e_pdf_pager.py` PPM liest) und dorthin wechseln.
- Danach auf beiden Rechnern alle Suiten laufen lassen; auf Linux wurden die Windows-Anpassungen
  vom 15.09.2026 (`start_zid`, `cursor_to`, Junction-Fallback, Pfadtrenner) noch nicht geprüft.
