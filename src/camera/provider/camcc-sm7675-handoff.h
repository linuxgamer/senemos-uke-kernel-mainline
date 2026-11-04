/* SPDX-License-Identifier: GPL-2.0-only */
/* Native registration helpers; include after the catalog, owner and clocks. */
#ifndef UKE_CAMCC_SM7675_HANDOFF_H
#define UKE_CAMCC_SM7675_HANDOFF_H

#include <linux/delay.h>
#include <linux/iopoll.h>

/* Stable 7.3.1 clk-rcg2.c / clk-alpha-pll.c register definitions. */
#define CAM_CC_RCG_UPDATE BIT(0)
#define CAM_CC_RCG_ROOT_EN BIT(1)
#define CAM_CC_RCG_ROOT_OFF BIT(31)
#define CAM_CC_RCG_CFG 0x4
#define CAM_CC_PLL_OUTCTRL BIT(0)
#define CAM_CC_PLL_OUTPUTS GENMASK(2, 0)
#define CAM_CC_PLL_FSM (BIT(21) | BIT(25))

static struct {
	struct clk *parents[3];
	struct clk *boot_rcgs[ARRAY_SIZE(cam_cc_sm7675_clocks)];
	bool boot_rcg_on[ARRAY_SIZE(cam_cc_sm7675_clocks)];
	bool registered[ARRAY_SIZE(cam_cc_sm7675_clocks)];
	unsigned int proxy_votes;
	bool pm_enabled;
	bool probe_pm_held;
	bool ready;
	bool synchronized;
} cam_cc_native;

static int cam_cc_native_fail(int error)
{
	if (!READ_ONCE(cam_cc_power.fault))
		cam_cc_power_fail(error, 0, 0);
	return error;
}

static int cam_cc_native_parents_get(struct device *dev)
{
	static const char * const names[] = { "bi_tcxo", "bi_tcxo_ao", "sleep_clk" };
	unsigned int i;
	int ret;

	for (i = 0; i < ARRAY_SIZE(names); i++) {
		cam_cc_native.parents[i] = clk_get(dev, names[i]);
		if (IS_ERR(cam_cc_native.parents[i])) {
			ret = PTR_ERR(cam_cc_native.parents[i]);
			cam_cc_native.parents[i] = NULL;
			goto put;
		}
		if (!clk_get_rate(cam_cc_native.parents[i]) ||
		    (i < 2 && clk_get_rate(cam_cc_native.parents[i]) != 19200000)) {
			ret = -EINVAL;
			i++;
			goto put;
		}
	}
	return 0;
put:
	while (i) {
		i--;
		clk_put(cam_cc_native.parents[i]);
		cam_cc_native.parents[i] = NULL;
	}
	return ret;
}

static void cam_cc_native_parents_put(void)
{
	unsigned int i;

	for (i = ARRAY_SIZE(cam_cc_native.parents); i-- > 0;) {
		if (cam_cc_native.parents[i]) {
			clk_put(cam_cc_native.parents[i]);
			cam_cc_native.parents[i] = NULL;
		}
	}
}

/* Protect possible boot rates before runtime_resume installs its MIN votes. */
static int cam_cc_native_proxy_get(void)
{
	unsigned int i;
	int ret;

	if (cam_cc_native.proxy_votes)
		return -EBUSY;
	for (i = 0; i < ARRAY_SIZE(cam_cc_sm7675_regulators); i++) {
		struct clk_vdd_class_data vote = { .vdd_class = cam_cc_sm7675_regulators[i] };

		ret = clk_vote_vdd_level(&vote, vote.vdd_class->num_levels - 1);
		if (ret) {
			cam_cc_power_fail(ret, 0, BIT(i));
			return ret;
		}
		cam_cc_native.proxy_votes |= BIT(i);
	}
	return 0;
}

static int cam_cc_native_proxy_put(void)
{
	unsigned int i;
	int ret;

	for (i = ARRAY_SIZE(cam_cc_sm7675_regulators); i-- > 0;) {
		struct clk_vdd_class_data vote = { .vdd_class = cam_cc_sm7675_regulators[i] };

		if (READ_ONCE(cam_cc_power.fault))
			return READ_ONCE(cam_cc_power.fault);
		if (!(cam_cc_native.proxy_votes & BIT(i)))
			continue;
		ret = clk_unvote_vdd_level(&vote, vote.vdd_class->num_levels - 1);
		if (ret) {
			cam_cc_power_fail(ret, 0, BIT(i));
			return ret;
		}
		cam_cc_native.proxy_votes &= ~BIT(i);
	}
	return 0;
}

/* Preserve boot CFG: native shared_init parks before CCF can acquire a hold. */
static int cam_cc_native_rcg_init(struct clk_hw *hw)
{
	struct clk_rcg2 *rcg = to_clk_rcg2(hw);
	int ret = regmap_read(rcg->clkr.regmap, rcg->cmd_rcgr + CAM_CC_RCG_CFG,
			      &rcg->parked_cfg);

	return ret ? cam_cc_native_fail(ret) : 0;
}

