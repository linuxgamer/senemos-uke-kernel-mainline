// SPDX-License-Identifier: GPL-2.0-only
/* Actual handoff/registration functions; kernel framework and MMIO boundaries modeled. */
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

typedef uint32_t u32;
#define BIT(n) (1U << (n))
#define GENMASK(h, l) ((~0U << (l)) & (~0U >> (31 - (h))))
#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))
#define READ_ONCE(x) (x)
#define WRITE_ONCE(x, v) ((x) = (v))
#define EPROBE_DEFER 517
#define ERR_PTR(x) ((void *)(intptr_t)(x))
#define PTR_ERR(x) ((int)(intptr_t)(x))
#define IS_ERR(x) ((uintptr_t)(x) >= (uintptr_t)-4095)
#define CLK_HOLD_STATE BIT(14)
#define BRANCH_HALT 0
#define BRANCH_HALT_DELAY 1
#define BRANCH_VOTED BIT(2)
#define BRANCH_HALT_VOTED BRANCH_VOTED
#define GENPD_FLAG_NO_STAY_ON BIT(10)
#define genpd_is_no_stay_on(g) ((g)->flags & GENPD_FLAG_NO_STAY_ON)
#define dev_err(...) ((void)0)
#define dev_info(...) ((void)0)
struct device;
struct device_node { bool protected; };
struct device_driver { void (*sync_state)(struct device *); };
struct device { struct device_driver *driver; struct device_node *of_node; int usage; bool enabled, active; };
struct platform_device { struct device dev; };
struct regmap { u32 words[1024]; };
struct clk_init_data { unsigned long flags; };
struct clk_hw { const struct clk_init_data *init; unsigned int number; };
struct clk_ops { int (*init)(struct clk_hw *); void (*disable)(struct clk_hw *); };
struct clk_regmap {
	struct clk_hw hw;
	struct regmap *regmap;
	unsigned int enable_reg, enable_mask;
	bool enable_is_inverted;
};
enum { PLL_OFF_USER_CTL, PLL_OFF_OPMODE, PLL_OFF_L_VAL };
struct alpha_pll_config { u32 l; };
struct clk_alpha_pll {
	struct clk_regmap clkr;
	unsigned int offset;
	const unsigned int *regs;
	const struct alpha_pll_config *config;
};
struct clk_rcg2 { struct clk_regmap clkr; unsigned int cmd_rcgr, safe_src_index; u32 parked_cfg; };
struct clk_branch { struct clk_regmap clkr; unsigned int halt_reg, halt_check, hwcg_reg; };
#define to_clk_alpha_pll(hw) ((struct clk_alpha_pll *)(hw))
#define to_clk_regmap(hw) ((struct clk_regmap *)(hw))
#define container_of(p, type, member) ((type *)((char *)(p) - offsetof(type, member)))
#define to_clk_rcg2(hw) ((struct clk_rcg2 *)(hw))
#define to_clk_branch(hw) ((struct clk_branch *)(hw))
struct clk { int references, enabled; unsigned long rate; struct clk_hw *hw; };
struct clk_vdd_class { int num_levels; int votes[4]; };
struct clk_vdd_class_data { struct clk_vdd_class *vdd_class; };
struct generic_pm_domain { bool stay_on; unsigned int flags; };
struct gdsc { struct generic_pm_domain pd; bool controller_pm_held; };
struct of_phandle_args { unsigned int args_count, args[1]; };
struct genpd_onecell_data {
	struct generic_pm_domain **domains; unsigned int num_domains;
	struct generic_pm_domain *(*xlate)(const struct of_phandle_args *, void *);
};
struct gdsc_desc { struct device *dev; struct gdsc **scs; size_t num; struct genpd_onecell_data *permanent_data; };
struct reset_controller_dev;
struct reset_control_ops {
	int (*assert)(struct reset_controller_dev *, unsigned long);
	int (*deassert)(struct reset_controller_dev *, unsigned long);
	int (*reset)(struct reset_controller_dev *, unsigned long);
};
struct reset_controller_dev { struct device *dev; struct device_node *of_node; const struct reset_control_ops *ops; unsigned int nr_resets; };
struct qcom_reset_map { unsigned int reg, bit, bitmask, udelay; };
struct qcom_reset_controller { struct reset_controller_dev rcdev; struct regmap *regmap; const struct qcom_reset_map *reset_map; };

