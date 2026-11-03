/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Copyright (c) 2022-2024, Qualcomm Innovation Center, Inc. All rights reserved.
 * SM7675 voltage tables from OEM dispcc-pineapple.c / Cliffs fixup, commit
 * 5712080a4b0c0b1a879e6d145c601c649ddaddfd. Include in dispcc-sm8550.c.
 * Use the already ported regulator aggregator, never a second RPMh writer.
 */
#include "vdd-level.h"

static DEFINE_VDD_REGULATORS(uke_vdd_mm, VDD_HIGH + 1, 1, vdd_corner);
static DEFINE_VDD_REGULATORS(uke_vdd_mxa, VDD_HIGH + 1, 1, vdd_corner);
static struct clk_vdd_class *uke_dispcc_regulators[] = { &uke_vdd_mm, &uke_vdd_mxa };
static bool uke_dispcc_proxy_active;
module_param_named(uke_proxy_active, uke_dispcc_proxy_active, bool, 0444);

static unsigned long uke_pll_rates[VDD_NUM] = {
	[VDD_LOWER_D1] = 615000000, [VDD_LOW] = 1100000000,
	[VDD_LOW_L1] = 1600000000, [VDD_NOMINAL] = 2000000000,
};
static unsigned long uke_mdp_rates[VDD_NUM] = {
	[VDD_LOWER_D1] = 155000000, [VDD_LOWER] = 200000000,
	[VDD_LOW] = 342000000, [VDD_LOW_L1] = 402000000,
	[VDD_NOMINAL] = 514000000, [VDD_HIGH] = 600000000,
};
static unsigned long uke_byte_rates[VDD_NUM] = {
	[VDD_LOWER_D1] = 140630000, [VDD_LOWER] = 187500000,
	[VDD_LOW] = 300000000, [VDD_LOW_L1] = 358000000,
};
static unsigned long uke_pixel_rates[VDD_NUM] = {
	[VDD_LOWER_D1] = 225000000, [VDD_LOWER] = 300000000,
	[VDD_LOW] = 480000000, [VDD_LOW_L1] = 625000000,
};
/* OEM Cliffs DPTX0 tables, bounded to Uke's HBR2 source limit. */
static unsigned long uke_dp_link_rates[VDD_NUM] = {
	[VDD_LOWER_D1] = 19200000, [VDD_LOWER] = 270000000,
	[VDD_LOW_L1] = 540000000,
};
static unsigned long uke_dp_pixel_rates[VDD_NUM] = {
	[VDD_LOWER_D1] = 19200000, [VDD_LOWER] = 337500000,
	[VDD_LOW_L1] = 405000000, [VDD_NOMINAL] = 675000000,
};
static unsigned long uke_dp_aux_rates[VDD_NUM] = {
	[VDD_LOWER_D1] = 19200000,
};
static struct clk_ops uke_pll_ops, uke_shared_ops, uke_byte_ops, uke_pixel_ops;
static struct clk_ops uke_dp_ops, uke_aux_ops;
static struct clk_init_data uke_clock_inits[11];

static int uke_dp_pre_rate_change(struct clk_hw *hw, unsigned long old_rate,
				  unsigned long new_rate)
{
	/* A stopped bypassed RCG must not veto its PHY parent's initial rate. */
	if (!clk_hw_is_prepared(hw))
		return 0;
	return clk_pre_change_regmap(hw, old_rate, new_rate);
}

static int uke_dp_post_rate_change(struct clk_hw *hw, unsigned long old_rate,
				   unsigned long new_rate)
{
	if (!clk_hw_is_prepared(hw))
		return 0;
	return clk_post_change_regmap(hw, old_rate, new_rate);
}

static int uke_pll_prepare(struct clk_hw *hw)
{
	int ret = clk_prepare_regmap(hw);

	if (ret)
		return ret;
	ret = clk_alpha_pll_reset_lucid_ole_ops.prepare(hw);
	if (ret)
		clk_unprepare_regmap(hw);
	return ret;
}

static void uke_dispcc_add_votes(struct clk_regmap *clock, unsigned long *rates,
				 const struct clk_ops *ops, bool mm_only, unsigned int index)
{
	clock->vdd_data = (struct clk_vdd_class_data) {
		.num_rate_max = VDD_NUM, .rate_max = rates,
	};
	if (mm_only)
		clock->vdd_data.vdd_class = &uke_vdd_mm;
	else {
		clock->vdd_data.vdd_classes = uke_dispcc_regulators;
		clock->vdd_data.num_vdd_classes = ARRAY_SIZE(uke_dispcc_regulators);
	}
	uke_clock_inits[index] = *clock->hw.init;
	uke_clock_inits[index].ops = ops;
	clock->hw.init = &uke_clock_inits[index];
}

static void uke_dispcc_voltage_release(void *data)
{
	struct device *dev = data;

	if (uke_dispcc_proxy_active) {
		if (clk_vdd_proxy_unvote(dev, &disp_cc_sm8550_desc))
			return;
		uke_dispcc_proxy_active = false;
	}
	clk_regulator_deinit(&disp_cc_sm8550_desc);
}

