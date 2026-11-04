/* SPDX-License-Identifier: GPL-2.0-only */
/* Include after the catalog, power callbacks and permanent resource owner. */
#ifndef UKE_CAMCC_SM7675_CLOCKS_H
#define UKE_CAMCC_SM7675_CLOCKS_H

struct cam_cc_clock {
	struct clk_regmap *clock;
	const struct clk_ops *native;
	struct clk_ops ops;
	struct clk_init_data init;
	bool prepared;
	bool voted;
	int (*disable_check)(struct cam_cc_clock *clock);
};

static struct cam_cc_clock cam_cc_clock_state[ARRAY_SIZE(cam_cc_sm7675_clocks)];
static bool cam_cc_clocks_ready;

static struct cam_cc_clock *cam_cc_clock_find(struct clk_hw *hw)
{
	size_t i;

	for (i = 0; i < ARRAY_SIZE(cam_cc_clock_state); i++)
		if (cam_cc_clock_state[i].clock &&
		    &cam_cc_clock_state[i].clock->hw == hw)
			return &cam_cc_clock_state[i];
	return NULL;
}

static int cam_cc_clock_access(struct cam_cc_clock *clock)
{
	return clock ? cam_cc_power_access(&cam_cc_power, 0) : -ENODEV;
}

/* A CCF void callback or ignored post-rate errno must still retain the fault. */
static int cam_cc_clock_fail(int error, unsigned int uncertain)
{
	if (!READ_ONCE(cam_cc_power.fault))
		cam_cc_power_fail(error, 0, uncertain);
	return -EIO;
}

static int cam_cc_clock_prepare(struct clk_hw *hw)
{
	struct cam_cc_clock *clock = cam_cc_clock_find(hw);
	int ret = cam_cc_clock_access(clock);

	if (ret)
		return ret;
	if (clock->prepared)
		return cam_cc_clock_fail(-EUCLEAN, 0);
	if (clock->clock->vdd_data.rate_max) {
		/* Reject an unsupported rate before any regulator operation. */
		ret = clk_find_vdd_level(hw, &clock->clock->vdd_data, clk_hw_get_rate(hw));
		if (ret < 0)
			return ret;
		ret = clk_prepare_regmap(hw);
		if (ret)
			return cam_cc_clock_fail(ret, CAM_CC_POWER_RAILS);
		clock->voted = true;
	}
	if (clock->native->prepare && clock->native->prepare != clk_prepare_regmap) {
		ret = clock->native->prepare(hw);
		if (ret)
			/* Calibration may have started; retain its voltage and resources. */
			return cam_cc_clock_fail(ret, 0);
	}
	clock->prepared = true;
	return 0;
}

static void cam_cc_clock_unprepare(struct clk_hw *hw)
{
	struct cam_cc_clock *clock = cam_cc_clock_find(hw);
	int ret;

	if (cam_cc_clock_access(clock))
		return;
	if (!clock->prepared) {
		cam_cc_clock_fail(-EUCLEAN, 0);
		return;
	}
	if (clock->native->unprepare && clock->native->unprepare != clk_unprepare_regmap)
		clock->native->unprepare(hw);
	if (READ_ONCE(cam_cc_power.fault))
		return;
	if (clock->voted) {
		/* The generic void helper discards this error; check it explicitly. */
		ret = clk_unvote_vdd_level(&clock->clock->vdd_data,
					 clock->clock->vdd_data.vdd_level);
		if (ret) {
			cam_cc_clock_fail(ret, CAM_CC_POWER_RAILS);
			return;
		}
		clock->voted = false;
	}
	clock->prepared = false;
}

static int cam_cc_clock_pre_rate(struct clk_hw *hw, unsigned long old_rate,
				 unsigned long new_rate)
{
	struct cam_cc_clock *clock = cam_cc_clock_find(hw);
	int ret = cam_cc_clock_access(clock);

	if (ret)
		return ret;
	if (!clock->clock->vdd_data.rate_max)
		return 0;
	ret = clk_find_vdd_level(hw, &clock->clock->vdd_data, new_rate);
	if (ret < 0)
		return ret;
	ret = clk_pre_change_regmap(hw, old_rate, new_rate);
	return ret ? cam_cc_clock_fail(ret, CAM_CC_POWER_RAILS) : 0;
}

static int cam_cc_clock_post_rate(struct clk_hw *hw, unsigned long old_rate,
				  unsigned long new_rate)
{
	struct cam_cc_clock *clock = cam_cc_clock_find(hw);
	int ret = cam_cc_clock_access(clock);

	if (ret)
		return ret;
	if (!clock->clock->vdd_data.rate_max)
		return 0;
	ret = clk_post_change_regmap(hw, old_rate, new_rate);
	return ret ? cam_cc_clock_fail(ret, CAM_CC_POWER_RAILS) : 0;
}

static int cam_cc_clock_enable(struct clk_hw *hw)
{
	struct cam_cc_clock *clock = cam_cc_clock_find(hw);
	int ret = cam_cc_clock_access(clock);

	if (ret)
		return ret;
	if (!clock->prepared)
		return cam_cc_clock_fail(-EUCLEAN, 0);
	ret = clock->native->enable(hw);
	return ret ? cam_cc_clock_fail(ret, 0) : 0;
}

