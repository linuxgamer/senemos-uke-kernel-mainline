// SPDX-License-Identifier: GPL-2.0-only
/* Host models only OS/hardware boundaries; production functions are imported. */
#include <assert.h>
#include <errno.h>
#include <limits.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define BIT(n) (1U << (n))
#define GENMASK(h, l) ((~0U << (l)) & (~0U >> (31 - (h))))
#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))
#define DIV_ROUND_CLOSEST(a, b) (((a) + (b) / 2) / (b))
#define max(a, b) ((a) > (b) ? (a) : (b))
static bool model_warn(bool condition) { return condition; }
#define WARN(condition, ...) model_warn(!!(condition))
#define pr_debug(...) ((void)0)
#define pr_err(...) ((void)0)
#define dev_err(...) ((void)0)
#define dev_warn(...) ((void)0)
#define EXPORT_SYMBOL(name)
#define EXPORT_SYMBOL_GPL(name)
#define DEFINE_MUTEX(name) int name
#define __iomem
#define __maybe_unused
#undef static_assert
#define static_assert(expression) _Static_assert(expression, #expression)
#define EPROBE_DEFER 517
#define READ_ONCE(x) (x)
#define WRITE_ONCE(x, value) ((x) = (value))
#define IS_ERR(x) ((uintptr_t)(x) >= (uintptr_t)-4095)
#define PTR_ERR(x) ((int)(intptr_t)(x))
#define ERR_PTR(x) ((void *)(intptr_t)(x))
typedef uint32_t u32;
typedef uint8_t u8;
typedef uint64_t resource_size_t;
static void mutex_lock(int *lock) { (void)lock; }
static void mutex_unlock(int *lock) { (void)lock; }
static int atomic_read(int *value) { return *value; }

struct device;
struct device_node { bool dynamic, power_domains; };
struct dev_pm_ops {
	int (*runtime_suspend)(struct device *);
	int (*runtime_resume)(struct device *);
	int (*runtime_idle)(struct device *);
	int (*suspend)(struct device *);
	int (*resume)(struct device *);
};
#define RUNTIME_PM_OPS(s, r, i) .runtime_suspend = (s), .runtime_resume = (r), .runtime_idle = (i),
#define SYSTEM_SLEEP_PM_OPS(s, r) .suspend = (s), .resume = (r),
struct device {
	void *data;
	const struct dev_pm_ops *ops;
	const struct device_driver *driver;
	struct device_node *of_node;
	void *pm_domain;
	int references;
	struct { int usage_count, child_count; bool needs_force_resume, smart_suspend; } power;
	bool disabled, suspended;
};
#ifdef CLOCKS_TEST
struct clk_init_data;
struct clk_hw { const struct clk_init_data *init; unsigned long rate; bool prepared; };
#else
struct clk_hw { int unused; };
#endif
static const char *clk_hw_get_name(struct clk_hw *hw) { return "camera-model"; }
struct device_driver { void *owner; bool suppress_bind_attrs; const struct dev_pm_ops *pm; };
struct clk { int count, enables, disables, error, references, managed; };
struct regulator {
	int count, voltage, sets, enables, disables;
	int set_error, enable_error, disable_error;
	int references, managed;
	bool late_disable;
};
struct regmap_config {
	unsigned int reg_bits, reg_stride, val_bits, max_register;
	bool fast_io;
	int (*reg_read)(void *, unsigned int, unsigned int *);
	int (*reg_write)(void *, unsigned int, unsigned int);
};
struct gdsc { bool controller_pm_held; };
#include "rpmh-levels.h"
#include "vdd-level.h"
#include "vdd-class.h"
struct qcom_cc_desc {
	struct clk_vdd_class **clk_regulators;
	size_t num_clk_regulators;
	struct gdsc **gdscs;
	size_t num_gdscs;
};

