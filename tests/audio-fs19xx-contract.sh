#!/usr/bin/env bash
# Actual FS19xx preset parser and register-table functions with host mocks;
# no I2C, GPIO, amplifier or speaker access. Set FS19XX_PRESET to also parse a
# private OEM preset locally (never stored in this repository).
set -Eeuo pipefail
kernel=${1:?Pass prepared kernel tree}
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
source_file=$kernel/sound/soc/codecs/fs19xx.c
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
extract_function() {
    awk -v name="$1" '
      $0 ~ "^static [^(]*[ *]" name "\\(" {emit=1}
      emit {print}
      emit && /^}/ {exit}
    ' "$source_file"
}
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef uint8_t u8; typedef uint16_t u16; typedef uint32_t u32;
typedef uint16_t __le16; typedef uint32_t __le32;
#define __packed __attribute__((packed))
#define GFP_KERNEL 0
#define BIT(n) (1UL << (n))
#define GENMASK(h, l) ((~0UL << (l)) & (~0UL >> (63 - (h))))
#define FIELD_GET(m, v) (((unsigned long)(v) & (m)) >> __builtin_ctzl(m))
#define FIELD_PREP(m, v) (((unsigned long)(v) << __builtin_ctzl(m)) & (m))
#define le16_to_cpu(x) (x)
#define cpu_to_le16(x) (x)
#define check_mul_overflow(a, b, d) __builtin_mul_overflow(a, b, d)
#define dev_dbg(dev, ...) ((void)0)
#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))
#define is_power_of_2(v) ((v) && !((v) & ((v)-1)))
static u16 get_unaligned_le16(const void *p) { u16 v; memcpy(&v, p, 2); return v; }
static u16 crc16(u16 crc, const u8 *p, size_t len) {
    while (len--) { crc ^= *p++; for (int i = 0; i < 8; i++) crc = crc & 1 ? (crc >> 1) ^ 0xA001 : crc >> 1; }
    return crc;
}
struct device { int unused; };
struct i2c_client { unsigned addr; };
struct mutex { int unused; };
struct delayed_work { int unused; };
struct gpio_desc;
struct regmap { u16 reg[256]; unsigned writes[256]; unsigned log_n; u16 log[512]; bool fail_read; };
static unsigned total_sleep_ms;
static void msleep(unsigned ms) { total_sleep_ms += ms; }
static void usleep_range(unsigned a, unsigned b) { (void)a; (void)b; }
static int regmap_read(struct regmap *m, unsigned reg, unsigned *val) {
    if (m->fail_read) return -EIO;
    *val = m->reg[reg]; return 0;
}
static int regmap_write(struct regmap *m, unsigned reg, unsigned val) {
    m->reg[reg] = val; m->writes[reg]++;
    if (m->log_n < 256) { m->log[2 * m->log_n] = reg; m->log[2 * m->log_n + 1] = val; m->log_n++; }
    return 0;
}
static unsigned live_allocations;
static void *devm_kmemdup(struct device *dev, const void *src, size_t len, int gfp) {
    void *p = malloc(len); (void)dev; (void)gfp;
    if (p) { memcpy(p, src, len); live_allocations++; }
    return p;
}
static void devm_kfree(struct device *dev, void *p) { (void)dev; live_allocations--; free(p); }
C
awk '/^#define FS19XX_DEFAULT_FW_NAME/ {emit=1} /^static int fs19xx_read_stable/ {exit} emit {print}' \
    "$source_file" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
#define min_t(t, a, b) ((t)(a) < (t)(b) ? (t)(a) : (t)(b))
C
for fn in fs19xx_read_stable fs19xx_apply_unit fs19xx_write_tables fs19xx_list_at fs19xx_find_sub fs19xx_parse_dev fs19xx_parse_preset; do
    extract_function "$fn" >> "$work/check.c"
    # Fail loudly if a function was renamed: extraction would otherwise silently shrink the test.
    grep -Fq "$fn(" "$work/check.c"
done
cat >> "$work/check.c" <<'C'

