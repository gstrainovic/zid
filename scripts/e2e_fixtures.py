#!/usr/bin/env python3
"""Testdaten für die E2E-Suiten, auf jedem Rechner gleich und ohne Fremdbibliothek.

Eingecheckte Vorlagen liegen unter scripts/fixtures/ (nicht unter test_data/, das ist
ignoriert). Binäres wie PDF und PNG wird hier erzeugt statt eingecheckt.

Selbsttest: python3 scripts/e2e_fixtures.py
"""
import os
import struct
import zlib

FIXTURES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures")
MARP_DECK = os.path.join(FIXTURES, "marp_test.md")


def write_pdf(path, pages):
    """PDF mit `pages` Seiten (16:9, je eine Überschrift „Seite N“)."""
    w, h = 960, 540
    objs = {1: b"<< /Type /Catalog /Pages 2 0 R >>",
            3: b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"}
    kids = []
    for i in range(pages):
        page, content = 4 + 2 * i, 5 + 2 * i
        kids.append(page)
        stream = f"BT /F1 48 Tf 80 {h - 120} Td (Seite {i + 1}) Tj ET".encode()
        objs[page] = (f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {w} {h}] "
                      f"/Resources << /Font << /F1 3 0 R >> >> /Contents {content} 0 R >>").encode()
        objs[content] = b"<< /Length %d >>\nstream\n%s\nendstream" % (len(stream), stream)
    objs[2] = f"<< /Type /Pages /Kids [{' '.join(f'{k} 0 R' for k in kids)}] /Count {pages} >>".encode()

    out = bytearray(b"%PDF-1.4\n")
    offsets = {}
    for n in sorted(objs):
        offsets[n] = len(out)
        out += b"%d 0 obj\n%s\nendobj\n" % (n, objs[n])
    xref = len(out)
    count = max(objs) + 1
    out += b"xref\n0 %d\n0000000000 65535 f \n" % count
    for n in range(1, count):
        out += b"%010d 00000 n \n" % offsets[n]
    out += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (count, xref)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(out)


def write_png(path, width, height):
    """RGB-PNG mit Farbverlauf, damit das Bild nicht einfarbig ist."""
    rows = bytearray()
    for y in range(height):
        rows.append(0)  # Filter „None“ je Zeile
        for x in range(width):
            rows += bytes((x * 255 // max(1, width - 1), y * 255 // max(1, height - 1), 128))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(bytes(rows)))
           + chunk(b"IEND", b""))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(png)


def _selftest():
    import shutil
    import subprocess
    import tempfile

    tmp = tempfile.mkdtemp()
    try:
        pdf = os.path.join(tmp, "t.pdf")
        write_pdf(pdf, 7)
        png = os.path.join(tmp, "t.png")
        write_png(png, 30, 40)
        assert open(pdf, "rb").read(5) == b"%PDF-"
        assert os.path.exists(MARP_DECK), MARP_DECK
        if shutil.which("mutool"):
            info = subprocess.run(["mutool", "info", pdf], capture_output=True, text=True)
            assert "Pages: 7" in info.stdout and not info.stderr.strip(), info.stdout + info.stderr
            draw = subprocess.run(["mutool", "draw", "-o", os.path.join(tmp, "p%d.png"), pdf],
                                  capture_output=True, text=True)
            # stderr trägt je Seite eine Fortschrittszeile; Probleme meldet mutool als error/warning.
            bad = [l for l in draw.stderr.splitlines() if "error" in l or "warning" in l]
            assert draw.returncode == 0 and not bad, draw.stderr
            print("mutool: 7 Seiten, fehlerfrei gerendert")
        with open(png, "rb") as f:
            data = f.read()
        assert data[:8] == b"\x89PNG\r\n\x1a\n" and struct.unpack(">II", data[16:24]) == (30, 40)
        print("OK")
    finally:
        shutil.rmtree(tmp)


if __name__ == "__main__":
    _selftest()