static struct regulator regulators[3];
static struct clk iface;
static int get_rail_error = -1, missing_rail = -1, get_clock_error, validation_error;
static int ordinary_gets;
static int reads, writes, operations;
static u32 memory[0x20000 / sizeof(u32)];
static void *dev_get_drvdata(struct device *dev) { return dev->data; }
static void dev_set_drvdata(struct device *dev, void *data) { dev->data = data; }
static struct device *get_device(struct device *dev) { dev->references++; return dev; }
static void put_device(struct device *dev) { assert(dev->references > 0); dev->references--; }
static struct regulator *regulator_get_optional(struct device *dev, const char *name)
{
	const char *names[] = { "vdd_mm", "vdd_mx", "vdd_mxc" };
	for (int i = 0; i < 3; i++)
		if (!strcmp(name, names[i])) {
			if (missing_rail == i) return ERR_PTR(-ENODEV);
			if (get_rail_error == i) return ERR_PTR(-EPROBE_DEFER);
			regulators[i].references++;
			return &regulators[i];
		}
	assert(false);
	return ERR_PTR(-EINVAL);
}
static void regulator_put(struct regulator *regulator)
{
	assert(regulator->references > 0);
	regulator->references--;
}
static struct regulator *devm_regulator_get_optional(struct device *dev, const char *name)
{
	struct regulator *regulator = regulator_get_optional(dev, name);
	if (!IS_ERR(regulator)) regulator->managed++;
	return regulator;
}
static struct regulator *devm_regulator_get(struct device *dev, const char *name)
{
	static struct regulator dummy;
	struct regulator *regulator = devm_regulator_get_optional(dev, name);
	ordinary_gets++;
	return IS_ERR(regulator) && PTR_ERR(regulator) == -ENODEV ? &dummy : regulator;
}
static int regulator_set_voltage(struct regulator *r, int min_uv, int max_uv)
{
	operations++;
	r->sets++;
	if (r->set_error) return r->set_error;
	r->voltage = min_uv;
	return 0;
}
static int regulator_enable(struct regulator *r)
{
	operations++;
	r->enables++;
	if (r->enable_error) return r->enable_error;
	r->count++;
	return 0;
}
static int regulator_disable(struct regulator *r)
{
	operations++;
	r->disables++;
	assert(r->count > 0);
	if (r->disable_error && !r->late_disable) return r->disable_error;
	r->count--;
	return r->disable_error;
}
static struct clk *clk_get(struct device *dev, const char *name)
{
	assert(!strcmp(name, "iface"));
	if (get_clock_error) return ERR_PTR(get_clock_error);
	iface.references++;
	return &iface;
}
static void clk_put(struct clk *clk) { assert(clk->references > 0); clk->references--; }
static struct clk *devm_clk_get(struct device *dev, const char *name)
{
	struct clk *clk = clk_get(dev, name);
	if (!IS_ERR(clk)) clk->managed++;
	return clk;
}
static int clk_prepare_enable(struct clk *clk)
{
	operations++;
	clk->enables++;
	for (int i = 0; i < 3; i++) assert(regulators[i].count == 1);
	if (clk->error) return clk->error;
	clk->count++;
	return 0;
}
static void clk_disable_unprepare(struct clk *clk)
{
	operations++;
	clk->disables++;
	assert(clk->count == 1);
	clk->count--;
}
static u32 readl(void *address) { reads++; return *(u32 *)address; }
static void writel(u32 value, void *address) { writes++; *(u32 *)address = value; }
static int cam_cc_validate_voltage_data(void) { return validation_error; }
static int pm_runtime_force_suspend(struct device *dev);
static int pm_runtime_force_resume(struct device *dev);
#include "vdd-functions.c"
#include "camcc-rails.h"
#include "camcc-config.h"
static struct gdsc domains[8];
static struct gdsc *cam_cc_sm7675_gdscs[] = {
	&domains[0], &domains[1], &domains[2], &domains[3],
	&domains[4], &domains[5], &domains[6], &domains[7],
};
static const struct qcom_cc_desc cam_cc_sm7675_desc = {
	.clk_regulators = cam_cc_sm7675_regulators,
	.num_clk_regulators = ARRAY_SIZE(cam_cc_sm7675_regulators),
	.gdscs = cam_cc_sm7675_gdscs,
	.num_gdscs = ARRAY_SIZE(cam_cc_sm7675_gdscs),
};
#include "provider-power.h"

