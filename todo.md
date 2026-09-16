# Offene Punkte

## Markdown-Vorschau: E2E für Tabellen und alle zigdown-Beispieldateien

Tabellen wurden nie getestet: die Zellen standen bis 15.09.2026 untereinander, ohne dass eine
Suite es merkte. zigdown testet Tabellen nur als Parser-Strings
(`libs/zigdown/src/lib/parsers/blocks.zig`), und `zig build test` in zid führt diese Tests
nicht aus.

- `scripts/e2e_md_preview.py` um einen Tabellen-Schritt ergänzen: `libs/zigdown/test/table.md`
  in der Vorschau öffnen und prüfen, dass die Zellen einer Zeile nebeneinander stehen (gleiches
  `y`, steigendes `x`) und die Kopfzeile über der ersten Datenzeile liegt. Dafür brauchen die
  Zellen in `MarkdownView.renderTable` abfragbare IDs (z. B. `md_tcell` per `idi`, Zähler je
  Frame wie `run_counter`, damit mehrere Tabellen nicht kollidieren); heute hat nur der Block
  eine ID (`md_block`). Screenshot nach `tmp/e2e_md_table.ppm`.
- Alle Beispieldateien unter `libs/zigdown/test/*.md` headless in der Vorschau öffnen (alert,
  code, directive, link, list, list2, mini, quote, sample, sample2, spaced-list, table, toc,
  yaml): je Datei mindestens ein `md_block` im Layout, keine Clay-Fehler im Log, kein Absturz,
  ein Screenshot pro Datei. Neue Dateien im Ordner automatisch mitnehmen (Glob statt Liste).
  Wo sinnvoll gezielte Prüfungen wie beim Tabellen-Schritt (Zitat mit linkem Rand, Liste mit
  Aufzählungszeichen, Codeblock mit Hintergrund).

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
