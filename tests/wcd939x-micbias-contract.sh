#!/usr/bin/env bash
# Actual codec functions with memory-only register/PM stubs; no device access.
set -euo pipefail
kernel=${1:?Pass prepared kernel tree}
source_file=$kernel/sound/soc/codecs/wcd939x.c
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))
#define WCD939X_ANA_MICB1 0x3022
#define WCD939X_ANA_MICB2 0x3023
#define WCD939X_ANA_MICB3 0x3025
#define WCD939X_ANA_MICB4 0x3026
#define WCD939X_MICB_VOUT_CTL 0x3f
#define WCD939X_DIGITAL_EFUSE_REG_0 0x34b0
#define WCD939X_EFUSE_REG_0_WCD939X_ID 0x1e
struct device { int unused; };
struct regmap { unsigned int hardware[4], cache[4]; };
struct wcd939x_priv {
 struct regmap *regmap;
 struct { unsigned int micb_vout[4]; } common;
 int tx_sdw_dev, variant;
};
struct snd_soc_component { struct device *dev; };
static const unsigned int registers[] = {0x3022, 0x3023, 0x3025, 0x3026};
static struct regmap map;
static struct device device;
static struct wcd939x_priv codec;
static unsigned int updates, reads, waits, resumes, pm_puts, init_regmap;
static int update_failure, read_failure, dropped_write, wait_error, resume_error;
static int chip_error;
static int __attribute__((unused)) dev_err_probe(struct device *dev, int error, const char *message)
{ assert(dev == &device && message); return error; }
static unsigned int index_of(unsigned int reg)
{
 for (unsigned int i = 0; i < ARRAY_SIZE(registers); i++)
  if (registers[i] == reg) return i;
 assert(false); return 0;
}
static int regmap_update_bits(struct regmap *m, unsigned int reg,
                              unsigned int mask, unsigned int value)
{
 unsigned int i = index_of(reg);
 assert(m == &map && mask == WCD939X_MICB_VOUT_CTL);
 assert(i == updates && reads == updates && value <= mask);
 updates++;
 if ((int)updates == update_failure) return -EREMOTEIO;
 m->cache[i] = (m->cache[i] & ~mask) | value;
 if ((int)updates != dropped_write)
  m->hardware[i] = (m->hardware[i] & ~mask) | value;
 return 0;
}
static int __attribute__((unused)) regmap_read_bypassed(struct regmap *m,
                                           unsigned int reg, unsigned int *value)
{
 unsigned int i = index_of(reg);
 assert(m == &map && i == reads && updates == reads + 1);
 reads++;
 if ((int)reads == read_failure) return -ETIMEDOUT;
 *value = m->hardware[i];
 return 0;
}
C
awk '/^static (int|void) wcd939x_set_micbias_data\(/ {emit=1}
 emit {print} emit && /^}/ {exit}' "$source_file" >> "$work/check.c"
if grep -q '^static int wcd939x_set_micbias_data(' "$source_file"; then
    printf '#define program_bias() wcd939x_set_micbias_data(&device, &codec)\n' >> "$work/check.c"
else
    # Keep the old void-returning source executable for the regression check.
    cat >> "$work/check.c" <<'C'