#ifndef OWNER_BASELINE
#define IORESOURCE_MEM 1
#define OF_DYNAMIC 0
struct resource { resource_size_t start, end; };
struct platform_device { struct device dev; struct resource resource; bool resource_present; };
struct regmap { int unused; };
static struct regmap model_map;
static bool machine_matches = true, region_busy, fail_mapping, fail_regmap;
static int regions, mappings, regmaps, region_releases;
static bool of_machine_is_compatible(const char *name)
{
	assert(!strcmp(name, "xiaomi,uke")); return machine_matches;
}
static bool of_node_check_flag(struct device_node *node, int flag) { return node->dynamic; }
static void *of_find_property(struct device_node *node, const char *name, void *length)
{
	assert(!strcmp(name, "power-domains")); return node->power_domains ? node : NULL;
}
static struct resource *platform_get_resource(struct platform_device *pdev, int type, int index)
{
	assert(type == IORESOURCE_MEM && index == 0);
	return pdev->resource_present ? &pdev->resource : NULL;
}
static resource_size_t resource_size(struct resource *res) { return res->end - res->start + 1; }
static const char *dev_name(struct device *dev) { return "camcc-model"; }
static struct resource *request_mem_region(resource_size_t start, resource_size_t size, const char *name)
{
	static struct resource result;
	if (region_busy || regions) return NULL;
	regions++;
	return &result;
}
static void release_mem_region(resource_size_t start, resource_size_t size)
{
	assert(regions == 1); regions--; region_releases++;
}
static void *ioremap(resource_size_t start, resource_size_t size)
{
	if (fail_mapping) return NULL;
	mappings++; return memory;
}
static void iounmap(void *base) { assert(base == memory && mappings == 1); mappings--; }
static struct regmap *regmap_init(struct device *dev, void *bus, void *context,
				 const struct regmap_config *config)
{
	assert(!bus && context == &cam_cc_power && config == &cam_cc_power_regmap_config);
	if (fail_regmap) return ERR_PTR(-ENOMEM);
	regmaps++; return &model_map;
}
static void regmap_exit(struct regmap *map) { assert(map == &model_map && regmaps == 1); regmaps--; }
#include "provider-owner.h"
#endif

/* Boundary from Linux dd.c/clk-devres.c/regulator/devres.c, not hardware. */
static void failed_probe_cleanup(struct device *dev)
{
	while (iface.managed) { iface.managed--; clk_put(&iface); }
	for (int i = 0; i < 3; i++)
		while (regulators[i].managed) { regulators[i].managed--; regulator_put(&regulators[i]); }
	dev->driver = NULL;
	dev->data = NULL;
	dev->disabled = true;
	dev->power.usage_count = dev->power.child_count = 0;
	put_device(dev);
}

static void assert_resources_retained(struct device *dev)
{
	assert(dev->references > 0 && iface.references == 1);
	for (int i = 0; i < 3; i++) assert(regulators[i].references == 1);
}

static void pm_runtime_disable(struct device *dev) { dev->disabled = true; }
static void pm_runtime_enable(struct device *dev) { dev->disabled = false; }
static bool pm_runtime_status_suspended(struct device *dev) { return dev->suspended; }
static bool pm_runtime_need_not_resume(struct device *dev)
{
	return dev->power.usage_count <= 1 && !dev->power.child_count;
}
static void pm_runtime_set_suspended(struct device *dev) { dev->suspended = true; }
static bool dev_pm_smart_suspend(struct device *dev) { return dev->power.smart_suspend; }
static void dev_pm_enable_wake_irq_check(struct device *dev, bool system) {}
static void dev_pm_disable_wake_irq_check(struct device *dev, bool system) {}
static void dev_pm_enable_wake_irq_complete(struct device *dev) {}
static void pm_runtime_mark_last_busy(struct device *dev) {}
#define GET_CALLBACK(dev, name) ((dev)->ops->name)
#include "force-pm.c"

static void reset(struct device *dev)
{
	/* A new isolated host test, never a production recovery/reset API. */
	memset(&cam_cc_power, 0, sizeof(cam_cc_power));
	memset(regulators, 0, sizeof(regulators));
	memset(domains, 0, sizeof(domains));
	memset(memory, 0, sizeof(memory));
	iface = (struct clk) { 0 };
	*dev = (struct device) { .ops = &cam_cc_power_pm_ops, .suspended = true, .references = 1 };
	get_rail_error = -1;
	missing_rail = -1;
	ordinary_gets = 0;
	get_clock_error = validation_error = reads = writes = operations = 0;
	for (int i = 0; i < 3; i++) {
		struct clk_vdd_class *rail = cam_cc_sm7675_regulators[i];
		memset(rail->level_votes, 0, rail->num_levels * sizeof(int));
		rail->regulator[0] = NULL;
		rail->cur_level = rail->num_levels;
	}
}