static int cam_cc_native_disable_check(struct cam_cc_clock *clock)
{
	struct regmap *map = clock->clock->regmap;
	struct clk_hw *hw = &clock->clock->hw;
	u32 value, mode;
	int ret;

	if (clock->native == &clk_branch2_ops) {
		struct clk_branch *br = to_clk_branch(hw);

		ret = regmap_read(map, br->clkr.enable_reg, &value);
		if (ret)
			return ret;
		if ((value & br->clkr.enable_mask) !=
		    (br->clkr.enable_is_inverted ? br->clkr.enable_mask : 0))
			return -EIO;
		/* Voted/delayed branches need not globally halt after our unvote. */
		if (br->halt_check & BRANCH_VOTED || br->halt_check == BRANCH_HALT_DELAY)
			return 0;
		return regmap_read_poll_timeout_atomic(map, br->halt_reg, value,
						      value & BIT(31), 1, 200);
	}
	if (clock->native == &clk_rcg2_shared_ops) {
		struct clk_rcg2 *rcg = to_clk_rcg2(hw);

		ret = regmap_read_poll_timeout_atomic(map, rcg->cmd_rcgr, value,
				!(value & (CAM_CC_RCG_UPDATE | CAM_CC_RCG_ROOT_EN)), 1, 500);
		if (ret)
			return ret;
		ret = regmap_read(map, rcg->cmd_rcgr + CAM_CC_RCG_CFG, &value);
		if (ret)
			return ret;
		return value == rcg->safe_src_index << 8 ? 0 : -EIO;
	}
	if (clock->native == &clk_alpha_pll_lucid_evo_ops ||
	    clock->native == &clk_alpha_pll_rivian_evo_ops) {
		struct clk_alpha_pll *pll = container_of(to_clk_regmap(hw), struct clk_alpha_pll, clkr);

		ret = regmap_read(map, pll->offset + pll->regs[PLL_OFF_USER_CTL], &value);
		if (ret)
			return ret;
		/* The admitted catalog has no FSM vote register/mask. */
		if (value & CAM_CC_PLL_FSM)
			return -EOPNOTSUPP;
		if (value & CAM_CC_PLL_OUTPUTS)
			return -EIO;
		ret = regmap_read(map, pll->offset, &mode);
		if (ret)
			return ret;
		ret = regmap_read(map, pll->offset + pll->regs[PLL_OFF_OPMODE], &value);
		if (ret)
			return ret;
		return !(mode & CAM_CC_PLL_OUTCTRL) && value == 0 ? 0 : -EIO;
	}
	return -EINVAL;
}

static int cam_cc_native_handoff_init(void)
{
	size_t i;
	u32 command;
	int ret;

	for (i = 0; i < ARRAY_SIZE(cam_cc_clock_state); i++) {
		struct cam_cc_clock *clock = &cam_cc_clock_state[i];

		if (!clock->clock)
			continue;
		clock->init.flags |= CLK_HOLD_STATE;
		if (clock->native->disable)
			clock->disable_check = cam_cc_native_disable_check;
		if (clock->native != &clk_rcg2_shared_ops)
			goto branch;
		clock->ops.init = cam_cc_native_rcg_init;
		ret = regmap_read(cam_cc_power.map,
				  to_clk_rcg2(&clock->clock->hw)->cmd_rcgr, &command);
		if (ret)
			return ret;
		cam_cc_native.boot_rcg_on[i] = !(command & CAM_CC_RCG_ROOT_OFF);
		continue;
branch:
		if (clock->native == &clk_branch2_ops) {
			struct clk_branch *br = to_clk_branch(&clock->clock->hw);

			if (br->hwcg_reg ||
			    (br->halt_check != BRANCH_HALT &&
			     br->halt_check != BRANCH_HALT_DELAY &&
			     br->halt_check != BRANCH_HALT_VOTED))
				return -EINVAL;
		}
	}
	return 0;
}

static int cam_cc_native_plls_configure(void)
{
	size_t i;
	u32 mode, opmode, value;
	int ret;

	/* Reject unsupported firmware voting before programming any PLL. */
	for (i = 0; i < ARRAY_SIZE(cam_cc_sm7675_plls); i++) {
		struct clk_alpha_pll *pll = cam_cc_sm7675_plls[i];

		if (!pll->config || !pll->regs)
			return -EINVAL;
		ret = regmap_read(cam_cc_power.map,
				  pll->offset + pll->regs[PLL_OFF_USER_CTL], &value);
		if (ret)
			return ret;
		if (value & CAM_CC_PLL_FSM)
			return -EOPNOTSUPP;
	}
	for (i = 0; i < ARRAY_SIZE(cam_cc_sm7675_plls); i++) {
		struct clk_alpha_pll *pll = cam_cc_sm7675_plls[i];

		ret = regmap_read(cam_cc_power.map, pll->offset, &mode);
		if (ret)
			return ret;
		ret = regmap_read(cam_cc_power.map,
				  pll->offset + pll->regs[PLL_OFF_OPMODE], &opmode);
		if (ret)
			return ret;
		if (mode & CAM_CC_PLL_OUTCTRL && opmode & BIT(0))
			continue;
		qcom_clk_alpha_pll_configure(pll, cam_cc_power.map);
		ret = cam_cc_power_access(&cam_cc_power, 0);
		if (ret)
			return ret;
		ret = regmap_read(cam_cc_power.map,
				  pll->offset + pll->regs[PLL_OFF_L_VAL], &value);
		if (ret)
			return ret;
		if ((value & 0xffff) != pll->config->l)
			return -EIO;
	}
	return 0;
}

#endif /* UKE_CAMCC_SM7675_HANDOFF_H */
