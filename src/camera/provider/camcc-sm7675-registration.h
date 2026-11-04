/* SPDX-License-Identifier: GPL-2.0-only */
/* Permanent built-in provider; all registration objects have static lifetime. */
#ifndef UKE_CAMCC_SM7675_REGISTRATION_H
#define UKE_CAMCC_SM7675_REGISTRATION_H

#include <linux/of_clk.h>
#include <linux/reset-controller.h>

static struct generic_pm_domain *cam_cc_native_domains[ARRAY_SIZE(cam_cc_sm7675_gdscs)];
static struct qcom_reset_controller cam_cc_native_reset;

static struct generic_pm_domain *cam_cc_native_domain_get(const struct of_phandle_args *args,
							 void *context)
{
	struct genpd_onecell_data *data = context;

	if (READ_ONCE(cam_cc_power.fault))
		return ERR_PTR(READ_ONCE(cam_cc_power.fault));
	if (!READ_ONCE(cam_cc_native.ready))
		return ERR_PTR(-EPROBE_DEFER);
	if (args->args_count != 1 || args->args[0] >= data->num_domains)
		return ERR_PTR(-EINVAL);
	return data->domains[args->args[0]] ?: ERR_PTR(-ENOENT);
}

static struct genpd_onecell_data cam_cc_native_domain_data = {
	.domains = cam_cc_native_domains,
	.num_domains = ARRAY_SIZE(cam_cc_native_domains),
	.xlate = cam_cc_native_domain_get,
};

static struct gdsc_desc cam_cc_native_gdsc = {
	.scs = cam_cc_sm7675_gdscs,
	.num = ARRAY_SIZE(cam_cc_sm7675_gdscs),
	.permanent_data = &cam_cc_native_domain_data,
};

static struct clk_hw *cam_cc_native_clock_get(struct of_phandle_args *args, void *context)
{
	unsigned int index;

	if (context != &cam_cc_native)
		return ERR_PTR(-EINVAL);
	if (READ_ONCE(cam_cc_power.fault))
		return ERR_PTR(READ_ONCE(cam_cc_power.fault));
	if (!READ_ONCE(cam_cc_native.ready))
		return ERR_PTR(-EPROBE_DEFER);
	if (args->args_count != 1)
		return ERR_PTR(-EINVAL);
	index = args->args[0];
	if (index >= ARRAY_SIZE(cam_cc_sm7675_clocks))
		return ERR_PTR(-EINVAL);
	return cam_cc_sm7675_clocks[index] ? &cam_cc_sm7675_clocks[index]->hw : ERR_PTR(-ENOENT);
}

static int cam_cc_native_reset_write(unsigned long id, bool assert)
{
	const struct qcom_reset_map *reset = &cam_cc_sm7675_resets[id];
	u32 mask = reset->bitmask ?: BIT(reset->bit);
	u32 value;
	int ret;

	ret = regmap_update_bits(cam_cc_power.map, reset->reg, mask, assert ? mask : 0);
	if (ret)
		return ret;
	ret = regmap_read(cam_cc_power.map, reset->reg, &value);
	if (ret)
		return ret;
	return (value & mask) == (assert ? mask : 0) ? 0 : -EIO;
}

static int cam_cc_native_reset_begin(struct reset_controller_dev *rcdev, unsigned long id)
{
	if (rcdev != &cam_cc_native_reset.rcdev || id >= ARRAY_SIZE(cam_cc_sm7675_resets))
		return -EINVAL;
	if (READ_ONCE(cam_cc_power.fault))
		return READ_ONCE(cam_cc_power.fault);
	if (!READ_ONCE(cam_cc_native.ready))
		return -EPROBE_DEFER;
	return pm_runtime_resume_and_get(cam_cc_power.dev);
}

static int cam_cc_native_reset_end(int error)
{
	if (error)
		/* Unknown reset state must retain its controller PM reference. */
		return cam_cc_native_fail(error);
	pm_runtime_put(cam_cc_power.dev);
	return 0;
}

static int cam_cc_native_reset_assert(struct reset_controller_dev *rcdev, unsigned long id)
{
	int ret = cam_cc_native_reset_begin(rcdev, id);

	return ret < 0 ? ret : cam_cc_native_reset_end(cam_cc_native_reset_write(id, true));
}