static int steps, fail_at, resources, registered_clocks, reset_published, domain_published, clock_published;
static int configured_plls, sync_error, sync_calls, genpd_syncs;
static bool model_domains_on, first_resume, boot_drop_fault, domain_sync_fault;
static bool crm_mapping, crm_active, busy_at_suspend;
static int sequence[1024], sequence_size;
enum { EVENT_CLOCK_SYNC = 1001, EVENT_RCG_DROP, EVENT_DOMAIN_SYNC, EVENT_PROXY_DROP, EVENT_PM_DROP };
static struct regmap model_map;
static struct clk parent_clks[3], boot_clk;
static struct device_node model_node;
static struct device_driver model_driver;
static struct platform_device model_device;
static struct clk_vdd_class classes[3];
static struct clk_vdd_class *cam_cc_sm7675_regulators[] = { &classes[0], &classes[1], &classes[2] };
static const unsigned int pll_regs[] = { 8, 4, 12 };
static const struct alpha_pll_config pll_config[] = { {62}, {50} };
static struct clk_alpha_pll plls[2];
static struct clk_regmap postdiv;
static struct clk_rcg2 rcg;
static struct clk_branch branch;
static struct clk_alpha_pll *cam_cc_sm7675_plls[] = { &plls[0], &plls[1] };
static struct clk_regmap *cam_cc_sm7675_clocks[] = { &branch.clkr, &rcg.clkr, &postdiv, &plls[0].clkr, &plls[1].clkr };
static struct gdsc domains[2];
static struct gdsc *cam_cc_sm7675_gdscs[] = { &domains[0], &domains[1] };
static const struct qcom_reset_map cam_cc_sm7675_resets[] = { {.reg = 0x600}, {.reg = 0x604} };
static const unsigned int cam_cc_sm7675_critical_cbcrs[] = {0x700, 0x704, 0x708, 0x70c};
static const struct { size_t num_clks, num_gdscs; } cam_cc_sm7675_desc = {5, 2};
static struct { struct device *dev; struct regmap *map; int fault, primary_error; bool publication_started; } cam_cc_power;

static void native_disable(struct clk_hw *hw) { (void)hw; }
static const struct clk_ops clk_alpha_pll_lucid_evo_ops = { .disable = native_disable };
static const struct clk_ops clk_alpha_pll_rivian_evo_ops = { .disable = native_disable };
static const struct clk_ops clk_alpha_pll_postdiv_lucid_ole_ops;
static const struct clk_ops clk_rcg2_shared_ops = { .disable = native_disable };
static const struct clk_ops clk_branch2_ops = { .disable = native_disable };
#include "clock-state.h"
static struct cam_cc_clock cam_cc_clock_state[5];

static int step(void) { return ++steps == fail_at ? -EREMOTEIO : 0; }
static void event(int value) { assert(sequence_size < 1024); sequence[sequence_size++] = value; }
static int cam_cc_power_fail(int error, int rollback, unsigned int uncertain)
{
	(void)rollback; (void)uncertain;
	cam_cc_power.fault = -EIO; cam_cc_power.primary_error = error;
	return -EIO;
}
static int cam_cc_power_access(void *context, unsigned int reg)
{
	assert(context == &cam_cc_power && reg == 0);
	if (cam_cc_power.fault) return cam_cc_power.fault;
	return model_device.dev.active ? 0 : -EHOSTDOWN;
}
static int regmap_read(struct regmap *map, unsigned int reg, u32 *value)
{
	assert(map == &model_map && reg % 4 == 0 && reg < sizeof(map->words));
	int ret = step(); if (ret) return ret;
	*value = map->words[reg / 4]; return 0;
}
static int regmap_update_bits(struct regmap *map, unsigned int reg, u32 mask, u32 value)
{
	assert(map == &model_map && reg % 4 == 0 && reg < sizeof(map->words));
	int ret = step(); if (ret) return ret;
	map->words[reg / 4] = (map->words[reg / 4] & ~mask) | (value & mask); return 0;
}
#define regmap_read_poll_timeout_atomic(map, reg, value, condition, delay, timeout) \
({ int r = 0, count = 0; do { r = regmap_read(map, reg, &value); \
 if (r || (condition)) break; } while (++count < 4); r ?: (condition) ? 0 : -ETIMEDOUT; })
