// SPDX-License-Identifier: GPL-2.0-only
/* Real voltage functions and provider callbacks; hardware/CCF boundaries modeled. */
#define CLOCKS_TEST
#define main original_owner_checks
#include "camcc-provider-check.c"
#undef main

struct clk_regmap { struct clk_hw hw; struct clk_vdd_class_data vdd_data; };
#define to_clk_regmap(hw) ((struct clk_regmap *)(hw))
static unsigned long clk_hw_get_rate(struct clk_hw *hw) { return hw->rate; }
static bool clk_hw_is_prepared(struct clk_hw *hw) { return hw->prepared; }
#include "clocks-voltage.c"

struct clk_ops {
	int (*prepare)(struct clk_hw *);
	void (*unprepare)(struct clk_hw *);
	int (*enable)(struct clk_hw *);
	void (*disable)(struct clk_hw *);
	int (*pre_rate_change)(struct clk_hw *, unsigned long, unsigned long);
	int (*post_rate_change)(struct clk_hw *, unsigned long, unsigned long);
	int (*set_rate)(struct clk_hw *, unsigned long, unsigned long);
	int (*set_parent)(struct clk_hw *, u8);
	int (*set_rate_and_parent)(struct clk_hw *, unsigned long, unsigned long, u8);
	int (*init)(struct clk_hw *);
	unsigned long (*recalc_rate)(struct clk_hw *, unsigned long);
};
struct clk_init_data {
	const char *name;
	const struct clk_ops *ops;
	const char * const *parent_names;
	u8 num_parents;
	unsigned long flags;
};
static int native_calls, native_error;
static int native_prepare(struct clk_hw *hw)
{
	struct clk_vdd_class_data *data = &to_clk_regmap(hw)->vdd_data;
	int level = clk_find_vdd_level(hw, data, hw->rate);
	native_calls++;
	assert(level > 0);
	if (data->vdd_class) assert(data->vdd_class->level_votes[level] > 0);
	for (int i = 0; i < data->num_vdd_classes; i++)
		assert(data->vdd_classes[i]->level_votes[level] > 0);
	return native_error;
}
static int native_enable(struct clk_hw *hw) { native_calls++; return native_error; }
static void native_disable(struct clk_hw *hw) { native_calls++; }
static int native_rate(struct clk_hw *hw, unsigned long rate, unsigned long parent)
{
	native_calls++;
	if (!native_error) hw->rate = rate;
	return native_error;
}
static int native_parent(struct clk_hw *hw, u8 index) { native_calls++; return native_error; }
static int native_rate_parent(struct clk_hw *hw, unsigned long rate, unsigned long parent, u8 index)
{
	return native_rate(hw, rate, parent);
}
static int native_init(struct clk_hw *hw) { return 27; }
static unsigned long native_recalc(struct clk_hw *hw, unsigned long parent) { return hw->rate; }
static const struct clk_ops clk_alpha_pll_lucid_evo_ops = {
	.prepare = native_prepare, .enable = native_enable, .disable = native_disable,
	.set_rate = native_rate, .init = native_init, .recalc_rate = native_recalc,
};
static const struct clk_ops clk_alpha_pll_rivian_evo_ops = {
	.enable = native_enable, .disable = native_disable, .recalc_rate = native_recalc,
};
static const struct clk_ops clk_alpha_pll_postdiv_lucid_ole_ops = {
	.set_rate = native_rate, .recalc_rate = native_recalc,
};
static const struct clk_ops clk_rcg2_shared_ops = {
	.prepare = clk_prepare_regmap, .unprepare = clk_unprepare_regmap,
	.pre_rate_change = clk_pre_change_regmap, .post_rate_change = clk_post_change_regmap,
	.enable = native_enable, .disable = native_disable, .set_rate = native_rate,
	.set_parent = native_parent, .set_rate_and_parent = native_rate_parent,
	.init = native_init, .recalc_rate = native_recalc,
};
static const struct clk_ops clk_branch2_ops = {
	.enable = native_enable, .disable = native_disable,
};
static struct clk_regmap test_clocks[5];
static struct clk_regmap *cam_cc_sm7675_clocks[] = {
	&test_clocks[0], &test_clocks[1], NULL, &test_clocks[2], &test_clocks[3], &test_clocks[4],
};
static struct clk_vdd_class *multi_rails[] = { &cam_cc_mm, &cam_cc_mxc };
static unsigned long test_rates[VDD_NUM] = {
	[VDD_LOWER_D1] = 100000000, [VDD_LOW] = 200000000, [VDD_NOMINAL] = 400000000,
};
static unsigned long rivian_rates[VDD_NUM] = { [VDD_LOW] = 200000000 };
static const char * const test_parents[] = { "fixture-parent" };
static struct clk_init_data original_inits[5];
#include "provider-clocks.h"