static void start(struct device *dev)
{
	reset(dev);
	assert(cam_cc_power_init(dev, memory, sizeof(memory)) == 0);
	assert(cam_cc_power_regmap_config.reg_read == cam_cc_power_read);
	assert(cam_cc_power_regmap_config.reg_write == cam_cc_power_write);
}

static void active(struct device *dev)
{
	assert(dev->ops->runtime_resume(dev) == 0);
	dev->suspended = false;
	assert(cam_cc_power.votes == 7 && cam_cc_power.iface_on && iface.count == 1);
}

static void blocked_access(int error)
{
	unsigned int value = 0xfeed;
	int before = reads + writes;
	assert(cam_cc_power_read(&cam_cc_power, 0, &value) == error);
	assert(value == 0xfeed);
	assert(cam_cc_power_write(&cam_cc_power, 0, 3) == error);
	assert(reads + writes == before);
}

static void cycles(void)
{
	struct device dev;
	start(&dev);
	blocked_access(-EHOSTDOWN);
	for (int cycle = 0; cycle < 3; cycle++) {
		active(&dev);
		int before = operations;
		assert(dev.ops->runtime_resume(&dev) == 0 && operations == before);
		unsigned int value;
		assert(cam_cc_power_write(&cam_cc_power, 0, cycle + 42) == 0);
		assert(cam_cc_power_read(&cam_cc_power, 0, &value) == 0 && value == (unsigned int)cycle + 42);
		unsigned int last = cam_cc_power_regmap_config.max_register;
		assert(cam_cc_power_write(&cam_cc_power, last, 91) == 0);
		assert(cam_cc_power_read(&cam_cc_power, last, &value) == 0 && value == 91);
		assert(cam_cc_power_write(&cam_cc_power, last + 4, 7) == -EINVAL);
		assert(dev.ops->runtime_suspend(&dev) == 0);
		assert(!cam_cc_power.votes && !cam_cc_power.iface_on && !iface.count);
		for (int i = 0; i < 3; i++) {
			assert(regulators[i].count == 0);
			assert(cam_cc_sm7675_regulators[i]->level_votes[VDD_MIN] == 0);
		}
		before = operations;
		assert(dev.ops->runtime_suspend(&dev) == 0 && operations == before);
		blocked_access(-EHOSTDOWN);
	}
	assert(iface.enables == 3 && iface.disables == 3);
	puts("CAMCC provider: cycles, ordering, duplicate callbacks and MMIO gates pass");
}

static void voltage_errors(void)
{
	struct device dev;
	for (int rail = 0; rail < 3; rail++) {
		for (int stage = 0; stage < 2; stage++) {
			start(&dev);
			if (!stage) regulators[rail].set_error = -EAGAIN;
			else regulators[rail].enable_error = -EBUSY;
			assert(dev.ops->runtime_resume(&dev) == -EIO);
			assert(cam_cc_power.primary_error == (stage ? -EBUSY : -EAGAIN));
			assert(cam_cc_power.uncertain_rails == BIT(rail));
			assert(cam_cc_power.votes == BIT(rail) - 1 && !iface.count);
			assert(cam_cc_sm7675_regulators[rail]->level_votes[VDD_MIN] == 0);
			int before = operations;
			assert(dev.ops->runtime_resume(&dev) == -EIO);
			assert(dev.ops->runtime_suspend(&dev) == -EIO && operations == before);
			blocked_access(-EIO);
		}
	}
	puts("CAMCC provider: every voltage/enable failure latches uncertainty without retry");
}