static int cam_cc_native_reset_deassert(struct reset_controller_dev *rcdev, unsigned long id)
{
	int ret = cam_cc_native_reset_begin(rcdev, id);

	return ret < 0 ? ret : cam_cc_native_reset_end(cam_cc_native_reset_write(id, false));
}

static int cam_cc_native_reset_pulse(struct reset_controller_dev *rcdev, unsigned long id)
{
	int ret = cam_cc_native_reset_begin(rcdev, id);

	if (ret < 0)
		return ret;
	ret = cam_cc_native_reset_write(id, true);
	if (ret)
		return cam_cc_native_reset_end(ret);
	fsleep(cam_cc_sm7675_resets[id].udelay ?: 1);
	return cam_cc_native_reset_end(cam_cc_native_reset_write(id, false));
}

static const struct reset_control_ops cam_cc_native_reset_ops = {
	.assert = cam_cc_native_reset_assert,
	.deassert = cam_cc_native_reset_deassert,
	.reset = cam_cc_native_reset_pulse,
};

static unsigned int cam_cc_native_clock_pass(struct cam_cc_clock *clock)
{
	if (clock->native == &clk_alpha_pll_lucid_evo_ops ||
	    clock->native == &clk_alpha_pll_rivian_evo_ops)
		return 0;
	if (clock->native == &clk_alpha_pll_postdiv_lucid_ole_ops)
		return 1;
	return clock->native == &clk_rcg2_shared_ops ? 2 : 3;
}

static int cam_cc_native_register_clocks(struct device *dev)
{
	unsigned int pass;
	size_t i;
	int ret;

	/* Register parents first; no shared-RCG orphan may lose its boot CFG. */
	for (pass = 0; pass < 4; pass++) {
		for (i = 0; i < ARRAY_SIZE(cam_cc_clock_state); i++) {
			struct cam_cc_clock *clock = &cam_cc_clock_state[i];
			struct clk *hold;

			if (!clock->clock || cam_cc_native_clock_pass(clock) != pass)
				continue;
			clock->clock->regmap = cam_cc_power.map;
			ret = clk_hw_register(dev, &clock->clock->hw);
			if (ret)
				return ret;
			cam_cc_native.registered[i] = true;
			if (READ_ONCE(cam_cc_power.fault))
				return READ_ONCE(cam_cc_power.fault);
			if (!cam_cc_native.boot_rcg_on[i])
				continue;
			hold = clk_hw_get_clk(&clock->clock->hw, "boot");
			if (IS_ERR(hold))
				return PTR_ERR(hold);
			cam_cc_native.boot_rcgs[i] = hold;
			ret = clk_prepare_enable(hold);
			if (ret)
				return ret;
		}
	}
	return 0;
}

/* Keep the permanent driver bound after uncertain/partial publication. */
static int cam_cc_native_quarantine(struct device *dev, int error)
{
	cam_cc_native_fail(error);
	dev_err(dev, "camera controller fault %d; resources retained until reboot\n", error);
	return 0;
}

