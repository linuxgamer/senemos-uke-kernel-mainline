/* SPDX-License-Identifier: GPL-2.0-only */
/* Cliffs MCQ uses separate OEM operation/status windows, not one donor span. */
static int ufs_qcom_uke_mcq_config_resource(struct ufs_hba *hba)
{
	struct platform_device *pdev = to_platform_device(hba->dev);
	struct ufs_qcom_host *host = ufshcd_get_variant(hba);
	struct resource *std, *ice, *sqd, *vs;
	struct resource config = { .name = "mcq", .flags = IORESOURCE_MEM };
	resource_size_t bytes;
	void __iomem *cfg_base, *sqd_base, *vs_base;
	void *group;
	int ret;

	std = platform_get_resource_byname(pdev, IORESOURCE_MEM, "std");
	ice = platform_get_resource_byname(pdev, IORESOURCE_MEM, "ice");
	sqd = platform_get_resource_byname(pdev, IORESOURCE_MEM, "mcq_sqd");
	vs = platform_get_resource_byname(pdev, IORESOURCE_MEM, "mcq_vs");
	if (!of_machine_is_compatible("qcom,sm7675") || !std || !ice || !sqd || !vs)
		return -ENODEV;
	if (std->start != 0x01d84000 || resource_size(std) != 0x3000 ||
	    ice->start != 0x01d88000 || resource_size(ice) != 0x11000 ||
	    sqd->start != 0x01da5000 || resource_size(sqd) != 0x2000 ||
	    vs->start != 0x01da4000 || resource_size(vs) != 0x10 ||
	    !hba->nr_hw_queues ||
	    hba->nr_hw_queues > resource_size(sqd) / UFS_QCOM_MCQ_STRIDE)
		return -EINVAL;

	/* QCFGPTR is in 512-byte units; bound its queue array between OEM regions. */
	config.start = std->start +
		FIELD_GET(GENMASK(23, 16), hba->mcq_capabilities) * 0x200;
	bytes = hba->nr_hw_queues * MCQ_QCFG_SIZE;
	if (config.start <= ice->end || config.start >= vs->start ||
	    bytes > vs->start - config.start)
		return -EINVAL;
	config.end = config.start + bytes - 1;
	group = devres_open_group(hba->dev, NULL, GFP_KERNEL);
	if (!group)
		return -ENOMEM;
	cfg_base = devm_ioremap_resource(hba->dev, &config);
	if (IS_ERR(cfg_base)) {
		ret = PTR_ERR(cfg_base);
		goto release;
	}
	sqd_base = devm_ioremap_resource(hba->dev, sqd);
	if (IS_ERR(sqd_base)) {
		ret = PTR_ERR(sqd_base);
		goto release;
	}
	vs_base = devm_ioremap_resource(hba->dev, vs);
	if (IS_ERR(vs_base)) {
		ret = PTR_ERR(vs_base);
		goto release;
	}
	devres_close_group(hba->dev, group);
	devres_remove_group(hba->dev, group);
	host->mcq_uke_sqd = sqd_base;
	host->mcq_uke_vs = vs_base;
	host->mcq_uke_opr_offset = sqd->start - std->start;
	hba->mcq_base = cfg_base;
	return 0;

release:
	devres_release_group(hba->dev, group);
	return ret;
}