static void clock_rollback(void)
{
	struct device dev;
	start(&dev);
	iface.error = -EAGAIN;
	assert(dev.ops->runtime_resume(&dev) == -EAGAIN);
	assert(!cam_cc_power.fault && !cam_cc_power.votes && !iface.count);
	for (int i = 0; i < 3; i++) assert(!regulators[i].count);
	iface.error = 0;
	active(&dev);
	assert(dev.ops->runtime_suspend(&dev) == 0);
	for (int rail = 0; rail < 3; rail++) {
		start(&dev);
		iface.error = -EAGAIN;
		regulators[rail].disable_error = -EREMOTEIO;
		assert(dev.ops->runtime_resume(&dev) == -EIO);
		assert(cam_cc_power.primary_error == -EAGAIN && cam_cc_power.rollback_error == -EREMOTEIO);
		assert(cam_cc_power.uncertain_rails == BIT(rail));
		assert(cam_cc_power.votes == BIT(rail + 1) - 1);
		int before = operations;
		assert(dev.ops->runtime_resume(&dev) == -EIO && operations == before);
		blocked_access(-EIO);
	}
	puts("CAMCC provider: clean clock rollback retries; failed rollback preserves both errors");
}

static void disable_errors(void)
{
	struct device dev;
	for (int rail = 0; rail < 3; rail++) {
		for (int late = 0; late < 2; late++) {
			start(&dev);
			active(&dev);
			regulators[rail].disable_error = -EBUSY;
			regulators[rail].late_disable = late;
			assert(dev.ops->runtime_suspend(&dev) == -EIO);
			assert(cam_cc_power.primary_error == -EBUSY && !cam_cc_power.iface_on);
			assert(cam_cc_power.votes == BIT(rail + 1) - 1);
			assert(cam_cc_sm7675_regulators[rail]->level_votes[VDD_MIN] == 1);
			assert(regulators[rail].count == (late ? 0 : 1));
			int before = operations;
			assert(dev.ops->runtime_suspend(&dev) == -EIO);
			assert(dev.ops->runtime_resume(&dev) == -EIO && operations == before);
			blocked_access(-EIO);
		}
	}
	puts("CAMCC provider: early/late disable errors never assume the backend counter is unchanged");
}

static void forced_suspend(void)
{
	struct device dev;
	for (int guard = 0; guard < 10; guard++) {
		start(&dev);
		active(&dev);
		if (guard == 0) dev.power.usage_count = 1;
		else if (guard == 1) dev.power.child_count = 1;
		else domains[guard - 2].controller_pm_held = true;
		int before = operations;
		assert(dev.ops->suspend(&dev) == -EBUSY);
		assert(!dev.disabled && !dev.suspended && operations == before);
		assert(cam_cc_power.votes == 7 && cam_cc_power.iface_on);
	}
	start(&dev);
	active(&dev);
	assert(dev.ops->suspend(&dev) == 0);
	assert(dev.disabled && dev.suspended && !iface.count && !cam_cc_power.votes);
	blocked_access(-EHOSTDOWN);
	assert(dev.ops->resume(&dev) == 0 && !dev.disabled);
	active(&dev);
	regulators[1].disable_error = -EAGAIN;
	assert(dev.ops->suspend(&dev) == -EIO);
	assert(!dev.disabled && !dev.suspended);
	/* force_suspend calls the driver directly: MMIO must guard the local fault. */
	blocked_access(-EIO);
	int before = operations;
	assert(dev.ops->runtime_resume(&dev) == -EIO && operations == before);
	puts("CAMCC provider: actual forced-PM functions honor usage/children/eight GDSC guards and fatal MMIO gate");
}