static int cam_cc_native_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct regmap *map;
	size_t i;
	int ret;

	if (cam_cc_sm7675_desc.num_clks != ARRAY_SIZE(cam_cc_sm7675_clocks) ||
	    cam_cc_sm7675_desc.num_gdscs != ARRAY_SIZE(cam_cc_sm7675_gdscs))
		return -EINVAL;
	if (of_find_property(dev->of_node, "protected-clocks", NULL))
		return -EINVAL;
	map = cam_cc_owner_create(pdev);
	if (IS_ERR(map))
		return PTR_ERR(map);
	ret = cam_cc_native_parents_get(dev);
	if (ret)
		goto clean_failure;
	ret = cam_cc_crm_guard_map(pdev);
	if (ret)
		goto clean_failure;
	ret = cam_cc_clocks_init();
	if (ret)
		goto clean_failure;
	ret = pm_runtime_set_suspended(dev);
	if (ret)
		goto clean_failure;
	ret = cam_cc_native_proxy_get();
	if (ret)
		return cam_cc_native_quarantine(dev, ret);
	pm_runtime_enable(dev);
	cam_cc_native.pm_enabled = true;
	ret = pm_runtime_resume_and_get(dev);
	if (ret < 0)
		return cam_cc_native_quarantine(dev, ret);
	cam_cc_native.probe_pm_held = true;
	/* OEM always-on transport gates precede any CRM register access. These
	 * gates are not the CRM-managed PLL/RCG/branch tree being admitted below.
	 */
	for (i = 0; i < ARRAY_SIZE(cam_cc_sm7675_critical_cbcrs); i++) {
		u32 value;

		ret = regmap_update_bits(map, cam_cc_sm7675_critical_cbcrs[i], BIT(0), BIT(0));
		if (!ret)
			ret = regmap_read(map, cam_cc_sm7675_critical_cbcrs[i], &value);
		if (!ret && !(value & BIT(0)))
			ret = -EIO;
		if (ret)
			return cam_cc_native_quarantine(dev, ret);
	}
	ret = cam_cc_crm_guard_admit();
	if (ret)
		return cam_cc_native_quarantine(dev, ret);
	ret = cam_cc_native_handoff_init();
	if (ret)
		return cam_cc_native_quarantine(dev, ret);
	ret = cam_cc_native_plls_configure();
	if (ret)
		return cam_cc_native_quarantine(dev, ret);
	ret = cam_cc_owner_begin_publication();
	if (ret)
		return cam_cc_native_quarantine(dev, ret);
	cam_cc_native_reset.rcdev.dev = dev;
	cam_cc_native_reset.rcdev.of_node = dev->of_node;
	cam_cc_native_reset.rcdev.ops = &cam_cc_native_reset_ops;
	cam_cc_native_reset.rcdev.nr_resets = ARRAY_SIZE(cam_cc_sm7675_resets);
	cam_cc_native_reset.regmap = map;
	cam_cc_native_reset.reset_map = cam_cc_sm7675_resets;
	ret = reset_controller_register(&cam_cc_native_reset.rcdev);
	if (ret)
		return cam_cc_native_quarantine(dev, ret);
	ret = cam_cc_native_register_clocks(dev);
	if (ret)
		return cam_cc_native_quarantine(dev, ret);
	cam_cc_native_gdsc.dev = dev;
	ret = gdsc_register(&cam_cc_native_gdsc, &cam_cc_native_reset.rcdev, map);
	if (ret)
		return cam_cc_native_quarantine(dev, ret);
	ret = of_clk_add_hw_provider(dev->of_node, cam_cc_native_clock_get, &cam_cc_native);
	if (ret)
		return cam_cc_native_quarantine(dev, ret);
	WRITE_ONCE(cam_cc_native.ready, true);
	dev_info(dev, "native camera clocks/domains ready; firmware handoff pending\n");
	return 0;

clean_failure:
	if (cam_cc_owner_busy())
		return cam_cc_native_quarantine(dev, ret);
	cam_cc_crm_guard_put();
	cam_cc_native_parents_put();
	return cam_cc_owner_probe_failed(ret);
}

static void cam_cc_native_sync_state(struct device *dev)
{
	size_t i;
	int ret;

	if (dev != cam_cc_power.dev || !cam_cc_native.ready ||
	    cam_cc_native.synchronized || READ_ONCE(cam_cc_power.fault))
		return;
	ret = clk_sync_state(dev);
	if (ret)
		/* CCF checks the whole provider before releasing any boot hold. */
		return;
	for (i = ARRAY_SIZE(cam_cc_native.boot_rcgs); i-- > 0;) {
		if (!cam_cc_native.boot_rcgs[i])
			continue;
		clk_disable_unprepare(cam_cc_native.boot_rcgs[i]);
		if (READ_ONCE(cam_cc_power.fault))
			return;
		clk_put(cam_cc_native.boot_rcgs[i]);
		cam_cc_native.boot_rcgs[i] = NULL;
	}
	/* Existing genpd stay_on protects boot-ON domains until this callback. */
	of_genpd_sync_state(dev->of_node);
	if (READ_ONCE(cam_cc_power.fault))
		return;
	ret = cam_cc_native_proxy_put();
	if (ret)
		return;
	if (cam_cc_native.probe_pm_held) {
		cam_cc_native.probe_pm_held = false;
		pm_runtime_put(dev);
	}
	cam_cc_native.synchronized = true;
}

#endif /* UKE_CAMCC_SM7675_REGISTRATION_H */