static void clock_reset(struct device *dev, bool powered)
{
	/* Fresh isolated model machine, never a production reset/recovery API. */
	start(dev);
	memset(cam_cc_clock_state, 0, sizeof(cam_cc_clock_state));
	cam_cc_clocks_ready = false;
	memset(test_clocks, 0, sizeof(test_clocks));
	const struct clk_ops *ops[] = { &clk_alpha_pll_lucid_evo_ops,
		&clk_alpha_pll_rivian_evo_ops, &clk_alpha_pll_postdiv_lucid_ole_ops,
		&clk_rcg2_shared_ops, &clk_branch2_ops };
	for (int i = 0; i < 5; i++) {
		original_inits[i] = (struct clk_init_data) { .name = "fixture-clock", .ops = ops[i],
			.parent_names = test_parents, .num_parents = 1, .flags = 0x352 };
		test_clocks[i].hw.init = &original_inits[i];
		test_clocks[i].hw.rate = 200000000;
	}
	test_clocks[0].vdd_data = (struct clk_vdd_class_data) {
		.vdd_class = &cam_cc_mxc, .rate_max = test_rates, .num_rate_max = VDD_NUM };
	test_clocks[1].vdd_data = (struct clk_vdd_class_data) {
		.vdd_class = &cam_cc_mx, .rate_max = rivian_rates, .num_rate_max = VDD_NUM };
	test_clocks[3].vdd_data = (struct clk_vdd_class_data) {
		.vdd_classes = multi_rails, .num_vdd_classes = 2,
		.rate_max = test_rates, .num_rate_max = VDD_NUM };
	native_calls = native_error = 0;
	if (powered) active(dev);
}

static void prepare_clock(int index)
{
	struct clk_hw *hw = &test_clocks[index].hw;
	assert(hw->init->ops->prepare(hw) == 0);
	hw->prepared = true;
}
static void unprepare_clock(int index)
{
	struct clk_hw *hw = &test_clocks[index].hw;
	hw->prepared = false; /* CCF decrements before its unprepare callback. */
	hw->init->ops->unprepare(hw);
}
static void fault_stops_everything(struct device *dev, int index)
{
	struct clk_hw *hw = &test_clocks[index].hw;
	const struct clk_ops *ops = hw->init->ops;
	int before = operations + native_calls;
	assert(cam_cc_power.fault == -EIO);
	assert(ops->prepare(hw) == -EIO);
	ops->unprepare(hw);
	assert(ops->pre_rate_change(hw, 200000000, 400000000) == -EIO);
	assert(ops->post_rate_change(hw, 400000000, 200000000) == -EIO);
	if (ops->enable) assert(ops->enable(hw) == -EIO);
	if (ops->disable) ops->disable(hw);
	if (ops->set_rate) assert(ops->set_rate(hw, 200000000, 100000000) == -EIO);
	if (ops->set_parent) assert(ops->set_parent(hw, 0) == -EIO);
	if (ops->set_rate_and_parent) assert(ops->set_rate_and_parent(hw, 200000000, 100000000, 0) == -EIO);
	assert(operations + native_calls == before);
	assert(cam_cc_owner_probe_failed(-ENOMEM) == -ENOMEM);
	failed_probe_cleanup(dev);
	assert_resources_retained(dev);
	blocked_access(-EIO);
}

static void admission(void)
{
	struct device dev;
	clock_reset(&dev, false);
	cam_cc_power.dev = NULL;
	assert(cam_cc_clocks_init() == -ENODEV);
	clock_reset(&dev, false);
	cam_cc_power.publication_started = true;
	assert(cam_cc_clocks_init() == -EBUSY);
	for (int bad = 0; bad < 3; bad++) {
		clock_reset(&dev, false);
		struct clk_ops unknown = clk_branch2_ops;
		if (bad == 0) test_clocks[4].hw.init = NULL;
		if (bad == 1) original_inits[4].ops = &unknown;
		if (bad == 2) validation_error = -ERANGE;
		assert(cam_cc_clocks_init() == (bad == 2 ? -ERANGE : -EINVAL));
		assert(!cam_cc_clocks_ready && !native_calls && !operations);
		for (int i = 0; i < 4; i++) assert(test_clocks[i].hw.init == &original_inits[i]);
	}
	clock_reset(&dev, false);
	assert(cam_cc_clocks_init() == 0 && cam_cc_clocks_init() == 0);
	assert(!cam_cc_clock_state[2].clock);
	for (int i = 0; i < 5; i++) {
		const struct clk_init_data *init = test_clocks[i].hw.init;
		assert(init->name == original_inits[i].name && init->flags == original_inits[i].flags);
		assert(init->parent_names == test_parents && init->num_parents == 1);
		assert(init->ops->init == original_inits[i].ops->init);
		assert(init->ops->recalc_rate == original_inits[i].ops->recalc_rate);
		assert(init->ops->prepare(&test_clocks[i].hw) == -EHOSTDOWN);
	}
	assert(!native_calls && !operations);
	struct clk_hw foreign = { 0 };
	assert(cam_cc_clock_prepare(&foreign) == -ENODEV);
	puts("CAMCC clocks: complete-table admission, sparse slots, metadata and clean idempotence pass");
}