static void initialization(void)
{
	struct device dev;
	assert(cam_cc_sm7675_desc.num_clk_regulators == 3 && cam_cc_sm7675_desc.num_gdscs == 8);
	reset(&dev);
	assert(cam_cc_power_init(&dev, NULL, sizeof(memory)) == -EINVAL);
	assert(cam_cc_power_init(&dev, ERR_PTR(-ENOMEM), sizeof(memory)) == -ENOMEM);
	assert(cam_cc_power_init(&dev, memory, 4) == -EINVAL);
	unsigned int required = cam_cc_sm7675_regmap_config.max_register + sizeof(u32);
	assert(cam_cc_power_init(&dev, memory, required - 1) == -EINVAL);
	validation_error = -ERANGE;
	assert(cam_cc_power_init(&dev, memory, sizeof(memory)) == -ERANGE);
	assert(!dev.data && !operations);
	validation_error = 0;
	get_clock_error = -EPROBE_DEFER;
	assert(cam_cc_power_init(&dev, memory, sizeof(memory)) == -EPROBE_DEFER);
	get_clock_error = 0;
	for (int i = 0; i < 3; i++) {
		get_rail_error = i;
		assert(cam_cc_power_init(&dev, memory, sizeof(memory)) == -EPROBE_DEFER);
		assert(!dev.data && !cam_cc_power.dev && !operations);
		for (int j = 0; j < 3; j++) assert(!cam_cc_sm7675_regulators[j]->regulator[0]);
	}
	get_rail_error = -1;
	for (int i = 0; i < 3; i++) {
		missing_rail = i;
		assert(cam_cc_power_init(&dev, memory, sizeof(memory)) == -ENODEV);
		assert(!dev.data && !operations && !ordinary_gets);
		for (int j = 0; j < 3; j++) assert(!cam_cc_sm7675_regulators[j]->regulator[0]);
	}
	missing_rail = -1;
	assert(cam_cc_power_init(&dev, memory, required) == 0);
	assert(cam_cc_power_init(&dev, memory, sizeof(memory)) == -EBUSY);
	unsigned int value;
	assert(cam_cc_power_read(&cam_cc_power, 1, &value) == -EINVAL);
	assert(cam_cc_power_read(&cam_cc_power, sizeof(memory), &value) == -EINVAL);
	assert(cam_cc_power_read(NULL, 0, &value) == -EINVAL);
	assert(cam_cc_power_read(&cam_cc_power, 0, NULL) == -EINVAL);
	assert(cam_cc_power_write(NULL, 0, 1) == -EINVAL);
	assert(!reads && !writes && !operations);
	puts("CAMCC provider: initialization, deferred suppliers, duplicate owner and MMIO bounds pass");
}

static void independent_votes(void)
{
	struct device dev;
	start(&dev);
	struct clk_vdd_class_data other = { .vdd_class = &cam_cc_mm };
	assert(clk_vote_vdd_level(&other, VDD_NOMINAL) == 0);
	active(&dev);
	assert(dev.ops->runtime_suspend(&dev) == 0);
	assert(!cam_cc_power.votes && regulators[0].count == 1);
	assert(cam_cc_mm.level_votes[VDD_NOMINAL] == 1 && cam_cc_mm.level_votes[VDD_MIN] == 0);
	assert(regulators[0].voltage == RPMH_REGULATOR_LEVEL_NOM);
	assert(clk_unvote_vdd_level(&other, VDD_NOMINAL) == 0);
	assert(!regulators[0].count);
	start(&dev);
	cam_cc_power.votes = 1;
	assert(dev.ops->runtime_resume(&dev) == -EIO && cam_cc_power.primary_error == -EUCLEAN);
	assert(!operations);
	start(&dev);
	active(&dev);
	cam_cc_power.iface_on = false;
	int before = operations;
	assert(dev.ops->runtime_suspend(&dev) == -EIO && operations == before);
	dev.data = NULL;
	assert(dev.ops->runtime_suspend(&dev) == -ENODEV);
	assert(dev.ops->runtime_resume(&dev) == -ENODEV && operations == before);
	puts("CAMCC provider: independent voltage votes survive; corrupt/foreign ownership is refused");
}

#ifndef OWNER_BASELINE
static const struct device_driver permanent_driver = {
	.suppress_bind_attrs = true, .pm = &cam_cc_power_pm_ops,
};

static void owner_reset(struct platform_device *pdev, struct device_node *node)
{
	/* Each fixture is a new model machine; this is not a recovery API. */
	memset(pdev, 0, sizeof(*pdev));
	reset(&pdev->dev);
	*node = (struct device_node) { 0 };
	pdev->dev.of_node = node;
	pdev->dev.driver = &permanent_driver;
	pdev->resource = (struct resource) { .start = 0xade0000, .end = 0xadfffff };
	pdev->resource_present = machine_matches = true;
	region_busy = fail_mapping = fail_regmap = false;
	regions = mappings = regmaps = region_releases = 0;
}

static void owner_empty(struct platform_device *pdev)
{
	assert(!cam_cc_power.dev && !pdev->dev.data && pdev->dev.references == 1);
	assert(!iface.references && !regions && !mappings && !regmaps);
	for (int i = 0; i < 3; i++) {
		assert(!regulators[i].references);
		assert(!cam_cc_sm7675_regulators[i]->regulator[0]);
	}
}