/* ---- preset builder: mirrors the OEM file layout, little endian ---- */
struct blob { u8 d[8192]; size_t n; };
static void put16(struct blob *b, unsigned v) { b->d[b->n++] = v; b->d[b->n++] = v >> 8; }
static void put32(struct blob *b, unsigned v) { put16(b, v); put16(b, v >> 16); }
static unsigned unit_ctrl(unsigned addr, unsigned pos, unsigned len) { return addr | pos << 8 | len << 12; }
struct opt { unsigned addr, chip, tcoef, pos, preset_ver; int spk_words; int common_extra; unsigned scene_mask_bit; };
/* One device body: dev_list header (40 bytes) + 3 index entries + spk info + common + scenes. */
static size_t build_dev(struct blob *b, const struct opt *o) {
    size_t start = b->n;
    unsigned spk = o->spk_words ? o->spk_words : 17;
    put16(b, o->preset_ver); for (int i = 0; i < 16; i++) b->d[b->n++] = 0;
    put32(b, 0); put16(b, 0); put16(b, 0);
    put16(b, 3);               /* len: three sub-lists */
    put16(b, 0); put16(b, o->addr); put16(b, o->chip << 8 | 0xa1);
    put16(b, 0); put16(b, 0x00ff); put16(b, 0);
    size_t index = b->n;
    unsigned off = 12;         /* three index entries of four bytes */
    put16(b, off); put16(b, 1); off += 2 + spk * 2;
    put16(b, off); put16(b, 2); off += 2 + 7 * 4 + o->common_extra * 4;
    put16(b, off); put16(b, 3);
    (void)index;
    put16(b, spk);
    for (unsigned i = 0; i < spk; i++) put16(b, i == 1 ? o->tcoef : i == 16 ? o->pos : 0);
    put16(b, 7 + o->common_extra);
    put16(b, unit_ctrl(0x20, 0, 15)); put16(b, 0x1234);        /* full write */
    put16(b, unit_ctrl(0x21, 4, 3));  put16(b, 0x0005);        /* field 4..7 = 5 */
    put16(b, unit_ctrl(0, 0xf, 1));   put16(b, 7);             /* delay 7 ms */
    put16(b, unit_ctrl(0x22, 0xf, 2)); put16(b, 0x0100 | 0);   /* wait: val 0, pos 0, len 1 */
    put16(b, unit_ctrl(0x23, 0, 0));  put16(b, 1);             /* single bit */
    put16(b, unit_ctrl(0x24, 15, 0)); put16(b, 1);             /* bit 15 */
    put16(b, unit_ctrl(0x25, 0, 15)); put16(b, 0xbeef);
    for (int i = 0; i < o->common_extra; i++) { put16(b, unit_ctrl(0x30, 0, 15)); put16(b, 0); }
    put16(b, 3);
    put16(b, 0x0001); put16(b, unit_ctrl(0x40, 0, 15)); put16(b, 0x1111);   /* music scene */
    put16(b, 0x0002); put16(b, unit_ctrl(0x41, 0, 15)); put16(b, 0x2222);   /* other scene */
    put16(b, 0x0001); put16(b, unit_ctrl(0x42, 8, 7));  put16(b, 0x00a5);   /* music, upper byte */
    return b->n - start;
}
static void finish(struct blob *b, unsigned ndev_pos_ndev) {
    (void)ndev_pos_ndev;
    b->d[22] = b->n; b->d[23] = b->n >> 8;           /* hdr.size */
    unsigned crc = crc16(0, b->d + 26, b->n - 26);
    b->d[24] = crc; b->d[25] = crc >> 8;
}
static size_t build_preset(struct blob *b, const struct opt *o, int ndev) {
    size_t starts[4], sizes[4];
    b->n = 0;
    put16(b, 0x0100); for (int i = 0; i < 16; i++) b->d[b->n++] = 0;
    put32(b, 0); put16(b, 0); put16(b, 0); put16(b, ndev);
    size_t idx = b->n;
    for (int i = 0; i < ndev; i++) { put16(b, 0); put16(b, 0); }
    for (int i = 0; i < ndev; i++) { starts[i] = b->n; sizes[i] = build_dev(b, &o[i]); }
    for (int i = 0; i < ndev; i++) { b->d[idx + 4 * i] = starts[i]; b->d[idx + 4 * i + 1] = starts[i] >> 8; }
    finish(b, ndev);
    (void)sizes;
    return b->n;
}

