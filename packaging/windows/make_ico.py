"""Baut packaging/windows/zid.ico aus dem App-Icon (SVG).

Rendert das SVG mit Inkscape in mehreren Größen und legt die PNGs unverändert
in die ICO-Datei (seit Vista zulässig). ImageMagick schreibt stattdessen BMP,
der 256er-Eintrag allein wäre dann 256 KiB groß.

    python3 packaging/windows/make_ico.py
"""

import pathlib
import struct
import subprocess
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
SVG = HERE.parent / "io.github.gstrainovic.zid.svg"
ICO = HERE / "zid.ico"
SIZES = [16, 20, 24, 32, 40, 48, 64, 256]


def render(size: int, out: pathlib.Path) -> bytes:
    subprocess.run(
        ["inkscape", str(SVG), "--export-type=png",
         f"--export-width={size}", f"--export-height={size}",
         f"--export-filename={out}"],
        check=True, capture_output=True,
    )
    return out.read_bytes()


def main() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        images = [render(n, pathlib.Path(tmp) / f"{n}.png") for n in SIZES]
    header = struct.pack("<HHH", 0, 1, len(images))
    offset = len(header) + 16 * len(images)
    entries, data = b"", b""
    for size, png in zip(SIZES, images):
        dim = 0 if size >= 256 else size  # 0 steht für 256
        entries += struct.pack("<BBBBHHII", dim, dim, 0, 0, 1, 32, len(png), offset + len(data))
        data += png
    ICO.write_bytes(header + entries + data)
    print(f"{ICO}: {len(SIZES)} Größen, {ICO.stat().st_size} Bytes")


if __name__ == "__main__":
    main()
