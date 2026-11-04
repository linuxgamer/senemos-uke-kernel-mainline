/* SPDX-License-Identifier: GPL-2.0-only */
/* Include after camcc-sm7675-data.h in the permanent native provider. */
#ifndef UKE_CAMCC_SM7675_POWER_H
#define UKE_CAMCC_SM7675_POWER_H

#include <linux/clk.h>
#include <linux/io.h>
#include <linux/pm_runtime.h>

#define CAM_CC_POWER_RAILS GENMASK(2, 0)

static struct {
	struct device *dev;
	struct clk *iface;
	void __iomem *base;
	struct regmap *map;
	struct regulator *supplies[3];
	resource_size_t region_start;
	resource_size_t region_size;
	bool region_owned;
	bool publication_started;
	unsigned int votes;
	unsigned int uncertain_rails;
	bool iface_on;
	int fault;
	int primary_error;
	int rollback_error;
} cam_cc_power;

static int cam_cc_power_fail(int primary, int rollback, unsigned int uncertain)
{
	cam_cc_power.primary_error = primary;
	cam_cc_power.rollback_error = rollback;
	cam_cc_power.uncertain_rails |= uncertain;
	WRITE_ONCE(cam_cc_power.fault, -EIO);
	return -EIO;
}

static int cam_cc_power_rail(unsigned int rail, bool on)
{
	struct clk_vdd_class_data vote = {
		.vdd_class = cam_cc_sm7675_regulators[rail],
	};

	return on ? clk_vote_vdd_level(&vote, VDD_MIN) :
		    clk_unvote_vdd_level(&vote, VDD_MIN);
}

static int __maybe_unused cam_cc_power_resume(struct device *dev)
{
	int rail, ret, rollback;

	if (dev_get_drvdata(dev) != &cam_cc_power || cam_cc_power.dev != dev)
		return -ENODEV;
	if (cam_cc_power.fault)
		return cam_cc_power.fault;
	if (cam_cc_power.iface_on && cam_cc_power.votes == CAM_CC_POWER_RAILS)
		return 0;
	if (cam_cc_power.iface_on || cam_cc_power.votes)
		return cam_cc_power_fail(-EUCLEAN, 0, 0);

	for (rail = 0; rail < ARRAY_SIZE(cam_cc_sm7675_regulators); rail++) {
		ret = cam_cc_power_rail(rail, true);
		if (ret)
			/* The voltage helper cannot qualify backend rollback on error. */
			return cam_cc_power_fail(ret, 0, BIT(rail));
		WRITE_ONCE(cam_cc_power.votes, cam_cc_power.votes | BIT(rail));
	}

	ret = clk_prepare_enable(cam_cc_power.iface);
	if (!ret) {
		WRITE_ONCE(cam_cc_power.iface_on, true);
		return 0;
	}

	cam_cc_power.primary_error = ret;
	for (rail--; rail >= 0; rail--) {
		rollback = cam_cc_power_rail(rail, false);
		if (rollback)
			return cam_cc_power_fail(ret, rollback, BIT(rail));
		WRITE_ONCE(cam_cc_power.votes, cam_cc_power.votes & ~BIT(rail));
	}
	return ret;
}

static int __maybe_unused cam_cc_power_suspend(struct device *dev)
{
	int rail, ret;

	if (dev_get_drvdata(dev) != &cam_cc_power || cam_cc_power.dev != dev)
		return -ENODEV;
	if (cam_cc_power.fault)
		return cam_cc_power.fault;

	/* Forced system suspend bypasses the normal runtime usage checks. */
	if (atomic_read(&dev->power.usage_count) || atomic_read(&dev->power.child_count))
		return -EBUSY;
	for (rail = 0; rail < ARRAY_SIZE(cam_cc_sm7675_gdscs); rail++)
		if (READ_ONCE(cam_cc_sm7675_gdscs[rail]->controller_pm_held))
			return -EBUSY;

	if (!cam_cc_power.iface_on && !cam_cc_power.votes)
		return 0;
	if (!cam_cc_power.iface_on || cam_cc_power.votes != CAM_CC_POWER_RAILS)
		return cam_cc_power_fail(-EUCLEAN, 0, 0);

	clk_disable_unprepare(cam_cc_power.iface);
	WRITE_ONCE(cam_cc_power.iface_on, false);
	for (rail = ARRAY_SIZE(cam_cc_sm7675_regulators) - 1; rail >= 0; rail--) {
		ret = cam_cc_power_rail(rail, false);
		if (ret)
			return cam_cc_power_fail(ret, 0, BIT(rail));
		WRITE_ONCE(cam_cc_power.votes, cam_cc_power.votes & ~BIT(rail));
	}
	return 0;
}

