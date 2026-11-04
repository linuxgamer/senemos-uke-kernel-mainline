/* SPDX-License-Identifier: GPL-2.0-only */
/* Import the actual guard; model the Linux resource and powered-MMIO boundary. */
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#define __iomem
#define IORESOURCE_MEM 1
#define BIT(n) (1U << (n))
typedef uint64_t resource_size_t;
struct device { int unused; };
struct platform_device { struct device dev; };
struct resource { resource_size_t start, end; };
static struct platform_device device;
static struct resource resource;
static bool missing, busy, fail_map, reserved, mapped;
static unsigned int requests, releases, reads, maps, unmaps;
static int power_error, gate_error;
static unsigned int gate_reads;
static bool gate_on;
static uint32_t words[0x2000 / 4];
struct regmap { int unused; };
static struct regmap controller_map;
static struct { struct regmap *map; } cam_cc_power;
static const char *dev_name(struct device *dev) { assert(dev == &device.dev); return "model"; }
static struct resource *platform_get_resource_byname(struct platform_device *dev, int type, const char *name)
{ assert(dev == &device && type == IORESOURCE_MEM && !strcmp(name, "crm")); return missing ? NULL : &resource; }
static resource_size_t resource_size(struct resource *res) { return res->end - res->start + 1; }
static struct resource *request_mem_region(resource_size_t start, resource_size_t size, const char *name)
{
	assert(start == 0xadd7000 && size == 0x2000 && !strcmp(name, "model"));
	requests++; if (busy || reserved) return NULL; reserved = true; return &resource;
}
static void release_mem_region(resource_size_t start, resource_size_t size)
{ assert(start == 0xadd7000 && size == 0x2000 && reserved && !mapped); reserved = false; releases++; }
static void *ioremap(resource_size_t start, resource_size_t size)
{ assert(start == 0xadd7000 && size == 0x2000 && reserved && !mapped); maps++; if (fail_map) return NULL; mapped = true; return words; }
static void iounmap(void *base) { assert(base == words && mapped && reserved); mapped = false; unmaps++; }
static int cam_cc_power_access(void *power, unsigned int reg)
{ assert(power == &cam_cc_power && !reg); return power_error; }
static int regmap_read(struct regmap *map, unsigned int reg, unsigned int *value)
{ assert(map == &controller_map && reg == 0x13318 && !power_error); gate_reads++; if (gate_error) return gate_error; *value = gate_on ? 1 : 0; return 0; }
static uint32_t readl(void *address)
{ assert(mapped && reserved && !power_error && gate_on && !gate_error && address == &words[3]); reads++; return words[3]; }
#include "crm-guard.h"
static void reset(void)
{
	assert(!mapped && !reserved);
	memset(&cam_cc_crm_guard, 0, sizeof(cam_cc_crm_guard));
	memset(words, 0, sizeof(words));
	resource = (struct resource){0xadd7000, 0xadd8fff};
	missing = busy = fail_map = false;
	requests = releases = reads = maps = unmaps = 0;
	power_error = gate_error = 0; gate_reads = 0; gate_on = false;
	cam_cc_power.map = &controller_map;
}
int main(void)
{
	reset(); assert(cam_cc_crm_guard_admit() == -ENODEV && !reads);
	for (unsigned int invalid = 0; invalid < 4; invalid++) {
		reset();
		if (!invalid) missing = true;
		if (invalid == 1) resource.start += 4;
		if (invalid == 2) resource.end--;
		if (invalid == 3) resource.end++;
		assert(cam_cc_crm_guard_map(&device) == -EINVAL && !requests && !reads);
	}
	reset(); busy = true;
	assert(cam_cc_crm_guard_map(&device) == -EBUSY && requests == 1 && !maps && !releases);
	reset(); fail_map = true;
	assert(cam_cc_crm_guard_map(&device) == -ENOMEM && !reserved && maps == 1 && releases == 1);
	reset(); assert(!cam_cc_crm_guard_map(&device));
	assert(cam_cc_crm_guard_map(&device) == -EBUSY && requests == 1);
	cam_cc_power.map = NULL;
	assert(cam_cc_crm_guard_admit() == -ENODEV && !reads && !gate_reads);
	cam_cc_power.map = &controller_map;
	const int errors[] = {-EHOSTDOWN, -EIO, -EREMOTEIO};
	for (unsigned int i = 0; i < sizeof(errors) / sizeof(errors[0]); i++) {
		power_error = errors[i];
		assert(cam_cc_crm_guard_admit() == errors[i] && !reads && !cam_cc_crm_guard.checked);
		assert(!gate_reads);
	}
	power_error = 0;
	assert(cam_cc_crm_guard_admit() == -EHOSTDOWN && !reads && gate_reads == 1);
	gate_error = -EREMOTEIO;
	assert(cam_cc_crm_guard_admit() == -EREMOTEIO && !reads && gate_reads == 2);
	gate_error = 0; gate_on = true;
	const uint32_t modes[] = {0, 1, 2, 0x80000000, UINT32_MAX};
	for (unsigned int i = 0; i < sizeof(modes) / sizeof(modes[0]); i++) {
		words[3] = modes[i];
		assert(cam_cc_crm_guard_admit() == (modes[i] ? -EOPNOTSUPP : 0));
		assert(cam_cc_crm_guard.checked && cam_cc_crm_guard.firmware_enabled == !!modes[i]);
		assert(reads == i + 1 && words[3] == modes[i]);
	}
	cam_cc_crm_guard_put();
	assert(!mapped && !reserved && !cam_cc_crm_guard.base && !cam_cc_crm_guard.checked);
	cam_cc_crm_guard_put(); assert(unmaps == 1 && releases == 1);
	puts("Actual CRM guard: exact resource, exclusive mapping, power/bus-gate/error refusal before CRM reads, zero-only direct mode and idempotent clean release pass; no hardware result");
	return 0;
}
