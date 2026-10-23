#!/usr/bin/env python3
"""Regenerates the spectrum fixtures in src/testdata/.

Writes a 16-bit RGB TIFF of a synthetic capture, then the equivalent Portable
Float Map. The pair exists so the spectrum readout can be checked against the
reference C++ tiff2specdata (which reads TIFF) while the port reads the PFM:

    python3 tools/gen_spectrum_fixture.py src/testdata
    # then, with ImageMagick, the PFM side:
    magick src/testdata/spectrum16.tif src/testdata/spectrum16.pfm

The image is 16 wide by 120 tall: a green band on rows 20..79 with a distinct
value per column, so the crop is exactly 100 rows (the band) and every column
reads differently. That keeps the two tools' numbers related by exactly
1/65535, which is what the compatibility harness checks, and the band sits
off-centre so a vertical flip cannot go unnoticed.
"""
import math
import struct
import sys


def band(y):
    """Illuminated rows: a hard band on 20..79.

    Deliberately off-centre: the crop still comes out exactly 100 rows tall, but
    a reader that forgot PFM's bottom-up row order would mirror the image and
    land on different pixels, so the fixtures catch it.
    """
    return 1.0 if 20 <= y < 80 else 0.08


def pixel(x, y):
    """Per-column values so the readout distinguishes every column."""
    lit = band(y)
    return (
        int(60000 * lit * (0.10 + 0.010 * x)),
        int(60000 * lit * (0.80 + 0.005 * x)),
        int(60000 * lit * (0.05 + 0.020 * x)),
    )


def write_tiff(path, width, height, pixels):
    """Baseline little-endian 16-bit RGB TIFF, one strip, uncompressed."""
    data = bytearray()
    for row in pixels:
        for (r, g, b) in row:
            data += struct.pack("<HHH", r, g, b)

    entries = []
    def entry(tag, typ, count, value):
        entries.append((tag, typ, count, value))

    ifd_offset = 8
    n = 11
    ifd_size = 2 + n * 12 + 4
    bps_offset = ifd_offset + ifd_size
    data_offset = bps_offset + 6

    entry(256, 4, 1, width)
    entry(257, 4, 1, height)
    entry(258, 3, 3, bps_offset)
    entry(259, 3, 1, 1)          # compression: none
    entry(262, 3, 1, 2)          # photometric: RGB
    entry(273, 4, 1, data_offset)
    entry(277, 3, 1, 3)
    entry(278, 4, 1, height)
    entry(279, 4, 1, len(data))
    entry(284, 3, 1, 1)          # planar: contiguous
    entry(339, 3, 1, 1)          # sample format: unsigned

    out = bytearray(b"II" + struct.pack("<HI", 42, ifd_offset))
    out += struct.pack("<H", len(entries))
    for tag, typ, count, value in entries:
        if typ == 3 and count == 1:
            val = struct.pack("<HH", value, 0)
        else:
            val = struct.pack("<I", value)
        out += struct.pack("<HHI", tag, typ, count) + val
    out += struct.pack("<I", 0)
    assert len(out) == bps_offset
    out += struct.pack("<HHH", 16, 16, 16)
    out += data
    with open(path, "wb") as f:
        f.write(out)


if __name__ == "__main__":
    outdir = sys.argv[1] if len(sys.argv) > 1 else "src/testdata"
    width, height = 16, 120
    rows = [[pixel(x, y) for x in range(width)] for y in range(height)]
    path = f"{outdir}/spectrum16.tif"
    write_tiff(path, width, height, rows)
    print(f"{path}: {width}x{height}, {len(rows[0])} columns")
    print("now run: magick " + path + " " + outdir + "/spectrum16.pfm")