static struct regmap fake;
static struct device dev;
static struct i2c_client i2c;
static struct fs19xx_priv priv;
static void reset_priv(unsigned addr) {
    if (priv.preset) { devm_kfree(&dev, priv.preset); }
    memset(&fake, 0, sizeof fake); memset(&priv, 0, sizeof priv);
    i2c.addr = addr; priv.i2c = &i2c; priv.dev = &dev; priv.regmap = &fake;
    total_sleep_ms = 0;
}
static int parse(const struct blob *b, unsigned addr, unsigned chip) {
    reset_priv(addr);
    return fs19xx_parse_preset(&priv, b->d, b->n, chip);
}

int main(int argc, char **argv) {
    struct opt devs[4] = {
        { 0x36, 0x29, 258, 4, 0xb0ce, 0, 0, 0 }, { 0x37, 0x29, 258, 1, 0xb0ce, 0, 2, 0 },
        { 0x34, 0x29, 258, 8, 0xb0ce, 0, 0, 0 }, { 0x35, 0x29, 300, 2, 0xb0ce, 0, 0, 0 },
    };
    static struct blob good, bad;
    build_preset(&good, devs, 4);

    /* Every device is found by I2C address; position and coefficient come from the preset. */
    const unsigned pos[4] = { 8, 2, 4, 1 };
    for (unsigned a = 0x34; a <= 0x37; a++) {
        assert(parse(&good, a, 0x29) == 0);
        assert(priv.position == pos[a - 0x34]);
        assert(priv.tcoef == (a == 0x35 ? 300 : 258));
        assert(priv.ncommon == (a == 0x37 ? 9 : 7) && priv.nscenes == 3);
        assert(priv.preset && priv.preset_size == good.n);
    }
    assert(parse(&good, 0x38, 0x29) == -ENOENT);

    /* Register tables: full write, field RMW, delay, wait, single bits, scene filtering. */
    assert(parse(&good, 0x34, 0x29) == 0);
    fake.reg[0x21] = 0xffff; fake.reg[0x23] = 0xfffe; fake.reg[0x24] = 0x7fff; fake.reg[0x42] = 0x1234;
    assert(fs19xx_write_tables(&priv) == 0);
    assert(fake.reg[0x20] == 0x1234 && fake.reg[0x25] == 0xbeef);
    assert(fake.reg[0x21] == ((0xffff & ~(0xfu << 4)) | (5u << 4)));
    assert(fake.reg[0x23] == 0xffff && fake.reg[0x24] == 0xffff);
    assert(total_sleep_ms >= 7);                  /* delay op honoured */
    assert(fake.reg[0x40] == 0x1111);             /* music scene applied */
    assert(fake.reg[0x41] == 0);                  /* other scene skipped */
    assert(fake.reg[0x42] == 0xa534);             /* RMW of an eight-bit field at bit 8 */
    assert(fake.writes[0x22] == 0 && fake.writes[0x00] == 0);   /* pseudo-ops never write */

    /* Read failures abort the table instead of writing stale data. */
    memset(&fake, 0, sizeof fake); fake.fail_read = true;
    assert(fs19xx_write_tables(&priv) == -EIO);

    /* Delay pseudo-op above the sane ceiling is rejected, not slept. */
    struct fs19xx_reg_unit slow = { 0 | 0xf00 | 1 << 12, 5000 };
    assert(fs19xx_apply_unit(&priv, &slow) == -EINVAL);

    /* Rejections: chip family, preset version, size, CRC, bounds. */
    assert(parse(&good, 0x34, 0x17) == -EINVAL);
    bad = good; bad.d[good.n - 1] ^= 1;
    assert(parse(&bad, 0x34, 0x29) == -EINVAL);                     /* bad CRC */
    bad = good; bad.n -= 2;
    assert(parse(&bad, 0x34, 0x29) == -EINVAL);                     /* size mismatch */
    bad.n = 10;
    assert(parse(&bad, 0x34, 0x29) == -EINVAL);                     /* shorter than header */
    struct opt old[1] = { { 0x34, 0x29, 258, 8, 0x30ce, 0, 0, 0 } };
    build_preset(&bad, old, 1);
    assert(parse(&bad, 0x34, 0x29) == -EINVAL);                     /* version bit 15 clear */
    struct opt short_spk[1] = { { 0x34, 0x29, 258, 8, 0xb0ce, 16, 0, 0 } };
    build_preset(&bad, short_spk, 1);
    assert(parse(&bad, 0x34, 0x29) == -EINVAL);                     /* no position word */
    struct opt wrong_position[1] = { { 0x34, 0x29, 258, 3, 0xb0ce, 0, 0, 0 } };
    build_preset(&bad, wrong_position, 1);
    assert(parse(&bad, 0x34, 0x29) == -EINVAL);
    wrong_position[0].pos = 16;
    build_preset(&bad, wrong_position, 1);
    assert(parse(&bad, 0x34, 0x29) == -EINVAL);
    wrong_position[0].pos = 8; wrong_position[0].tcoef = 0;
    build_preset(&bad, wrong_position, 1);
    assert(parse(&bad, 0x34, 0x29) == -EINVAL);
    wrong_position[0].tcoef = 0x8000;
    build_preset(&bad, wrong_position, 1);
    assert(parse(&bad, 0x34, 0x29) == -EINVAL);
    wrong_position[0].tcoef = 0xffff;
    build_preset(&bad, wrong_position, 1);
    assert(parse(&bad, 0x34, 0x29) == -EINVAL);
    wrong_position[0].tcoef = 0x7fff;
    build_preset(&bad, wrong_position, 1);
    assert(parse(&bad, 0x34, 0x29) == 0);
    struct opt huge[1] = { { 0x34, 0x29, 258, 8, 0xb0ce, 0, 0, 0 } };
    build_preset(&bad, huge, 1);
    {   /* a sub-list claiming more entries than the file holds, with a recomputed CRC */
        size_t dev_start = bad.d[28] | bad.d[29] << 8;
        size_t common = dev_start + 40 + (bad.d[dev_start + 40 + 4] | bad.d[dev_start + 40 + 5] << 8);
        bad.d[common] = 0xff; bad.d[common + 1] = 0xff;
        unsigned crc = crc16(0, bad.d + 26, bad.n - 26); bad.d[24] = crc; bad.d[25] = crc >> 8;
        assert(parse(&bad, 0x34, 0x29) == -EINVAL);
    }
    build_preset(&bad, huge, 1);
    {   /* an index offset pointing outside the blob */
        size_t dev_start = bad.d[28] | bad.d[29] << 8;
        bad.d[dev_start + 40 + 4] = 0xf0; bad.d[dev_start + 40 + 5] = 0xff;
        unsigned crc = crc16(0, bad.d + 26, bad.n - 26); bad.d[24] = crc; bad.d[25] = crc >> 8;
        assert(parse(&bad, 0x34, 0x29) == -EINVAL);
    }
    build_preset(&bad, huge, 1);
    {   /* a device-list offset pointing outside the blob */
        bad.d[28] = 0xff; bad.d[29] = 0xff;
        unsigned crc = crc16(0, bad.d + 26, bad.n - 26); bad.d[24] = crc; bad.d[25] = crc >> 8;
        assert(parse(&bad, 0x34, 0x29) == -EINVAL);
    }
    /* Device count larger than the index the file contains. */
    build_preset(&bad, huge, 1);
    bad.d[22] = 0x00; bad.d[23] = 0x00;                              /* hdr.size = 0 */
    assert(parse(&bad, 0x34, 0x29) == -EINVAL);

    if (argc == 2) {  /* optional private OEM preset: structure only, nothing printed from it */
        FILE *f = fopen(argv[1], "rb"); static struct blob real;
        assert(f); real.n = fread(real.d, 1, sizeof real.d, f); fclose(f);
        for (unsigned a = 0x34; a <= 0x37; a++) assert(parse(&real, a, 0x29) == 0);
        printf("private preset parsed for four amplifiers\n");
    }
    /* Rejected presets must not keep their copy; only the last accepted one is live. */
    reset_priv(0x34);
    assert(live_allocations == 0);
    printf("FS19xx preset/register-table fixtures passed\n");
    return 0;
}
C
# Prefer the full sanitizers; hosts without the compiler-rt runtime still get trapping UBSan.
flags=(-O1 -g -Wall -Wno-unused-function -Wno-unused-parameter)
if ! ${CC:-clang} "${flags[@]}" -fsanitize=address,undefined -fno-sanitize-recover=undefined \
        -o "$work/check" "$work/check.c" 2>/dev/null; then
    ${CC:-clang} "${flags[@]}" -fsanitize=undefined -fsanitize-trap=all -o "$work/check" "$work/check.c"
fi
if [[ -n ${FS19XX_PRESET:-} ]]; then "$work/check" "$FS19XX_PRESET"; else "$work/check"; fi
