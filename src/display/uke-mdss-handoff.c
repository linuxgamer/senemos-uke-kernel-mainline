/* SPDX-License-Identifier: GPL-2.0-only */
/* Included after struct msm_mdss in the isolated SM7675 display tree. */
#include <linux/iopoll.h>
#include <linux/mfd/syscon.h>
#include <linux/of.h>
#include <linux/qcom-uke-display.h>
#include <linux/regmap.h>

#define UKE_DISPLAY_XINS (BIT(0) | BIT(1) | BIT(4) | BIT(5) | BIT(9) | BIT(13) | BIT(14))

static int uke_mdss_handoff(struct msm_mdss *mdss)
{
	struct device *dev = mdss->dev;
	struct device_node *node;
	struct platform_device *supplier;
	struct device_link *link;
	struct reset_control *reset;
	struct regmap *dispcc;
	void __iomem *vbif;
	u32 value, saved_halt;
	int ret;

	dev_info(dev, "Uke display boot: MDSS handoff begins\n");
	if (of_find_property(dev->of_node, "iommus", NULL))
		return dev_err_probe(dev, -EINVAL, "put display iommus on DPU child\n");
	node = of_parse_phandle(dev->of_node, "qcom,display-smmu", 0);
	if (!node)
		return -EINVAL;
	supplier = of_find_device_by_node(node);
	of_node_put(node);
	if (!supplier)
		return -EPROBE_DEFER;
	if (!supplier->dev.driver || !dev_get_drvdata(&supplier->dev)) {
		ret = -EPROBE_DEFER;
		goto put_supplier;
	}
	link = device_link_add(dev, &supplier->dev, DL_FLAG_AUTOREMOVE_CONSUMER);
	if (!link) {
		ret = -ENOMEM;
		goto put_supplier;
	}
	/* Named phandle must be the same DISPCC as resets; validated by DT tests. */
	dispcc = syscon_regmap_lookup_by_phandle(dev->of_node, "qcom,display-dispcc");
	if (IS_ERR(dispcc)) {
		ret = PTR_ERR(dispcc);
		goto put_supplier;
	}
	reset = devm_reset_control_get_exclusive(dev, NULL);
	if (IS_ERR(reset)) {
		ret = PTR_ERR(reset);
		goto put_supplier;
	}
	vbif = devm_platform_ioremap_resource_byname(to_platform_device(dev), "handoff-vbif");
	if (IS_ERR(vbif)) {
		ret = PTR_ERR(vbif);
		goto put_supplier;
	}
	/* Probe owns clocks and ICC routes before retiring ABL's translations. */
	ret = pm_runtime_resume_and_get(dev);
	if (ret < 0)
		goto put_supplier;
	/* Check actual hardware revision, not merely the selected compatible. */
	value = readl(mdss->mmio);
	if ((value >> 16) != 0xa001) {
		dev_err(dev, "unexpected SM7675 MDSS revision %#x\n", value);
		ret = -ENODEV;
		goto put_pm;
	}
	saved_halt = readl(vbif + 0x200);
	writel(saved_halt | UKE_DISPLAY_XINS, vbif + 0x200);
	ret = readl_poll_timeout(vbif + 0x204, value,
				 (value & UKE_DISPLAY_XINS) == UKE_DISPLAY_XINS,
				 100, 100000);
	if (ret) {
		/* No SMR was changed: restore the prior requests and keep firmware maps. */
		writel(saved_halt, vbif + 0x200);
		goto put_pm;
	}
	ret = reset_control_assert(reset);
	if (ret)
		goto restore_halt;
	/* Generic qcom reset ops ignore regmap errors. Verify the real bit. */
	ret = regmap_read(dispcc, 0x8000, &value);
	if (ret || !(value & BIT(0))) {
		if (!ret)
			ret = -EIO;
		goto restore_halt;
	}
	msleep(20);
	ret = qcom_uke_display_release(&supplier->dev, dev);
	if (ret) {
		/* Leave reset asserted on release failure; never resume stale DMA. */
		dev_err(dev, "display SMR handoff failed: %d; core remains reset\n", ret);
		goto put_pm;
	}
	ret = reset_control_deassert(reset);
	if (ret)
		goto put_pm;
	ret = regmap_read(dispcc, 0x8000, &value);
	if (ret || (value & BIT(0))) {
		if (!ret)
			ret = -EIO;
		goto put_pm;
	}
	/* Reset erased the old scanout. DPU children attach translated domains
	 * only after this returns; no old buffer is accessed through new tables.
	 */
	writel(saved_halt & ~UKE_DISPLAY_XINS, vbif + 0x200);
	mdss->uke_handoff_complete = true;
	dev_info(dev, "Uke display boot: MDSS handoff complete\n");
	goto put_pm;
restore_halt:
	writel(saved_halt, vbif + 0x200);
put_pm:
	pm_runtime_put_sync(dev);
put_supplier:
	put_device(&supplier->dev);
	return ret;
}