static struct clk *clk_get(struct device *dev, const char *name)
{
	assert(dev == &model_device.dev);
	int ret = step(); if (ret) return ERR_PTR(ret);
	int i = !strcmp(name, "bi_tcxo") ? 0 : !strcmp(name, "bi_tcxo_ao") ? 1 : 2;
	parent_clks[i].references++; return &parent_clks[i];
}
static unsigned long clk_get_rate(struct clk *clk) { return clk->rate; }
static void clk_put(struct clk *clk) { assert(clk->references > 0); clk->references--; }
static int clk_vote_vdd_level(struct clk_vdd_class_data *vote, int level)
{
	assert(level == vote->vdd_class->num_levels - 1);
	vote->vdd_class->votes[level]++; return step();
}
static int clk_unvote_vdd_level(struct clk_vdd_class_data *vote, int level)
{
	event(EVENT_PROXY_DROP);
	int ret = step(); if (ret) return ret;
	assert(vote->vdd_class->votes[level] > 0); vote->vdd_class->votes[level]--; return 0;
}
static void qcom_clk_alpha_pll_configure(struct clk_alpha_pll *pll, struct regmap *map)
{
	assert(map == &model_map);
	int ret = step(); if (ret) { cam_cc_power_fail(ret, 0, 0); return; }
	configured_plls++; map->words[(pll->offset + pll->regs[PLL_OFF_L_VAL]) / 4] = pll->config->l;
}
static int pm_runtime_set_suspended(struct device *dev)
{
	assert(!dev->active); int ret = step(); if (ret) return ret;
	if (busy_at_suspend) { dev->usage++; return -EBUSY; }
	return 0;
}
static void pm_runtime_enable(struct device *dev) { dev->enabled = true; }
static int pm_runtime_resume_and_get(struct device *dev)
{
	int ret = step(); if (ret) return ret;
	if (!first_resume) {
		for (int i = 0; i < 3; i++) assert(classes[i].votes[classes[i].num_levels - 1] > 0);
		first_resume = true;
	}
	assert(dev->enabled); dev->usage++; dev->active = true; return 0;
}
static void pm_runtime_put(struct device *dev)
{
	event(EVENT_PM_DROP); assert(dev->usage > 0); if (!--dev->usage) dev->active = false;
}
static struct regmap *cam_cc_owner_create(struct platform_device *pdev)
{
	int ret = step(); if (ret) return ERR_PTR(ret);
	assert(!resources); resources = 1; cam_cc_power.dev = &pdev->dev;
	return cam_cc_power.map = &model_map;
}
static int cam_cc_owner_probe_failed(int error)
{
	assert(!cam_cc_power.publication_started && !model_device.dev.usage);
	assert(!crm_mapping);
	resources = 0; cam_cc_power.dev = NULL; cam_cc_power.map = NULL; return error;
}
static bool cam_cc_owner_busy(void)
{
	return model_device.dev.usage || model_device.dev.active ||
		cam_cc_power.fault || cam_cc_power.publication_started;
}
static int cam_cc_crm_guard_map(struct platform_device *pdev)
{
	assert(pdev == &model_device && resources && !crm_mapping);
	int ret = step(); if (ret) return ret;
	crm_mapping = true; return 0;
}
static int cam_cc_crm_guard_admit(void)
{
	assert(crm_mapping && model_device.dev.active && model_device.dev.usage > 0);
	assert(!configured_plls && !registered_clocks && !reset_published);
	for (unsigned int i = 0; i < ARRAY_SIZE(cam_cc_sm7675_critical_cbcrs); i++)
		assert(model_map.words[cam_cc_sm7675_critical_cbcrs[i] / 4] & BIT(0));
	int ret = step(); if (ret) return ret;
	return crm_active ? -EOPNOTSUPP : 0;
}
static void cam_cc_crm_guard_put(void)
{
	assert(!model_device.dev.active && !cam_cc_power.publication_started);
	crm_mapping = false;
}
static int cam_cc_owner_begin_publication(void)
{
	int ret = step(); if (ret) return ret;
	cam_cc_power.publication_started = true; return 0;
}
static const void *of_find_property(struct device_node *node, const char *name, void *length)
{
	(void)name; (void)length; return node->protected ? node : NULL;
}
static int cam_cc_clocks_init(void)
{
	const struct clk_ops *ops[] = { &clk_branch2_ops, &clk_rcg2_shared_ops,
		&clk_alpha_pll_postdiv_lucid_ole_ops, &clk_alpha_pll_lucid_evo_ops, &clk_alpha_pll_rivian_evo_ops };
	int ret = step(); if (ret) return ret;
	for (int i = 0; i < 5; i++) {
		cam_cc_clock_state[i].clock = cam_cc_sm7675_clocks[i];
		cam_cc_clock_state[i].native = ops[i];
		cam_cc_clock_state[i].ops = *ops[i];
		cam_cc_sm7675_clocks[i]->hw.init = &cam_cc_clock_state[i].init;
		cam_cc_sm7675_clocks[i]->hw.number = i;
	}
	return 0;
}
static int clk_hw_register(struct device *dev, struct clk_hw *hw)
{
	assert(dev->usage > 0 && cam_cc_power.publication_started);
	int ret = step(); if (ret) return ret;
	event((int)hw->number);
	registered_clocks++;
	return cam_cc_clock_state[hw->number].ops.init ? cam_cc_clock_state[hw->number].ops.init(hw) : 0;
}
static struct clk *clk_hw_get_clk(struct clk_hw *hw, const char *name)
{
	assert(hw == &rcg.clkr.hw && !strcmp(name, "boot"));
	int ret = step(); if (ret) return ERR_PTR(ret);
	boot_clk.references++; boot_clk.hw = hw; return &boot_clk;
}
static int clk_prepare_enable(struct clk *clk)
{
	int ret = step(); if (ret) return ret;
	assert(clk == &boot_clk); clk->enabled++; return 0;
}
static void clk_disable_unprepare(struct clk *clk)
{
	event(EVENT_RCG_DROP); assert(clk == &boot_clk && clk->enabled > 0); clk->enabled--;
	if (boot_drop_fault) cam_cc_power_fail(-ETIMEDOUT, 0, 0);
}
static int reset_controller_register(struct reset_controller_dev *reset)
{
	assert(reset->dev->usage > 0); int ret = step(); if (ret) return ret;
	reset_published = 1; return 0;
}
static void fsleep(unsigned int us) { assert(us > 0); }
static void generic_genpd_sync(struct device *dev) { (void)dev; }
#include "device-sync-function.c"
#include "genpd-stay-function.c"
static int gdsc_register(struct gdsc_desc *desc, struct reset_controller_dev *reset, struct regmap *map)
{
	(void)reset; assert(map == &model_map);
	int ret = step(); if (ret) return ret;
	assert(dev_set_drv_sync_state(desc->dev, generic_genpd_sync) == -EBUSY);
	for (size_t i = 0; i < desc->num; i++) {
		desc->permanent_data->domains[i] = &desc->scs[i]->pd;
		genpd_set_stay_on(&desc->scs[i]->pd, !model_domains_on);
		desc->scs[i]->controller_pm_held = model_domains_on;
		if (model_domains_on) desc->dev->usage++;
	}
	domain_published = 1; return 0;
}
static int of_clk_add_hw_provider(struct device_node *node,
		struct clk_hw *(*get)(struct of_phandle_args *, void *), void *data)
{
	(void)node; (void)get; (void)data; int ret = step(); if (ret) return ret;
	clock_published = 1; return 0;
}
static int clk_sync_state(struct device *dev)
{
	assert(dev->usage > 0); event(EVENT_CLOCK_SYNC); sync_calls++; return sync_error;
}
static void of_genpd_sync_state(struct device_node *node)
{
	assert(node == &model_node && model_device.dev.usage > 0);
	event(EVENT_DOMAIN_SYNC); genpd_syncs++;
	if (domain_sync_fault) { cam_cc_power_fail(-ETIMEDOUT, 0, 0); return; }
	for (int i = 0; i < 2; i++) {
		assert(domains[i].pd.stay_on == model_domains_on); domains[i].pd.stay_on = false;
		if (domains[i].controller_pm_held) {
			domains[i].controller_pm_held = false; model_device.dev.usage--;
		}
	}
}
#include "native-handoff.h"
#include "native-registration.h"

