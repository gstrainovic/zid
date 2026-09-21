---
name: pdf-view
description: >
  PDF-Vorschau in zid: Blättern, Neuladen bei Dateiänderung, mupdf-Abstürze bei halb geschriebenen PDFs, E2E-Zustand. Use when touching src/ui/pdf_view.zig, pdf_nav.zig, src/rendering/pdf_handler.zig, PDF reload, or scripts/e2e_pdf_*.py.
---

Aus AGENTS.md hierher verschoben (21.09.2026), Wortlaut unverändert.

## PDF-Vorschau: Blättern und Neuladen

- **Neu laden bei Dateiänderung:** `handleExternalChange` erkennt offene PDFs (`keyForPath` über
  `open_pdfs`, auch per realpath) und reiht sie in `pending_pdf_reloads` ein; `exportMarpPdf` tut
  das direkt. Der Main-Loop lädt erst, wenn die Datei 150 ms ruht (`takeDuePdfReload`, mtime):
  Das System-mupdf 1.27.2 (Linux linkt `/lib64/libmupdf.so`, nicht fancy-cats mupdf) stürzt beim
  Reparieren mancher halb geschriebener PDFs ab („double free“, `mutool draw` segfaultet auf
  derselben Datei), und der Watcher meldet je Datei nur ein Ereignis pro 100 ms. Neuer Handler,
  Seite geklemmt, Textur ersetzt; scheitert etwas, bleibt der alte Stand. `wantsFrameSoon` hält
  den Loop wach, solange ein Reload wartet. E2E `python3 scripts/e2e_pdf_reload.py`, Marp-Weg in
  `e2e_marp_pdf.py` (letzter Schritt).

- Blätter-Logik als reines Modul `src/ui/pdf_nav.zig` (Tasten, Mausrad, Sättigung an den
  Rändern, Beschriftung). Die Ansicht `src/ui/pdf_view.zig` liefert nur ein Seiten-Delta,
  angewendet wird es in der Hauptschleife, die auch die Textur neu rendert.
- Bild ab/auf und Pfeil links/rechts blättern; hoch und runter bleiben der Navigation
  zwischen Panes und im Explorer. Mausrad: negative Zeilen heißen nach unten, also vorwärts.
- `clay.pointerOver` meldet in dieser Ansicht nichts, deshalb hat die Leiste eine eigene
  Schaltfläche statt `components.Button`: Hover und Klick rechnen gegen die Bounding-Box aus
  dem letzten Layout (`pdf_nav.hits`, Aufhellung über `pdf_nav.brighten`).
- Die Beschriftung liegt in einem Puffer der UI (`pdf_label_buf`), nicht in der Frame-Arena:
  `beginLayout` setzt die Arena zurück, Clay liest den Text erst beim Zeichnen.
- Zustand für E2E: `pdf_state` liest Felder im `E2EContext`, die der Main-Thread pro Frame
  setzt. Über Tabs und `open_pdfs` im Server-Thread zu laufen lieferte springende Werte.
- E2E: `python3 scripts/e2e_pdf_pager.py`, das siebenseitige PDF erzeugt `write_pdf` nach
  `tmp/e2e_pdf/pager.pdf`. Der Test startet
  mit eigenem, frischem `XDG_CONFIG_HOME` und übergibt das PDF als Startdatei: über eine
  wiederhergestellte Sitzung wechselt der aktive Tab und die Messung trifft Fremdzustand.
  `open_file` öffnet keinen PDF-Tab, das Laden hängt am Explorer-Pfad.
