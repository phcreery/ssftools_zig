#!/usr/bin/env python3
"""Regenerates src/testdata/spectrum16.pfm.

A 16 wide by 120 tall synthetic capture: a green band on rows 20..79 with a
distinct value per column. The band sits off-centre so a reader that forgot
PFM's bottom-up row order cannot pass, and it is exactly 100 rows tall so the
readout's crop is exactly 100.

    python3 tools/gen_spectrum_fixture.py src/testdata

The reference numbers in src/testdata/spectrum16.reference.txt are the original
C++ tool's output for this same image. To recapture them, point the script at
that binary; it writes a temporary 16-bit TIFF, runs the tool over it, and
removes the TIFF again:

    python3 tools/gen_spectrum_fixture.py src/testdata /path/to/tiff2specdata
"""
import struct
import sys


def band(y):
    """Illuminated rows: a hard band on 20..79."""
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

    ifd_offset, entries = 8, 11
    bps_offset = ifd_offset + 2 + entries * 12 + 4
    data_offset = bps_offset + 6
    items = [
        (256, 4, 1, width), (257, 4, 1, height), (258, 3, 3, bps_offset),
        (259, 3, 1, 1), (262, 3, 1, 2), (273, 4, 1, data_offset),
        (277, 3, 1, 3), (278, 4, 1, height), (279, 4, 1, len(data)),
        (284, 3, 1, 1), (339, 3, 1, 1),
    ]
    out = bytearray(b"II" + struct.pack("<HI", 42, ifd_offset))
    out += struct.pack("<H", entries)
    for tag, typ, count, value in items:
        out += struct.pack("<HHI", tag, typ, count)
        out += struct.pack("<HH", value, 0) if typ == 3 and count == 1 else struct.pack("<I", value)
    out += struct.pack("<I", 0)
    out += struct.pack("<HHH", 16, 16, 16)
    out += data
    with open(path, "wb") as f:
        f.write(out)


def write_pfm(path, width, height, pixels):
    """Portable Float Map: header, then float32 samples, rows bottom-up."""
    with open(path, "wb") as f:
        f.write(b"PF\n%d %d\n-1.0\n" % (width, height))
        for y in reversed(range(height)):
            for x in range(width):
                r, g, b = pixels[y][x]
                f.write(struct.pack("<fff", r / 65535.0, g / 65535.0, b / 65535.0))


if __name__ == "__main__":
    import os
    import subprocess
    import tempfile

    outdir = sys.argv[1] if len(sys.argv) > 1 else "src/testdata"
    reference_tool = sys.argv[2] if len(sys.argv) > 2 else None
    width, height = 16, 120
    rows = [[pixel(x, y) for x in range(width)] for y in range(height)]

    path = f"{outdir}/spectrum16.pfm"
    write_pfm(path, width, height, rows)
    print(f"{path}: {width}x{height}, {len(rows[0])} columns")

    if reference_tool:
        with tempfile.TemporaryDirectory() as tmp:
            tiff = os.path.join(tmp, "spectrum16.tif")
            write_tiff(tiff, width, height, rows)
            debug = subprocess.run([reference_tool, tiff, "debug"], capture_output=True, text=True).stdout
            readout = subprocess.run([reference_tool, tiff], capture_output=True, text=True).stdout
        reference = f"{outdir}/spectrum16.reference.txt"
        with open(reference, "w") as f:
            f.write(debug + "---\n" + readout)
        print(f"{reference}: {len(debug) + len(readout) + 4} bytes from {reference_tool}")