static void defaults(bool boot_on)
{
	memset(&cam_cc_native, 0, sizeof(cam_cc_native));
	memset(&cam_cc_power, 0, sizeof(cam_cc_power));
	memset(&model_map, 0, sizeof(model_map));
	memset(&model_device, 0, sizeof(model_device));
	memset(&model_node, 0, sizeof(model_node));
	memset(cam_cc_clock_state, 0, sizeof(cam_cc_clock_state));
	memset(cam_cc_native_domains, 0, sizeof(cam_cc_native_domains));
	memset(domains, 0, sizeof(domains)); memset(classes, 0, sizeof(classes));
	memset(parent_clks, 0, sizeof(parent_clks)); memset(&boot_clk, 0, sizeof(boot_clk));
	memset(plls, 0, sizeof(plls)); memset(&postdiv, 0, sizeof(postdiv));
	memset(&rcg, 0, sizeof(rcg)); memset(&branch, 0, sizeof(branch));
	steps = fail_at = resources = registered_clocks = 0;
	reset_published = domain_published = clock_published = 0;
	configured_plls = sync_error = sync_calls = genpd_syncs = sequence_size = 0;
	model_domains_on = boot_on; first_resume = boot_drop_fault = domain_sync_fault = false;
	crm_mapping = crm_active = busy_at_suspend = false;
	model_driver.sync_state = cam_cc_native_sync_state;
	model_device.dev.driver = &model_driver; model_device.dev.of_node = &model_node;
	for (int i = 0; i < 3; i++) {
		classes[i].num_levels = i == 1 ? 3 : 4;
		parent_clks[i].rate = i < 2 ? 19200000 : 32000;
	}
	for (int i = 0; i < 2; i++) {
		plls[i].offset = i * 0x100; plls[i].regs = pll_regs; plls[i].config = &pll_config[i];
		if (boot_on) {
			model_map.words[plls[i].offset / 4] = BIT(0);
			model_map.words[(plls[i].offset + 4) / 4] = 1;
			model_map.words[(plls[i].offset + 12) / 4] = 43;
		}
	}
	rcg.cmd_rcgr = 0x400; model_map.words[0x400 / 4] = boot_on ? 0 : BIT(31);
	model_map.words[0x404 / 4] = 0x103;
	branch.clkr.enable_reg = branch.halt_reg = 0x500; branch.clkr.enable_mask = 1;
}

