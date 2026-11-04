/* SPDX-License-Identifier: GPL-2.0-only */
/* Actual NVMEM mode/access gates, synthetic data and modeled GPIO/backend. */
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
typedef unsigned short umode_t;
struct gpio_desc { int unused; };
struct nvmem_operations {
 int (*reg_read)(void *, unsigned, void *, size_t);
 int (*reg_write)(void *, unsigned, void *, size_t);
};
struct nvmem_device {
 struct nvmem_operations *ops;
 void *priv;
 struct gpio_desc *wp_gpio;
 bool root_only, read_only;
};
static unsigned reads, writes, gpio_calls;
static int gpio_failure;
static int gpiod_set_value_cansleep(struct gpio_desc *gpio, int value)
{
 assert(gpio && (value == 0 || value == 1));
 gpio_calls++;
 return gpio_failure;
}
static int read_bytes(void *priv, unsigned off, void *buf, size_t count)
{ assert(off == 0 && count == 1); reads++; memcpy(buf, priv, count); return 0; }
static int write_bytes(void *priv, unsigned off, void *buf, size_t count)
{ assert(off == 0 && count == 1); writes++; memcpy(priv, buf, count); return 0; }
#include "__nvmem_reg_read.h"
#include "__nvmem_reg_write.h"
#include "nvmem_bin_attr_get_umode.h"
int main(void)
{
 unsigned char synthetic = 0xa5, output = 0, replacement = 0x5a;
 struct gpio_desc wp;
 struct nvmem_operations ops = {read_bytes, NULL};
 struct nvmem_device dev = {&ops, &synthetic, &wp, true, true};
 assert(nvmem_bin_attr_get_umode(&dev) == 0400);
 assert(!__nvmem_reg_read(&dev, 0, &output, 1) && output == 0xa5 && reads == 1);
 assert(__nvmem_reg_write(&dev, 0, &replacement, 1) == -EOPNOTSUPP);
 assert(!writes && !gpio_calls && synthetic == 0xa5);
 /* Changing only the generic read_only flag cannot add the missing writer. */
 dev.read_only = false;
 assert(nvmem_bin_attr_get_umode(&dev) == 0400);
 assert(__nvmem_reg_write(&dev, 0, &replacement, 1) == -EOPNOTSUPP);
 assert(!writes && !gpio_calls && synthetic == 0xa5);
 dev.read_only = true; dev.root_only = false;
 assert(nvmem_bin_attr_get_umode(&dev) == 0444);
 dev.root_only = true; ops.reg_read = NULL;
 assert(nvmem_bin_attr_get_umode(&dev) == 0);
 assert(__nvmem_reg_read(&dev, 0, &output, 1) == -EOPNOTSUPP);
 /* Retain a genuine normal-writer comparison on fake bytes only. */
 ops.reg_read = read_bytes; ops.reg_write = write_bytes; dev.read_only = false;
 assert(nvmem_bin_attr_get_umode(&dev) == 0600);
 assert(!__nvmem_reg_write(&dev, 0, &replacement, 1));
 assert(writes == 1 && gpio_calls == 2 && synthetic == 0x5a);
 gpio_failure = -EIO;
 assert(__nvmem_reg_write(&dev, 0, &replacement, 1) == -EIO && writes == 1);
 puts("Actual NVMEM: root-only 0400, no write/WP callbacks even after a read_only flag change, read refusal and normal synthetic writer/error controls pass; no device data");
 return 0;
}