static int program_bias(void) { wcd939x_set_micbias_data(&device, &codec); return 0; }
C
fi
cat >> "$work/check.c" <<'C'
static int sdw_slave_wait_for_init(int dev, int timeout)
{ assert(dev == 1 && timeout == 2000); waits++; return wait_error; }
static void snd_soc_component_init_regmap(struct snd_soc_component *component, struct regmap *m)
{ assert(component->dev == &device && m == &map && waits == 1); init_regmap++; }
static int pm_runtime_resume_and_get(struct device *dev)
{ assert(dev == &device && init_regmap == 1); resumes++; return resume_error; }
static void __attribute__((unused)) pm_runtime_put(struct device *dev)
{ assert(dev == &device && resumes == 1 && resume_error >= 0); pm_puts++; }
static int __attribute__((unused)) snd_soc_component_read_field(struct snd_soc_component *component,
                                       unsigned int reg, unsigned int mask)
{
 assert(component->dev == &device && reg == WCD939X_DIGITAL_EFUSE_REG_0);
 assert(mask == WCD939X_EFUSE_REG_0_WCD939X_ID && resumes == 1);
 return 5;
}
static int __attribute__((unused)) wcd939x_read_chip_info(struct device *dev,
                                                        struct wcd939x_priv *wcd)
{ assert(dev == &device && wcd == &codec && resumes == 1); return chip_error; }
static int actual_initialization_guard(struct snd_soc_component *component)
{
 struct device *dev = component->dev;
 struct wcd939x_priv *wcd939x = &codec;
 int ret;
C
awk '
 /^static int wcd939x_soc_codec_probe\(/ {in_probe=1}
 in_probe && /ret = sdw_slave_wait_for_init\(/ {emit=1}
 emit && /wcd939x->clsh_info =/ {found=1; exit}
 emit {print}
 END {if (!found) exit 1}
' "$source_file" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
 return 0;
}
static void clear(void)
{
 memset(&map, 0, sizeof(map)); memset(&codec, 0, sizeof(codec));
 codec.regmap = &map; codec.tx_sdw_dev = 1;
 updates = reads = waits = resumes = pm_puts = init_regmap = 0;
 update_failure = read_failure = dropped_write = wait_error = resume_error = 0;
 chip_error = 0;
 for (unsigned int i = 0; i < ARRAY_SIZE(registers); i++) {
  codec.common.micb_vout[i] = (unsigned int[]){0, 1, 38, 63}[i];
  map.hardware[i] = 0xc0 | (codec.common.micb_vout[i] ^ 1);
  map.cache[i] = 0xc0 | codec.common.micb_vout[i];
 }
}
int main(void)
{
 struct snd_soc_component component = {&device};
 clear(); assert(program_bias() == 0); assert(updates == 4 && reads == 4);
 for (unsigned int i = 0; i < ARRAY_SIZE(registers); i++)
  assert(map.hardware[i] == (0xc0 | codec.common.micb_vout[i]));
 for (unsigned int fail = 1; fail <= 4; fail++) {
  clear(); update_failure = fail;
  assert(program_bias() == -EREMOTEIO && updates == fail && reads == fail - 1);
  clear(); read_failure = fail;
  assert(program_bias() == -ETIMEDOUT && updates == fail && reads == fail);
  clear(); dropped_write = fail;
  assert(program_bias() == -EIO && updates == fail && reads == fail);
 }
 clear(); wait_error = -ETIMEDOUT;
 assert(actual_initialization_guard(&component) == -ETIMEDOUT);
 assert(waits == 1 && !resumes && !pm_puts && !updates && !reads);
 clear(); resume_error = -EIO;
 assert(actual_initialization_guard(&component) == -EIO);
 assert(waits == 1 && resumes == 1 && !pm_puts && !updates && !reads);
 for (unsigned int error = 0; error < 2; error++) {
  clear(); chip_error = error ? -EIO : -ENODEV;
  assert(actual_initialization_guard(&component) == chip_error);
  assert(pm_puts == 1 && !updates && !reads);
 }
 for (unsigned int fail = 1; fail <= 4; fail++) {
  clear(); update_failure = fail;
  assert(actual_initialization_guard(&component) == -EREMOTEIO && pm_puts == 1);
  clear(); read_failure = fail;
  assert(actual_initialization_guard(&component) == -ETIMEDOUT && pm_puts == 1);
  clear(); dropped_write = fail;
  assert(actual_initialization_guard(&component) == -EIO && pm_puts == 1);
 }
 clear(); assert(actual_initialization_guard(&component) == 0);
 assert(waits == 1 && resumes == 1 && !pm_puts && updates == 4 && reads == 4);
 puts("WCD939x actual bias functions: 30 memory-only cases passed; physical capture NOT_RUN.");
}
C
${CC:-cc} -std=gnu11 -Wall -Wextra -Werror -Wno-unused-parameter \
    -fsanitize=address,undefined -fno-omit-frame-pointer "$work/check.c" -o "$work/check"
"$work/check"