static void normal_lifecycle(void)
{
	for (int on = 0; on < 2; on++) {
		defaults(on); assert(!cam_cc_native_probe(&model_device));
		assert(resources && cam_cc_native.ready && !cam_cc_power.fault);
		assert(reset_published && domain_published && clock_published && registered_clocks == 5);
		assert(configured_plls == (on ? 0 : 2));
		assert(model_driver.sync_state == cam_cc_native_sync_state);
		int order[] = {3, 4, 2, 1, 0};
		assert(!memcmp(order, sequence, sizeof(order)));
		assert(model_map.words[0x404 / 4] == 0x103 && rcg.parked_cfg == 0x103);
		assert(boot_clk.enabled == on && boot_clk.references == on);
		assert(cam_cc_native.proxy_votes == 7 && model_device.dev.usage == 1 + 2 * on);
		struct of_phandle_args args = {.args_count = 1, .args = {0}};
		assert(cam_cc_native_clock_get(&args, &cam_cc_native) == &branch.clkr.hw);
		assert(cam_cc_native_domain_get(&args, &cam_cc_native_domain_data) == &domains[0].pd);
		sync_error = -EAGAIN; int events_before = sequence_size;
		cam_cc_native_sync_state(&model_device.dev);
		assert(!cam_cc_native.synchronized && !genpd_syncs && cam_cc_native.proxy_votes == 7);
		assert(sequence_size == events_before + 1 && boot_clk.enabled == on);
		sync_error = 0; sequence_size = 0;
		cam_cc_native_sync_state(&model_device.dev);
		assert(sequence[0] == EVENT_CLOCK_SYNC);
		assert(sequence[on ? 2 : 1] == EVENT_DOMAIN_SYNC);
		assert(sequence[sequence_size - 1] == EVENT_PM_DROP);
		assert(cam_cc_native.synchronized && !cam_cc_native.proxy_votes && !model_device.dev.usage);
		assert(!boot_clk.references && !boot_clk.enabled && !model_device.dev.active);
		int calls = sync_calls; cam_cc_native_sync_state(&model_device.dev); assert(sync_calls == calls);
	}
	puts("CAMCC native: cold/boot-ON parent-first registration, original CFG, CCF/genpd composition, EAGAIN and ordered/idempotent handoff passed");
}

