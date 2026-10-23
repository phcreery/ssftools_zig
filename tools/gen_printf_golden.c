/* Regenerates src/testdata/printf_f32.txt.
 *
 * Each line is "<f32 bits as hex> <precision> <printf output>", covering the
 * values where a naive float formatter and C's %f disagree: huge magnitudes,
 * subnormals, exact dyadic ties (round-half-even), NaN/inf sign handling and
 * values with long decimal expansions.
 *
 *     gcc -O2 -o /tmp/gen tools/gen_printf_golden.c && /tmp/gen > src/testdata/printf_f32.txt
 *
 * src/cformat.zig is expected to reproduce the third field byte for byte; the
 * output is portable, since %f is correctly rounded by any conforming libc.
 */
#include <stdio.h>
#include <stdint.h>
#include <string.h>

static uint32_t rng_state = 0x12345678u;
static uint32_t rng(void) {
    rng_state = rng_state * 1664525u + 1013904223u;
    return rng_state;
}

static const int precisions[] = { 0, 2, 6 };
#define NPREC (sizeof(precisions) / sizeof(precisions[0]))

static void emit(uint32_t bits, int precision) {
    float f;
    memcpy(&f, &bits, 4);
    printf("%08x %d %.*f\n", bits, precision, precision, (double)f);
}

static void emit_all(uint32_t bits) {
    for (unsigned p = 0; p < NPREC; p++) emit(bits, precisions[p]);
}

static uint32_t bits_of(float f) {
    uint32_t bits;
    memcpy(&bits, &f, 4);
    return bits;
}

int main(void) {
    /* Zeroes, subnormals, infinities, NaNs, exact ties and the limits. */
    const uint32_t specials[] = {
        0x00000000, 0x80000000, /* +0, -0 */
        0x00000001, 0x007fffff, 0x00800000, /* smallest subnormal, largest subnormal, smallest normal */
        0x3f800000, 0xbf800000, /* 1, -1 */
        0x7f800000, 0xff800000, /* inf, -inf */
        0x7fc00000, 0xffc00000, 0x7f800001, /* quiet NaN, negative NaN, signalling NaN */
        0x7f7fffff, 0xff7fffff, /* FLT_MAX, -FLT_MAX */
        0x3f000000, 0x3e800000, 0x3e000000, 0x3d000000, /* 0.5, 0.25, 0.125, 0.0078125 */
        0x3fc00000, 0x40200000, 0x40000000, /* 1.5, 2.5, 2 */
        0x43000000, 0x42c80000, /* 128, 100 */
        0x3eaaaaab, 0x3eaaaaaa, /* either side of 1/3 */
        0x4a0cbe80, /* 2306873.5: odd/even ties at 0 decimals */
        0x4a0cbe81,
    };
    for (unsigned i = 0; i < sizeof(specials) / sizeof(specials[0]); i++) emit_all(specials[i]);

    /* Uniform [0,1): the shape of a normalised measurement. */
    for (int i = 0; i < 300; i++) {
        float f = (float)(rng() >> 8) / (float)(1 << 24);
        emit_all(bits_of(f));
    }

    /* Uniform [0,1000): beyond the magnitude where std.fmt's padding is safe. */
    for (int i = 0; i < 200; i++) {
        float f = (float)(rng() >> 8) * (1000.0f / (float)(1 << 24));
        emit_all(bits_of(f));
    }

    /* Exact dyadic values: the half-to-even ties. */
    for (int n = 0; n <= 24; n++)
        for (int k = 1; k < 4; k++) emit_all(bits_of((float)k / (float)(1u << n)));

    /* Uniform over the whole f32 range, including huge and denormal values. */
    for (int i = 0; i < 400; i++) emit_all(rng());

    return 0;
}