static void normal_clocks(void)
{
	struct device dev;
	clock_reset(&dev, true);
	assert(cam_cc_clocks_init() == 0);
	for (int i = 0; i < 5; i++) prepare_clock(i);
	assert(cam_cc_clocks_init() == -EBUSY);
	/* Shared generic callbacks and the PLL wrapper each vote exactly once. */
	assert(cam_cc_mm.level_votes[VDD_LOW] == 1);
	assert(cam_cc_mxc.level_votes[VDD_LOW] == 2);
	assert(cam_cc_mx.level_votes[VDD_LOW] == 1);
	for (int i = 0; i < 5; i++) {
		struct clk_hw *hw = &test_clocks[i].hw;
		const struct clk_ops *ops = hw->init->ops;
		if (ops->enable) assert(ops->enable(hw) == 0);
		if (ops->disable) ops->disable(hw);
	}
	for (int i = 4; i >= 0; i--) unprepare_clock(i);
	assert(!cam_cc_power.fault);
	assert(!cam_cc_mm.level_votes[VDD_LOW] && !cam_cc_mxc.level_votes[VDD_LOW]);
	assert(!cam_cc_mx.level_votes[VDD_LOW]);
	for (int i = 0; i < 3; i++) assert(regulators[i].count == 1);
	assert(dev.ops->runtime_suspend(&dev) == 0);
	clock_reset(&dev, true);
	assert(cam_cc_clocks_init() == 0);
	struct clk_vdd_class_data independent = { .vdd_class = &cam_cc_mxc };
	assert(clk_vote_vdd_level(&independent, VDD_NOMINAL) == 0);
	prepare_clock(0);
	unprepare_clock(0);
	assert(cam_cc_mxc.level_votes[VDD_NOMINAL] == 1);
	assert(regulators[2].voltage == RPMH_REGULATOR_LEVEL_NOM);
	assert(clk_unvote_vdd_level(&independent, VDD_NOMINAL) == 0);
	puts("CAMCC clocks: five native families, exact single/multiple-rail votes, original callbacks and controller MIN ownership pass");
}

static void rate_changes(void)
{
	struct device dev;
	clock_reset(&dev, true);
	assert(cam_cc_clocks_init() == 0);
	prepare_clock(3);
	struct clk_hw *hw = &test_clocks[3].hw;
	const struct clk_ops *ops = hw->init->ops;
	assert(ops->pre_rate_change(hw, 200000000, 400000000) == 0);
	assert(cam_cc_mm.level_votes[VDD_NOMINAL] == 1 && cam_cc_mxc.level_votes[VDD_NOMINAL] == 1);
	assert(!cam_cc_mm.level_votes[VDD_LOW] && !cam_cc_mxc.level_votes[VDD_LOW]);
	assert(ops->set_rate(hw, 400000000, 100000000) == 0);
	assert(ops->post_rate_change(hw, 200000000, 400000000) == 0);
	assert(ops->pre_rate_change(hw, 400000000, 100000000) == 0);
	assert(ops->set_rate_and_parent(hw, 100000000, 100000000, 0) == 0);
	assert(ops->post_rate_change(hw, 400000000, 100000000) == 0);
	assert(cam_cc_mm.level_votes[VDD_LOWER_D1] == 1 && cam_cc_mxc.level_votes[VDD_LOWER_D1] == 1);
	assert(!cam_cc_mm.level_votes[VDD_NOMINAL] && !cam_cc_mxc.level_votes[VDD_NOMINAL]);
	assert(ops->set_parent(hw, 0) == 0);
	unprepare_clock(3);
	assert(!cam_cc_mm.level_votes[VDD_LOWER_D1] && !cam_cc_mxc.level_votes[VDD_LOWER_D1]);
	assert(ops->pre_rate_change(hw, 100000000, 200000000) == 0); /* Unprepared: cache, no vote. */
	assert(!cam_cc_mm.level_votes[VDD_LOW] && test_clocks[3].vdd_data.vdd_level == VDD_LOW);
	int before = operations + native_calls;
	assert(ops->pre_rate_change(hw, 200000000, 401000000) < 0 && !cam_cc_power.fault);
	assert(before == operations + native_calls);
	puts("CAMCC clocks: rise-before-rate, lower-after-rate, combined parent change, stopped cache and unsupported-rate refusal pass");
}