static void owner_pinned_after_cleanup(struct platform_device *pdev)
{
	assert(cam_cc_power.fault && cam_cc_power.dev == &pdev->dev);
	assert(cam_cc_power.region_owned && regions == 1 && mappings == 1 && regmaps == 1);
	failed_probe_cleanup(&pdev->dev);
	assert_resources_retained(&pdev->dev);
	assert(!iface.managed && !region_releases);
	for (int i = 0; i < 3; i++) assert(!regulators[i].managed);
	blocked_access(-EIO);
	int before = operations;
	assert(cam_cc_power_resume(&pdev->dev) == -ENODEV && operations == before);
	pdev->dev.driver = &permanent_driver;
	assert(PTR_ERR(cam_cc_owner_create(pdev)) == -EBUSY);
}

static void owner_lifetime(void)
{
	struct platform_device pdev;
	struct device_node node;

	for (int invalid = 0; invalid < 9; invalid++) {
		struct device_driver driver = permanent_driver;
		owner_reset(&pdev, &node);
		pdev.dev.driver = &driver;
		if (invalid == 0) machine_matches = false;
		if (invalid == 1) pdev.dev.of_node = NULL;
		if (invalid == 2) node.dynamic = true;
		if (invalid == 3) driver.owner = &driver;
		if (invalid == 4) driver.suppress_bind_attrs = false;
		if (invalid == 5) driver.pm = NULL;
		if (invalid == 6) pdev.dev.driver = NULL;
		if (invalid == 7) pdev.dev.pm_domain = &pdev;
		if (invalid == 8) node.power_domains = true;
		assert(PTR_ERR(cam_cc_owner_create(&pdev)) == -EINVAL);
		owner_empty(&pdev);
		assert(!operations && !reads && !writes);
	}
	for (int invalid = 0; invalid < 4; invalid++) {
		owner_reset(&pdev, &node);
		if (invalid == 0) pdev.resource_present = false;
		if (invalid == 1) pdev.resource.start++;
		if (invalid == 2) pdev.resource.end = pdev.resource.start + 3;
		if (invalid == 3) pdev.resource.end += 4;
		assert(PTR_ERR(cam_cc_owner_create(&pdev)) == -EINVAL);
		owner_empty(&pdev);
	}
	for (int failure = 0; failure < 10; failure++) {
		owner_reset(&pdev, &node);
		int expected = -ENOMEM;
		if (failure == 0) { region_busy = true; expected = -EBUSY; }
		if (failure == 1) fail_mapping = true;
		if (failure == 2) { get_clock_error = -EPROBE_DEFER; expected = -EPROBE_DEFER; }
		if (failure >= 3 && failure <= 5) { get_rail_error = failure - 3; expected = -EPROBE_DEFER; }
		if (failure >= 6 && failure <= 8) { missing_rail = failure - 6; expected = -ENODEV; }
		if (failure == 9) fail_regmap = true;
		assert(PTR_ERR(cam_cc_owner_create(&pdev)) == expected);
		owner_empty(&pdev);
		assert(!operations && !reads && !writes);
	}
	owner_reset(&pdev, &node);
	regions = 1; /* An existing foreign reservation is not ours to release. */
	assert(PTR_ERR(cam_cc_owner_create(&pdev)) == -EBUSY);
	assert(regions == 1 && !region_releases);

	owner_reset(&pdev, &node);
	assert(cam_cc_owner_create(&pdev) == &model_map);
	assert(PTR_ERR(cam_cc_owner_create(&pdev)) == -EBUSY);
	assert(cam_cc_owner_begin_publication() == -EHOSTDOWN);
	assert(!reads && !writes && !operations);
	assert(cam_cc_owner_probe_failed(0) == -EINVAL);
	assert(cam_cc_owner_probe_failed(-EPROBE_DEFER) == -EPROBE_DEFER);
	owner_empty(&pdev);
	assert(cam_cc_owner_probe_failed(-EIO) == -EIO);
	assert(cam_cc_owner_create(&pdev) == &model_map); /* clean defer can retry */
	assert(cam_cc_owner_probe_failed(-EIO) == -EIO);
	owner_empty(&pdev);

	for (int held = 0; held < 10; held++) {
		owner_reset(&pdev, &node);
		assert(cam_cc_owner_create(&pdev) == &model_map);
		if (held == 0) pdev.dev.power.usage_count = 1;
		else if (held == 1) pdev.dev.power.child_count = 1;
		else domains[held - 2].controller_pm_held = true;
		assert(cam_cc_owner_probe_failed(-ENOMEM) == -ENOMEM);
		owner_pinned_after_cleanup(&pdev);
	}
	owner_reset(&pdev, &node);
	assert(cam_cc_owner_create(&pdev) == &model_map);
	active(&pdev.dev);
	assert(cam_cc_owner_probe_failed(-ENOMEM) == -ENOMEM);
	assert(cam_cc_power.primary_error == -ENOMEM);
	owner_pinned_after_cleanup(&pdev);
	assert(cam_cc_owner_probe_failed(-EAGAIN) == -EAGAIN);
	assert(cam_cc_power.primary_error == -ENOMEM);

	for (int rail = 0; rail < 3; rail++) {
		owner_reset(&pdev, &node);
		assert(cam_cc_owner_create(&pdev) == &model_map);
		regulators[rail].set_error = -EREMOTEIO;
		assert(cam_cc_power_resume(&pdev.dev) == -EIO);
		assert(cam_cc_owner_probe_failed(-EPROBE_DEFER) == -EPROBE_DEFER);
		assert(cam_cc_power.primary_error == -EREMOTEIO);
		owner_pinned_after_cleanup(&pdev);
	}
	owner_reset(&pdev, &node);
	assert(cam_cc_owner_create(&pdev) == &model_map);
	iface.error = -EAGAIN;
	assert(cam_cc_power_resume(&pdev.dev) == -EAGAIN);
	assert(cam_cc_owner_probe_failed(-EAGAIN) == -EAGAIN);
	owner_empty(&pdev);

	owner_reset(&pdev, &node);
	assert(cam_cc_owner_create(&pdev) == &model_map);
	active(&pdev.dev);
	assert(cam_cc_owner_begin_publication() == 0);
	assert(cam_cc_owner_begin_publication() == -EALREADY);
	assert(cam_cc_power_suspend(&pdev.dev) == 0);
	assert(cam_cc_owner_probe_failed(-ENOMEM) == -ENOMEM);
	owner_pinned_after_cleanup(&pdev);

	owner_reset(&pdev, &node);
	assert(cam_cc_owner_create(&pdev) == &model_map);
	struct clk_vdd_class_data other = { .vdd_class = &cam_cc_mm };
	assert(clk_vote_vdd_level(&other, VDD_NOMINAL) == 0);
	assert(cam_cc_owner_probe_failed(-EIO) == -EIO);
	assert(cam_cc_mm.level_votes[VDD_NOMINAL] == 1);
	owner_pinned_after_cleanup(&pdev);

	owner_reset(&pdev, &node);
	assert(cam_cc_owner_create(&pdev) == &model_map);
	struct regulator foreign = { 0 };
	cam_cc_mm.regulator[0] = &foreign;
	assert(cam_cc_owner_probe_failed(-EIO) == -EIO && !foreign.references);
	owner_pinned_after_cleanup(&pdev);

	for (int powered = 0; powered < 2; powered++) {
		owner_reset(&pdev, &node);
		assert(cam_cc_owner_create(&pdev) == &model_map);
		if (powered) active(&pdev.dev);
		cam_cc_owner_detach(&pdev.dev);
		assert(cam_cc_power.primary_error == -ESHUTDOWN);
		owner_pinned_after_cleanup(&pdev);
	}
	puts("CAMCC owner: exact static built-in contract, all acquisition failures, clean defer, powered/uncertain/published/boot-held failure and shutdown retain complete resources through core cleanup");
}
#endif

int main(void)
{
#ifdef OWNER_BASELINE
	struct device dev;
	start(&dev);
	active(&dev);
	failed_probe_cleanup(&dev);
	assert_resources_retained(&dev);
#else
	initialization();
	cycles();
	voltage_errors();
	clock_rollback();
	disable_errors();
	forced_suspend();
	independent_votes();
	owner_lifetime();
#endif
	return 0;
}
