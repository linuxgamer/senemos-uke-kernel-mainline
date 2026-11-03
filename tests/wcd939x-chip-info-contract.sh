#!/usr/bin/env bash
# Actual codec identification helper with fake register reads; no device access.
set -euo pipefail
kernel=${1:?Pass prepared kernel tree}
source_file=$kernel/sound/soc/codecs/wcd939x.c
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <errno.h>
#include <limits.h>
#include <stdbool.h>
#include <stdio.h>
#define GENMASK(h, l) ((UINT_MAX << (l)) & (UINT_MAX >> (31 - (h))))
#define FIELD_GET(mask, value) (((value) & (mask)) >> __builtin_ctz(mask))
#define WCD939X_VERSION_1_0 0
#define WCD939X_VERSION_1_1 1
#define WCD939X_VERSION_2_0 2
struct device {int unused;};
struct regmap {int unused;};
struct wcd939x_priv {struct regmap *regmap; int variant;};
static struct device device;
static struct regmap map;
static unsigned int reads, reports, revision, status, efuse, expected_version;
static int failure_at, failure;
C
awk '/^#define CHIPID_WCD939/ {print}' "$source_file" >> "$work/check.c"
awk '/^#define WCD939X_(DIGITAL_CHIP_ID1|EAR_STATUS_REG_1|DIGITAL_EFUSE_REG_0|EFUSE_REG_0_WCD939X_ID)[[:space:]]/ {print}' \
    "$kernel/sound/soc/codecs/wcd939x.h" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
static int regmap_read_bypassed(struct regmap *m, unsigned int reg, unsigned int *value)
{
 const unsigned int regs[] = {WCD939X_DIGITAL_CHIP_ID1, WCD939X_EAR_STATUS_REG_1,
                              WCD939X_DIGITAL_EFUSE_REG_0};
 const unsigned int values[] = {revision, status, efuse};
 assert(m == &map && reads < 3 && reg == regs[reads]);
 reads++;
 if ((int)reads == failure_at) return failure;
 *value = values[reads - 1];
 return 0;
}
static int dev_err_probe(struct device *dev, int error, const char *message)
{ assert(dev == &device && message); return error; }
static const char *version_to_str(unsigned int version)
{ assert(version == expected_version); return "qualified source revision"; }
static void checked_report(struct device *dev, const char *fmt, const char *version)
{ assert(dev == &device && fmt && version && reads == 3); reports++; }
#define dev_dbg checked_report
C
awk '/^static int wcd939x_read_chip_info\(/ {emit=1}
 emit {print} emit && /^}/ {found=1; exit}
 END {if (!found) exit 1}' "$source_file" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
static void clear(struct wcd939x_priv *w)
{
 w->regmap = &map; w->variant = -1;
 reads = reports = revision = status = efuse = expected_version = 0;
 failure_at = failure = 0;
}
int main(void)
{
 struct wcd939x_priv w;
 unsigned int scenarios = 0;
 for (unsigned int major = 0; major < 2; major++) {
  for (unsigned int minor = 0; minor < 4; minor++) {
   for (unsigned int variant = 0; variant < 16; variant++) {
    clear(&w); revision = major; status = 0xc0 | minor; efuse = 0xa1 | (variant << 1);
    expected_version = major ? WCD939X_VERSION_2_0 :
                       minor ? WCD939X_VERSION_1_1 : WCD939X_VERSION_1_0;
    int rc = wcd939x_read_chip_info(&device, &w);
    bool supported = variant == CHIPID_WCD9390 || variant == CHIPID_WCD9395;
    assert(rc == (supported ? 0 : -ENODEV) && reads == 3);
    assert(w.variant == (supported ? (int)variant : -1) && reports == supported);
    scenarios++;
   }
  }
 }
 for (unsigned int unsupported = 2; unsupported <= 255; unsupported++) {
  clear(&w); revision = unsupported;
  assert(wcd939x_read_chip_info(&device, &w) == -ENODEV);
  assert(reads == 1 && !reports && w.variant == -1);
  scenarios++;
 }
 const int errors[] = {-EIO, -EREMOTEIO, -ETIMEDOUT};
 for (unsigned int stage = 1; stage <= 3; stage++) {
  for (unsigned int error = 0; error < 3; error++) {
   clear(&w); failure_at = stage; failure = errors[error];
   assert(wcd939x_read_chip_info(&device, &w) == failure);
   assert(reads == stage && !reports && w.variant == -1);
   scenarios++;
  }
 }
 assert(scenarios == 391);
 puts("WCD939x actual identity helper: 391 memory-only cases passed; physical silicon identity NOT_READ.");
}
C
${CC:-cc} -std=gnu11 -Wall -Wextra -Werror -fsanitize=address,undefined \
    -fno-omit-frame-pointer "$work/check.c" -o "$work/check"
"$work/check"