static void probe_failures(void)
{
	unsigned int cases = 0;
	for (int on = 0; on < 2; on++) {
		defaults(on); assert(!cam_cc_native_probe(&model_device)); int total = steps;
		for (int failure = 1; failure <= total; failure++) {
			defaults(on); fail_at = failure;
			int ret = cam_cc_native_probe(&model_device);
			if (failure <= 7) {
				assert(ret == -EREMOTEIO && !resources && !cam_cc_power.fault);
				assert(!parent_clks[0].references && !parent_clks[1].references && !parent_clks[2].references);
			} else {
				assert(!ret && resources && cam_cc_power.fault);
				assert(!cam_cc_native.ready);
				struct of_phandle_args args = {.args_count = 1};
				assert(PTR_ERR(cam_cc_native_clock_get(&args, &cam_cc_native)) == -EIO);
				assert(PTR_ERR(cam_cc_native_domain_get(&args, &cam_cc_native_domain_data)) == -EIO);
				assert(cam_cc_native_reset_begin(&cam_cc_native_reset.rcdev, 0) == -EIO);
				int old_steps = steps; cam_cc_native_sync_state(&model_device.dev); assert(steps == old_steps);
			}
			cases++;
		}
	}
	printf("CAMCC native: %u exact API/MMIO probe fault points preserve clean retry or bound fault resources\n", cases);
	defaults(true); crm_active = true;
	assert(!cam_cc_native_probe(&model_device));
	assert(cam_cc_power.fault && cam_cc_power.primary_error == -EOPNOTSUPP);
	assert(resources && crm_mapping && model_device.dev.active && cam_cc_native.probe_pm_held);
	assert(!configured_plls && !registered_clocks && !reset_published && !domain_published && !clock_published);
	assert(!cam_cc_native.ready);
	int before_sync = steps; cam_cc_native_sync_state(&model_device.dev); assert(steps == before_sync);
	puts("CAMCC native: checked always-on transport gates precede CRM reads; active CRM refuses managed clock programming/publication and retains powered resources");
	defaults(false); busy_at_suspend = true;
	assert(!cam_cc_native_probe(&model_device));
	assert(cam_cc_power.fault && cam_cc_power.primary_error == -EBUSY && resources && crm_mapping);
	assert(parent_clks[0].references && parent_clks[1].references && parent_clks[2].references);
	assert(!configured_plls && !registered_clocks && !reset_published && !cam_cc_native.ready);
	puts("CAMCC native: an unexpected pre-PM reference retains parent clocks and CRM mapping instead of taking clean failure cleanup");
}