static int uke_dispcc_voltage_init(struct device *dev)
{
	struct clk_ops *ops[] = { &uke_pll_ops, &uke_shared_ops, &uke_byte_ops,
		&uke_pixel_ops, &uke_dp_ops, &uke_aux_ops };
	int ret;

	dev_info(dev, "Uke display boot: DISPCC voltage admission begins\n");
	/* Supply names must remain OEM vdd_mm/vdd_mxa, not the private C names. */
	uke_vdd_mm.class_name = "vdd_mm";
	uke_vdd_mxa.class_name = "vdd_mxa";
	uke_vdd_mm.regulator_names[0] = "vdd_mm";
	uke_vdd_mxa.regulator_names[0] = "vdd_mxa";
	uke_pll_ops = clk_alpha_pll_reset_lucid_ole_ops;
	uke_shared_ops = clk_rcg2_shared_ops;
	uke_byte_ops = clk_byte2_ops;
	uke_pixel_ops = clk_pixel_ops;
	uke_dp_ops = clk_dp_ops;
	uke_aux_ops = clk_rcg2_ops;
	uke_pll_ops.prepare = uke_pll_prepare;
	for (int i = 0; i < ARRAY_SIZE(ops); i++) {
		if (i)
			ops[i]->prepare = clk_prepare_regmap;
		ops[i]->unprepare = clk_unprepare_regmap;
		ops[i]->pre_rate_change = clk_pre_change_regmap;
		ops[i]->post_rate_change = clk_post_change_regmap;
	}
	uke_dp_ops.pre_rate_change = uke_dp_pre_rate_change;
	uke_dp_ops.post_rate_change = uke_dp_post_rate_change;
	uke_dispcc_add_votes(&disp_cc_pll0.clkr, uke_pll_rates, &uke_pll_ops, true, 0);
	uke_dispcc_add_votes(&disp_cc_pll1.clkr, uke_pll_rates, &uke_pll_ops, true, 1);
	uke_dispcc_add_votes(&disp_cc_mdss_mdp_clk_src.clkr, uke_mdp_rates, &uke_shared_ops, false, 2);
	uke_dispcc_add_votes(&disp_cc_mdss_byte0_clk_src.clkr, uke_byte_rates, &uke_byte_ops, false, 3);
	uke_dispcc_add_votes(&disp_cc_mdss_byte1_clk_src.clkr, uke_byte_rates, &uke_byte_ops, false, 4);
	uke_dispcc_add_votes(&disp_cc_mdss_pclk0_clk_src.clkr, uke_pixel_rates, &uke_pixel_ops, false, 5);
	uke_dispcc_add_votes(&disp_cc_mdss_pclk1_clk_src.clkr, uke_pixel_rates, &uke_pixel_ops, false, 6);
	uke_dispcc_add_votes(&disp_cc_mdss_dptx0_aux_clk_src.clkr, uke_dp_aux_rates, &uke_aux_ops, true, 7);
	uke_dispcc_add_votes(&disp_cc_mdss_dptx0_link_clk_src.clkr, uke_dp_link_rates, &uke_byte_ops, false, 8);
	uke_dispcc_add_votes(&disp_cc_mdss_dptx0_pixel0_clk_src.clkr, uke_dp_pixel_rates, &uke_dp_ops, false, 9);
	uke_dispcc_add_votes(&disp_cc_mdss_dptx0_pixel1_clk_src.clkr, uke_dp_pixel_rates, &uke_dp_ops, false, 10);
	disp_cc_sm8550_desc.clk_regulators = uke_dispcc_regulators;
	disp_cc_sm8550_desc.num_clk_regulators = ARRAY_SIZE(uke_dispcc_regulators);
	ret = clk_regulator_init(dev, &disp_cc_sm8550_desc);
	if (ret)
		return ret;
	ret = devm_add_action_or_reset(dev, uke_dispcc_voltage_release, dev);
	if (ret)
		return ret;
	ret = clk_vdd_proxy_vote(dev, &disp_cc_sm8550_desc);
	if (!ret)
		uke_dispcc_proxy_active = true;
	dev_info(dev, "Uke display boot: DISPCC proxy vote result=%d\n", ret);
	return ret;
}

static void uke_dispcc_sync_state(struct device *dev)
{
	if (!of_device_is_compatible(dev->of_node, "qcom,sm7675-dispcc"))
		return;
	dev_info(dev, "Uke display boot: DISPCC sync begins proxy=%d\n",
		 uke_dispcc_proxy_active);
	if (clk_sync_state(dev))
		return;
	if (uke_dispcc_proxy_active && !clk_vdd_proxy_unvote(dev, &disp_cc_sm8550_desc))
		uke_dispcc_proxy_active = false;
	dev_info(dev, "Uke display boot: DISPCC sync ends proxy=%d\n",
		 uke_dispcc_proxy_active);
}