static void callback_faults(void)
{
	struct device dev;
	for (int kind = 0; kind < 6; kind++) {
		clock_reset(&dev, true);
		assert(cam_cc_clocks_init() == 0);
		int index = kind == 0 ? 0 : 3;
		struct clk_hw *hw = &test_clocks[index].hw;
		const struct clk_ops *ops = hw->init->ops;
		if (kind) prepare_clock(index);
		native_error = -ETIMEDOUT;
		if (!kind) assert(ops->prepare(hw) == -EIO);
		if (kind == 1) assert(ops->enable(hw) == -EIO);
		if (kind == 2) assert(ops->set_rate(hw, 100000000, 100000000) == -EIO);
		if (kind == 3) assert(ops->set_parent(hw, 0) == -EIO);
		if (kind == 4) assert(ops->set_rate_and_parent(hw, 100000000, 100000000, 0) == -EIO);
		if (kind == 5) assert(ops->prepare(hw) == -EIO); /* Duplicate callback is corrupt. */
		assert(cam_cc_power.primary_error == (kind == 5 ? -EUCLEAN : -ETIMEDOUT));
		assert(cam_cc_mxc.level_votes[VDD_LOW] == 1);
		fault_stops_everything(&dev, index);
	}
	puts("CAMCC clocks: calibration/enable/rate/parent/duplicate failures latch once and stop backend operations across core cleanup");
}

static void voltage_faults(void)
{
	struct device dev;
	for (int rail = 0; rail < 2; rail++) {
		for (int phase = 0; phase < 4; phase++) {
			clock_reset(&dev, true);
			assert(cam_cc_clocks_init() == 0);
			struct clk_hw *hw = &test_clocks[3].hw;
			const struct clk_ops *ops = hw->init->ops;
			if (phase) prepare_clock(3);
			if (phase == 2) {
				assert(ops->pre_rate_change(hw, 200000000, 400000000) == 0);
				assert(ops->set_rate(hw, 400000000, 100000000) == 0);
				assert(ops->post_rate_change(hw, 200000000, 400000000) == 0);
				assert(ops->pre_rate_change(hw, 400000000, 100000000) == 0);
				assert(ops->set_rate(hw, 100000000, 100000000) == 0);
			}
			regulators[rail ? 2 : 0].set_error = -EREMOTEIO;
			if (!phase) assert(ops->prepare(hw) == -EIO);
			if (phase == 1) assert(ops->pre_rate_change(hw, 200000000, 400000000) == -EIO);
			if (phase == 2) assert(ops->post_rate_change(hw, 400000000, 100000000) == -EIO);
			if (phase == 3) unprepare_clock(3);
			assert(cam_cc_power.primary_error == -EREMOTEIO);
			assert(cam_cc_power.uncertain_rails == CAM_CC_POWER_RAILS);
			fault_stops_everything(&dev, 3);
		}
	}
	puts("CAMCC clocks: prepare/up-rate/post-rate/unprepare voltage errors on either shared rail remain visible and retain owner resources");
}

static int fail_disable_check(struct cam_cc_clock *clock)
{
	assert(clock->prepared);
	return -ETIMEDOUT;
}

static void disable_observation(void)
{
	struct device dev;
	clock_reset(&dev, true);
	assert(!cam_cc_clocks_init());
	prepare_clock(0);
	cam_cc_clock_state[0].disable_check = fail_disable_check;
	int calls = native_calls;
	test_clocks[0].hw.init->ops->disable(&test_clocks[0].hw);
	assert(native_calls == calls + 1 && cam_cc_power.primary_error == -ETIMEDOUT);
	assert(cam_cc_clock_state[0].voted && cam_cc_clock_state[0].prepared);
	assert(cam_cc_mxc.level_votes[VDD_LOW] == 1);
	fault_stops_everything(&dev, 0);
	puts("CAMCC clocks: observed void-disable failure latches fault before voltage unprepare and preserves resources");
}

int main(void)
{
#ifdef CLOCKS_BASELINE
	struct device dev;
	clock_reset(&dev, true);
	/* Actual Rivian native family has no prepare/VDD callback. Model CCF's call. */
	struct clk_hw *hw = &test_clocks[1].hw;
	if (hw->init->ops->prepare) assert(hw->init->ops->prepare(hw) == 0);
	hw->prepared = true;
	assert(cam_cc_mx.level_votes[VDD_LOW] == 1);
#else
	assert(original_owner_checks() == 0);
	admission(); normal_clocks(); rate_changes(); callback_faults(); voltage_faults(); disable_observation();
#endif
	return 0;
}