static void cam_cc_clock_disable(struct clk_hw *hw)
{
	struct cam_cc_clock *clock = cam_cc_clock_find(hw);
	int ret;

	if (cam_cc_clock_access(clock))
		return;
	if (!clock->prepared) {
		cam_cc_clock_fail(-EUCLEAN, 0);
		return;
	}
	clock->native->disable(hw);
	if (READ_ONCE(cam_cc_power.fault))
		return;
	if (clock->disable_check) {
		ret = clock->disable_check(clock);
		if (ret)
			cam_cc_clock_fail(ret, 0);
	}
}

static int cam_cc_clock_set_rate(struct clk_hw *hw, unsigned long rate,
				 unsigned long parent_rate)
{
	struct cam_cc_clock *clock = cam_cc_clock_find(hw);
	int ret = cam_cc_clock_access(clock);

	if (ret)
		return ret;
	ret = clock->native->set_rate(hw, rate, parent_rate);
	return ret ? cam_cc_clock_fail(ret, 0) : 0;
}

static int cam_cc_clock_set_parent(struct clk_hw *hw, u8 index)
{
	struct cam_cc_clock *clock = cam_cc_clock_find(hw);
	int ret = cam_cc_clock_access(clock);

	if (ret)
		return ret;
	ret = clock->native->set_parent(hw, index);
	return ret ? cam_cc_clock_fail(ret, 0) : 0;
}

static int cam_cc_clock_set_rate_parent(struct clk_hw *hw, unsigned long rate,
					unsigned long parent_rate, u8 index)
{
	struct cam_cc_clock *clock = cam_cc_clock_find(hw);
	int ret = cam_cc_clock_access(clock);

	if (ret)
		return ret;
	ret = clock->native->set_rate_and_parent(hw, rate, parent_rate, index);
	return ret ? cam_cc_clock_fail(ret, 0) : 0;
}

static bool cam_cc_clock_native_ops(const struct clk_ops *ops)
{
	return ops == &clk_alpha_pll_lucid_evo_ops ||
	       ops == &clk_alpha_pll_rivian_evo_ops ||
	       ops == &clk_alpha_pll_postdiv_lucid_ole_ops ||
	       ops == &clk_rcg2_shared_ops || ops == &clk_branch2_ops;
}

static int cam_cc_clocks_init(void)
{
	struct cam_cc_clock *clock;
	const struct clk_ops *ops;
	struct clk_regmap *rclk;
	size_t i;
	int ret;

	if (!cam_cc_power.dev)
		return -ENODEV;
	if (READ_ONCE(cam_cc_power.fault))
		return READ_ONCE(cam_cc_power.fault);
	if (cam_cc_power.publication_started)
		return -EBUSY;
	if (cam_cc_clocks_ready) {
		for (i = 0; i < ARRAY_SIZE(cam_cc_clock_state); i++) {
			clock = &cam_cc_clock_state[i];
			if (clock->clock && (clock->prepared || clock->voted ||
			    clock->clock->hw.init != &clock->init))
				return -EBUSY;
		}
		return 0;
	}
	ret = cam_cc_validate_voltage_data();
	if (ret)
		return ret;
	/* Validate every table before replacing any catalog pointer. */
	for (i = 0; i < ARRAY_SIZE(cam_cc_sm7675_clocks); i++) {
		rclk = cam_cc_sm7675_clocks[i];
		if (!rclk)
			continue;
		if (!rclk->hw.init || !cam_cc_clock_native_ops(rclk->hw.init->ops))
			return -EINVAL;
		ops = rclk->hw.init->ops;
		if ((ops->pre_rate_change && ops->pre_rate_change != clk_pre_change_regmap) ||
		    (ops->post_rate_change && ops->post_rate_change != clk_post_change_regmap))
			return -EINVAL;
	}
	for (i = 0; i < ARRAY_SIZE(cam_cc_sm7675_clocks); i++) {
		rclk = cam_cc_sm7675_clocks[i];
		if (!rclk)
			continue;
		clock = &cam_cc_clock_state[i];
		clock->clock = rclk;
		clock->native = rclk->hw.init->ops;
		clock->ops = *clock->native;
		clock->ops.prepare = cam_cc_clock_prepare;
		clock->ops.unprepare = cam_cc_clock_unprepare;
		clock->ops.pre_rate_change = cam_cc_clock_pre_rate;
		clock->ops.post_rate_change = cam_cc_clock_post_rate;
		if (clock->native->enable)
			clock->ops.enable = cam_cc_clock_enable;
		if (clock->native->disable)
			clock->ops.disable = cam_cc_clock_disable;
		if (clock->native->set_rate)
			clock->ops.set_rate = cam_cc_clock_set_rate;
		if (clock->native->set_parent)
			clock->ops.set_parent = cam_cc_clock_set_parent;
		if (clock->native->set_rate_and_parent)
			clock->ops.set_rate_and_parent = cam_cc_clock_set_rate_parent;
		clock->init = *rclk->hw.init;
		clock->init.ops = &clock->ops;
		rclk->hw.init = &clock->init;
	}
	cam_cc_clocks_ready = true;
	return 0;
}

#endif /* UKE_CAMCC_SM7675_CLOCKS_H */