static void reset_and_lookup(void)
{
	defaults(false); assert(!cam_cc_native_probe(&model_device));
	struct of_phandle_args args = {.args_count = 1, .args = {5}};
	assert(PTR_ERR(cam_cc_native_clock_get(&args, &cam_cc_native)) == -EINVAL);
	args.args[0] = 2; assert(PTR_ERR(cam_cc_native_domain_get(&args, &cam_cc_native_domain_data)) == -EINVAL);
	args.args[0] = 0; args.args_count = 0;
	assert(PTR_ERR(cam_cc_native_clock_get(&args, &cam_cc_native)) == -EINVAL);
	assert(PTR_ERR(cam_cc_native_domain_get(&args, &cam_cc_native_domain_data)) == -EINVAL);
	cam_cc_native.ready = false;
	assert(PTR_ERR(cam_cc_native_clock_get(&args, &cam_cc_native)) == -EPROBE_DEFER);
	assert(cam_cc_native_reset_begin(&cam_cc_native_reset.rcdev, 0) == -EPROBE_DEFER);
	cam_cc_native.ready = true;
	int usage = model_device.dev.usage;
	assert(!cam_cc_native_reset_assert(&cam_cc_native_reset.rcdev, 0));
	assert(model_map.words[0x600 / 4] == 1 && model_device.dev.usage == usage);
	assert(!cam_cc_native_reset_deassert(&cam_cc_native_reset.rcdev, 0));
	assert(!model_map.words[0x600 / 4] && model_device.dev.usage == usage);
	assert(!cam_cc_native_reset_pulse(&cam_cc_native_reset.rcdev, 1));
	assert(!model_map.words[0x604 / 4] && model_device.dev.usage == usage);
	assert(cam_cc_native_reset_assert(&cam_cc_native_reset.rcdev, 2) == -EINVAL);
	for (int failure = 1; failure <= 5; failure++) {
		defaults(false); assert(!cam_cc_native_probe(&model_device)); usage = model_device.dev.usage;
		fail_at = steps + failure;
		assert(cam_cc_native_reset_pulse(&cam_cc_native_reset.rcdev, 0) == -EREMOTEIO);
		assert(model_device.dev.usage == usage + (failure > 1));
		assert(!!cam_cc_power.fault == (failure > 1));
	}
	puts("CAMCC native: early/fault/bounds lookup gates and reset pulse/readback/PM error paths passed");
}

static void disable_postconditions(void)
{
	defaults(false); assert(!cam_cc_native_probe(&model_device));
	struct cam_cc_clock *clock = &cam_cc_clock_state[0];
	model_map.words[0x500 / 4] = BIT(31); assert(!cam_cc_native_disable_check(clock));
	model_map.words[0x500 / 4] = BIT(0); assert(cam_cc_native_disable_check(clock) == -EIO);
	model_map.words[0x500 / 4] = 0; assert(cam_cc_native_disable_check(clock) == -ETIMEDOUT);
	branch.halt_check = BRANCH_HALT_VOTED; assert(!cam_cc_native_disable_check(clock));
	clock = &cam_cc_clock_state[1]; model_map.words[0x404 / 4] = 0;
	assert(!cam_cc_native_disable_check(clock));
	model_map.words[0x400 / 4] = BIT(0); assert(cam_cc_native_disable_check(clock) == -ETIMEDOUT);
	model_map.words[0x400 / 4] = 0; model_map.words[0x404 / 4] = 0x100;
	assert(cam_cc_native_disable_check(clock) == -EIO);
	for (int i = 3; i < 5; i++) {
		clock = &cam_cc_clock_state[i]; unsigned int offset = plls[i - 3].offset;
		assert(!cam_cc_native_disable_check(clock));
		model_map.words[offset / 4] = 1; assert(cam_cc_native_disable_check(clock) == -EIO);
		model_map.words[offset / 4] = 0; model_map.words[(offset + 8) / 4] = BIT(21);
		assert(cam_cc_native_disable_check(clock) == -EOPNOTSUPP);
		model_map.words[(offset + 8) / 4] = 0;
	}
	puts("CAMCC native: branch vote/halt, RCG update/park and both PLL disable postconditions passed");
}

static void handoff_failures(void)
{
	for (int failure = 0; failure < 5; failure++) {
		defaults(true); assert(!cam_cc_native_probe(&model_device));
		if (failure == 0) boot_drop_fault = true;
		else if (failure == 1) domain_sync_fault = true;
		else fail_at = steps + failure - 1;
		cam_cc_native_sync_state(&model_device.dev);
		assert(cam_cc_power.fault && resources && !cam_cc_native.synchronized);
		assert(cam_cc_native.probe_pm_held && model_device.dev.active && model_device.dev.usage > 0);
		assert(cam_cc_native.proxy_votes != 0);
		int old_steps = steps, old_calls = sync_calls;
		cam_cc_native_sync_state(&model_device.dev);
		assert(steps == old_steps && sync_calls == old_calls);
	}
	puts("CAMCC native: RCG/domain/proxy-release faults retain initial power and prevent handoff retry");
}

int main(void)
{
	normal_lifecycle(); probe_failures(); reset_and_lookup(); disable_postconditions(); handoff_failures();
	return 0;
}
