/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Copyright (c) 2015, The Linux Foundation. All rights reserved.
 * Copyright (C) 2015-2018 Linaro Ltd.
 * Native gen3 resource layout adapted from stable Linux camss.c.
 * Uke counts, supplies, loads and rates are checked against Cliffs OEM DT.
 * No board DT activation is included.
 */
#ifndef UKE_CAMSS_SM7675_DATA_H
#define UKE_CAMSS_SM7675_DATA_H

#define SM7675_CSIPHY(n) { \
	.regulators = { \
		{ .supply = "vdd-csiphy-0p9", .init_load_uA = 98480 }, \
		{ .supply = "vdd-csiphy-1p2", .init_load_uA = 17920 }, \
	}, \
	.clock = { "csiphy" #n, "csiphy" #n "_timer" }, \
	.clock_rate = { { 400000000 }, { 400000000 } }, \
	.reg = { "csiphy" #n }, \
	.interrupt = { "csiphy" #n }, \
	.csiphy = { \
		.id = n, \
		.hw_ops = &csiphy_ops_sm7675, \
		.formats = &csiphy_formats_sdm845, \
	}, \
}

static const struct camss_subdev_resources csiphy_res_sm7675[] = {
	SM7675_CSIPHY(0), SM7675_CSIPHY(1), SM7675_CSIPHY(2),
	SM7675_CSIPHY(3), SM7675_CSIPHY(4),
};
#undef SM7675_CSIPHY

#define SM7675_CSID(n) { \
	.clock = { "csid", "csiphy_rx" }, \
	.clock_rate = { { 400000000 }, { 400000000, 480000000 } }, \
	.reg = { "csid" #n }, \
	.interrupt = { "csid" #n }, \
	.csid = { \
		.parent_dev_ops = &vfe_parent_dev_ops, \
		.hw_ops = &csid_ops_gen3, \
		.formats = &csid_formats_gen2, \
	}, \
}
#define SM7675_CSID_LITE(n) { \
	.clock = { "vfe_lite_ahb", "vfe_lite_csid", "vfe_lite_cphy_rx" }, \
	.clock_rate = { { 0 }, { 400000000, 480000000 }, { 0 } }, \
	.reg = { "csid_lite" #n }, \
	.interrupt = { "csid_lite" #n }, \
	.csid = { \
		.is_lite = true, \
		.parent_dev_ops = &vfe_parent_dev_ops, \
		.hw_ops = &csid_ops_gen3, \
		.formats = &csid_formats_gen2, \
	}, \
}
static const struct camss_subdev_resources csid_res_sm7675[] = {
	SM7675_CSID(0), SM7675_CSID(1), SM7675_CSID(2),
	SM7675_CSID_LITE(0), SM7675_CSID_LITE(1),
};
#undef SM7675_CSID
#undef SM7675_CSID_LITE

#define SM7675_VFE(n) { \
	.clock = { "gcc_axi_hf", "cpas_ahb", "cpas_fast_ahb", \
		"camnoc_axi", "vfe" #n "_fast_ahb", "vfe" #n, "cpas_vfe" #n, \
		"qdss_debug_xo" }, \
	.clock_rate = { { 0 }, { 80000000 }, { 300000000, 400000000 }, \
		{ 300000000, 400000000 }, { 0 }, \
		{ 326000000, 466000000, 594000000, 675000000, 785000000 }, \
		{ 0 }, { 0 } }, \
	.reg = { "vfe" #n }, \
	.interrupt = { "vfe" #n }, \
	.vfe = { \
		.line_num = 3, \
		.has_pd = true, \
		.pd_name = "ife" #n, \
		.hw_ops = &vfe_ops_gen3, \
		.formats_rdi = &vfe_formats_rdi_845, \
		.formats_pix = &vfe_formats_pix_845, \
	}, \
}
#define SM7675_VFE_LITE(n) { \
	.clock = { "gcc_axi_hf", "cpas_ahb", "camnoc_axi", "vfe_lite_ahb", \
		"vfe_lite", "cpas_vfe_lite", "qdss_debug_xo" }, \
	.clock_rate = { { 0 }, { 80000000 }, { 300000000, 400000000 }, \
		{ 0 }, { 400000000, 480000000 }, { 0 }, { 0 } }, \
	.reg = { "vfe_lite" #n }, \
	.interrupt = { "vfe_lite" #n }, \
	.vfe = { \
		.line_num = 4, \
		.is_lite = true, \
		.hw_ops = &vfe_ops_gen3, \
		.formats_rdi = &vfe_formats_rdi_845, \
		.formats_pix = &vfe_formats_pix_845, \
	}, \
}
static const struct camss_subdev_resources vfe_res_sm7675[] = {
	SM7675_VFE(0), SM7675_VFE(1), SM7675_VFE(2),
	SM7675_VFE_LITE(0), SM7675_VFE_LITE(1),
};
#undef SM7675_VFE
#undef SM7675_VFE_LITE

static const struct resources_icc icc_res_sm7675[] = {
	{ .name = "ahb", .icc_bw_tbl = { .avg = 38400, .peak = 76800 } },
	/* Exact OEM CPAS minimum instantaneous bandwidth is 3 GB/s. */
	{ .name = "hf_mnoc", .icc_bw_tbl = { .avg = 0, .peak = 3000000 } },
};

static const struct camss_resources sm7675_resources = {
	.version = CAMSS_7675,
	.pd_name = "top",
	.csiphy_res = csiphy_res_sm7675,
	.csid_res = csid_res_sm7675,
	.csid_wrapper_res = &csid_wrapper_res_sm8550,
	.vfe_res = vfe_res_sm7675,
	.icc_res = icc_res_sm7675,
	.icc_path_num = ARRAY_SIZE(icc_res_sm7675),
	.csiphy_num = ARRAY_SIZE(csiphy_res_sm7675),
	.csid_num = ARRAY_SIZE(csid_res_sm7675),
	.vfe_num = ARRAY_SIZE(vfe_res_sm7675),
};

#endif /* UKE_CAMSS_SM7675_DATA_H */
