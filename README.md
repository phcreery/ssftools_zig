# ssftool, in Zig

Zig implementations of the two ssftool command line tools, which turn spectral
measurements into the data used to build camera profiles.

| Binary | Job |
| --- | --- |
| `pfm2specdata` | Reads a Portable Float Map of a spectrum; prints one `x,r,g,b` row per column. |
| `ssftool` | Formats, calibrates, resamples and normalises those rows. |

Standard library only, no dependencies.

## Building

```bash
zig build                 # zig-out/bin/{pfm2specdata,ssftool}
zig build run -- <args>   # build and run ssftool
```

## Usage

`ssftool` with no arguments prints its operators and their arguments. The shape
of a run is:

```
pfm2specdata <spectrum.pfm> [debug] | ssftool <operator> [datafile] [parameters...]
```

Two captures to a normalised spectrum:

```bash
pfm2specdata spectrum.pfm    > spectrum.csv
pfm2specdata calibration.pfm > calibration.csv
ssftool wavelengthcalibrate spectrum.csv blue=437,green=546,red=611 calibration.csv \
  | ssftool intervalize 400,715,5 \
  | ssftool powercalibrate Dedolight_5nm.csv \
  | ssftool normalize \
  | ssftool format 2
```

`pfm2specdata` prints the columns right to left, so index 0 is the rightmost
pixel; the capture's long wavelengths belong on the left for the wavelengths to
increase down the file. `debug` prints the detection — channel maxima,
thresholds, brightest green, crop box — instead of the data.

### Input

`pfm2specdata` reads Portable Float Maps:

```
PF\n<width> <height>\n<scale>\n<width*height*channels float32 samples>
```

`PF` is RGB and `Pf` is grayscale, which is rejected. The scale's sign selects
the byte order (negative is little-endian), exactly one whitespace byte ends the
header, and rows are stored bottom-up.

`ssftool` reads and writes comma-separated `w,r,g,b` rows, with fewer channels
allowed.

## Testing

```bash
zig build test     # unit tests, no C toolchain needed
zig build compat   # differential test against the original C++ programs
```

`compat` needs a checkout of the original for its reference binaries:

```bash
zig build compat -Dc-checkout=/path/to/ssftool
```

It compares only the data each tool writes to stdout — never exit statuses,
messages or usage text — over 71 `ssftool` cases (67 value-identical, 3 verified
deviations, plus the demo pipeline), and checks `pfm2specdata`'s detection and
readout against the C++ `tiff2specdata` on the equivalent TIFF. Where this port
deliberately produces different values, `src/compat.zig` asserts what it
produces instead.