static int cam_cc_power_access(void *context, unsigned int reg)
{
	if (context != &cam_cc_power)
		return -EINVAL;
	if (reg > cam_cc_sm7675_regmap_config.max_register || reg % sizeof(u32))
		return -EINVAL;
	if (READ_ONCE(cam_cc_power.fault))
		return READ_ONCE(cam_cc_power.fault);
	if (!cam_cc_power.base || !READ_ONCE(cam_cc_power.iface_on) ||
	    READ_ONCE(cam_cc_power.votes) != CAM_CC_POWER_RAILS)
		return -EHOSTDOWN;
	return 0;
}

static int cam_cc_power_read(void *context, unsigned int reg, unsigned int *value)
{
	int ret;

	if (!value)
		return -EINVAL;
	ret = cam_cc_power_access(context, reg);
	if (ret)
		return ret;
	*value = readl(cam_cc_power.base + reg);
	return 0;
}

static int cam_cc_power_write(void *context, unsigned int reg, unsigned int value)
{
	int ret = cam_cc_power_access(context, reg);

	if (ret)
		return ret;
	writel(value, cam_cc_power.base + reg);
	return 0;
}

static const struct regmap_config cam_cc_power_regmap_config = {
	CAM_CC_SM7675_REGMAP_FORMAT,
	.reg_read = cam_cc_power_read,
	.reg_write = cam_cc_power_write,
};

static int cam_cc_power_init(struct device *dev, void __iomem *base, resource_size_t size)
{
	static const char * const supplies[] = { "vdd_mm", "vdd_mx", "vdd_mxc" };
	struct clk *iface;
	struct regulator *supply;
	int rail, ret;

	static_assert(ARRAY_SIZE(supplies) == ARRAY_SIZE(cam_cc_sm7675_regulators));
	if (cam_cc_power.dev || dev_get_drvdata(dev))
		return -EBUSY;
	if (IS_ERR(base))
		return PTR_ERR(base);
	if (!base || size < cam_cc_sm7675_regmap_config.max_register + sizeof(u32))
		return -EINVAL;
	ret = cam_cc_validate_voltage_data();
	if (ret)
		return ret;
	/* The owner retains these references across failed-probe devres cleanup. */
	for (rail = 0; rail < ARRAY_SIZE(supplies); rail++)
		if (cam_cc_sm7675_regulators[rail]->regulator[0])
			return -EBUSY;
	iface = clk_get(dev, "iface");
	if (IS_ERR(iface))
		return PTR_ERR(iface);
	for (rail = 0; rail < ARRAY_SIZE(supplies); rail++) {
		cam_cc_sm7675_regulators[rail]->class_name = supplies[rail];
		cam_cc_sm7675_regulators[rail]->regulator_names[0] = supplies[rail];
		/* Required supplies must fail on absence instead of accepting a dummy. */
		supply = regulator_get_optional(dev, supplies[rail]);
		if (IS_ERR(supply)) {
			ret = PTR_ERR(supply);
			while (rail--) {
				regulator_put(cam_cc_sm7675_regulators[rail]->regulator[0]);
				cam_cc_sm7675_regulators[rail]->regulator[0] = NULL;
			}
			clk_put(iface);
			return ret;
		}
		cam_cc_sm7675_regulators[rail]->regulator[0] = supply;
	}

	cam_cc_power.dev = get_device(dev);
	for (rail = 0; rail < ARRAY_SIZE(supplies); rail++)
		cam_cc_power.supplies[rail] = cam_cc_sm7675_regulators[rail]->regulator[0];
	cam_cc_power.iface = iface;
	cam_cc_power.base = base;
	dev_set_drvdata(dev, &cam_cc_power);
	return 0;
}

static const struct dev_pm_ops cam_cc_power_pm_ops = {
	RUNTIME_PM_OPS(cam_cc_power_suspend, cam_cc_power_resume, NULL)
	SYSTEM_SLEEP_PM_OPS(pm_runtime_force_suspend, pm_runtime_force_resume)
};

#endif /* UKE_CAMCC_SM7675_POWER_H */
