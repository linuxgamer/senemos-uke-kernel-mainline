/* SPDX-License-Identifier: GPL-2.0-only */
/* Include after camcc-sm7675-power.h; permanent built-in provider only. */
#ifndef UKE_CAMCC_SM7675_OWNER_H
#define UKE_CAMCC_SM7675_OWNER_H

#include <linux/device/driver.h>
#include <linux/ioport.h>
#include <linux/of.h>
#include <linux/string.h>

static bool cam_cc_owner_busy(void)
{
	unsigned int rail, level, domain;

	if (cam_cc_power.fault || cam_cc_power.uncertain_rails ||
	    cam_cc_power.votes || cam_cc_power.iface_on ||
	    cam_cc_power.publication_started)
		return true;
	if (atomic_read(&cam_cc_power.dev->power.usage_count) ||
	    atomic_read(&cam_cc_power.dev->power.child_count))
		return true;
	for (domain = 0; domain < ARRAY_SIZE(cam_cc_sm7675_gdscs); domain++)
		if (READ_ONCE(cam_cc_sm7675_gdscs[domain]->controller_pm_held))
			return true;
	for (rail = 0; rail < ARRAY_SIZE(cam_cc_sm7675_regulators); rail++) {
		struct clk_vdd_class *class = cam_cc_sm7675_regulators[rail];

		if (class->regulator[0] != cam_cc_power.supplies[rail])
			return true;
		for (level = 0; level < class->num_levels; level++)
			if (class->level_votes[level])
				return true;
	}
	return false;
}

/* A clean unpublished failure may unwind; every other state pins resources. */
static int cam_cc_owner_probe_failed(int error)
{
	struct device *dev = cam_cc_power.dev;
	unsigned int rail;

	if (error >= 0)
		return -EINVAL;
	if (!dev)
		return error;
	if (cam_cc_owner_busy()) {
		if (!cam_cc_power.fault)
			cam_cc_power_fail(error, 0, 0);
		return error;
	}

	if (cam_cc_power.map)
		regmap_exit(cam_cc_power.map);
	for (rail = ARRAY_SIZE(cam_cc_sm7675_regulators); rail-- > 0;) {
		regulator_put(cam_cc_power.supplies[rail]);
		cam_cc_sm7675_regulators[rail]->regulator[0] = NULL;
	}
	clk_put(cam_cc_power.iface);
	if (cam_cc_power.region_owned) {
		iounmap(cam_cc_power.base);
		release_mem_region(cam_cc_power.region_start, cam_cc_power.region_size);
	}
	if (dev_get_drvdata(dev) == &cam_cc_power)
		dev_set_drvdata(dev, NULL);
	memset(&cam_cc_power, 0, sizeof(cam_cc_power));
	put_device(dev);
	return error;
}

static struct regmap *cam_cc_owner_create(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct resource *res;
	void __iomem *base;
	struct regmap *map;
	resource_size_t size;
	int ret;

	/* No module unload, dynamic DT removal or user unbind contract is admitted. */
	if (!of_machine_is_compatible("xiaomi,uke") || !dev->of_node ||
	    of_node_check_flag(dev->of_node, OF_DYNAMIC) ||
	    dev->pm_domain || of_find_property(dev->of_node, "power-domains", NULL) ||
	    !dev->driver || dev->driver->owner || !dev->driver->suppress_bind_attrs ||
	    dev->driver->pm != &cam_cc_power_pm_ops)
		return ERR_PTR(-EINVAL);
	if (cam_cc_power.dev || dev_get_drvdata(dev))
		return ERR_PTR(-EBUSY);
	res = platform_get_resource(pdev, IORESOURCE_MEM, 0);
	if (!res || res->start != 0x0ade0000)
		return ERR_PTR(-EINVAL);
	size = resource_size(res);
	if (size < cam_cc_sm7675_regmap_config.max_register + sizeof(u32) ||
	    size > 0x20000)
		return ERR_PTR(-EINVAL);
	if (!request_mem_region(res->start, size, dev_name(dev)))
		return ERR_PTR(-EBUSY);
	base = ioremap(res->start, size);
	if (!base) {
		release_mem_region(res->start, size);
		return ERR_PTR(-ENOMEM);
	}
	ret = cam_cc_power_init(dev, base, size);
	if (ret) {
		iounmap(base);
		release_mem_region(res->start, size);
		return ERR_PTR(ret);
	}
	cam_cc_power.region_start = res->start;
	cam_cc_power.region_size = size;
	cam_cc_power.region_owned = true;
	map = regmap_init(dev, NULL, &cam_cc_power, &cam_cc_power_regmap_config);
	if (IS_ERR(map)) {
		ret = PTR_ERR(map);
		cam_cc_owner_probe_failed(ret);
		return ERR_PTR(ret);
	}
	cam_cc_power.map = map;
	return map;
}

/* Call before the first reset/clock/domain provider can become visible. */
static int cam_cc_owner_begin_publication(void)
{
	int ret = cam_cc_power_access(&cam_cc_power, 0);

	if (ret)
		return ret;
	if (cam_cc_power.publication_started)
		return -EALREADY;
	cam_cc_power.publication_started = true;
	return 0;
}

/* Unbind/shutdown must not remove power beneath retained or published users. */
static void cam_cc_owner_detach(struct device *dev)
{
	if (cam_cc_power.dev != dev)
		return;
	if (!cam_cc_power.fault)
		cam_cc_power_fail(-ESHUTDOWN, 0, 0);
}

#endif /* UKE_CAMCC_SM7675_OWNER_H */
