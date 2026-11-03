/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Experimental primary-display subset for SM7675, adapted to Linux 7.2.10.
 * Derived from Palawan's dpu_10_1_palawan.h:
 * Copyright (c) 2026, Alexandr Zubtsov
 * Source commit: 0d9f7fdf720ae9f4ecfbee4fadaf1e3b5c442e95
 * Register inventory checked against matching Uke stock DT.
 * Offsets here are relative to DPU @ ae01000, not stock MDP @ ae00000.
 * DP0 stream 0/1 uses INTF0/3, checked against the exact Uke OEM catalog.
 * The native profile activates this catalog; physical MST remains unvalidated.
 */
#ifndef _DPU_10_1_SM7675_H
#define _DPU_10_1_SM7675_H

static const struct dpu_caps sm7675_dpu_caps = {
	.max_mixer_width = DEFAULT_DPU_OUTPUT_LINE_WIDTH,
	.max_mixer_blendstages = 0xb,
	.has_src_split = true,
	.has_dim_layer = true,
	.has_idle_pc = true,
	.has_3d_merge = true,
	.max_linewidth = 5120,
	.pixel_ram_size = DEFAULT_PIXEL_RAM_SIZE,
};

static const struct dpu_ctl_cfg sm7675_ctl[] = {
	{ .name = "ctl_0", .id = CTL_0, .base = 0x15000, .len = 0x1000,
	  .intr_start = DPU_IRQ_IDX(MDP_SSPP_TOP0_INTR2, 9) },
	{ .name = "ctl_1", .id = CTL_1, .base = 0x16000, .len = 0x1000,
	  .intr_start = DPU_IRQ_IDX(MDP_SSPP_TOP0_INTR2, 10) },
	{ .name = "ctl_2", .id = CTL_2, .base = 0x17000, .len = 0x1000,
	  .intr_start = DPU_IRQ_IDX(MDP_SSPP_TOP0_INTR2, 11) },
	{ .name = "ctl_3", .id = CTL_3, .base = 0x18000, .len = 0x1000,
	  .intr_start = DPU_IRQ_IDX(MDP_SSPP_TOP0_INTR2, 12) },
};

static const struct dpu_sspp_cfg sm7675_sspp[] = {
	{ .name = "sspp_0", .id = SSPP_VIG0, .base = 0x4000, .len = 0x344,
	  .features = VIG_SDM845_MASK_SDMA, .sblk = &dpu_vig_sblk_qseed3_3_3,
	  .xin_id = 0, .type = SSPP_TYPE_VIG },
	{ .name = "sspp_1", .id = SSPP_VIG1, .base = 0x6000, .len = 0x344,
	  .features = VIG_SDM845_MASK_SDMA, .sblk = &dpu_vig_sblk_qseed3_3_3,
	  .xin_id = 4, .type = SSPP_TYPE_VIG },
	{ .name = "sspp_8", .id = SSPP_DMA0, .base = 0x24000, .len = 0x344,
	  .features = DMA_SDM845_MASK_SDMA, .sblk = &dpu_dma_sblk,
	  .xin_id = 1, .type = SSPP_TYPE_DMA },
	{ .name = "sspp_9", .id = SSPP_DMA1, .base = 0x26000, .len = 0x344,
	  .features = DMA_SDM845_MASK_SDMA, .sblk = &dpu_dma_sblk,
	  .xin_id = 5, .type = SSPP_TYPE_DMA },
	{ .name = "sspp_10", .id = SSPP_DMA2, .base = 0x28000, .len = 0x344,
	  .features = DMA_SDM845_MASK_SDMA, .sblk = &dpu_dma_sblk,
	  .xin_id = 9, .type = SSPP_TYPE_DMA },
	{ .name = "sspp_11", .id = SSPP_DMA3, .base = 0x2a000, .len = 0x344,
	  .features = DMA_SDM845_MASK_SDMA, .sblk = &dpu_dma_sblk,
	  .xin_id = 13, .type = SSPP_TYPE_DMA },
	{ .name = "sspp_12", .id = SSPP_DMA4, .base = 0x2c000, .len = 0x344,
	  .features = DMA_CURSOR_SDM845_MASK_SDMA, .sblk = &dpu_dma_sblk,
	  .xin_id = 14, .type = SSPP_TYPE_DMA },
};

static const struct dpu_lm_cfg sm7675_lm[] = {
	{ .name = "lm_0", .id = LM_0, .base = 0x44000, .len = 0x400,
	  .features = MIXER_MSM8998_MASK, .sblk = &sdm845_lm_sblk,
	  .lm_pair = LM_1, .pingpong = PINGPONG_0, .dspp = DSPP_0 },
	{ .name = "lm_1", .id = LM_1, .base = 0x45000, .len = 0x400,
	  .features = MIXER_MSM8998_MASK, .sblk = &sdm845_lm_sblk,
	  .lm_pair = LM_0, .pingpong = PINGPONG_1, .dspp = DSPP_1 },
	{ .name = "lm_2", .id = LM_2, .base = 0x46000, .len = 0x400,
	  .features = MIXER_MSM8998_MASK, .sblk = &sdm845_lm_sblk,
	  .lm_pair = LM_3, .pingpong = PINGPONG_2, .dspp = DSPP_2 },
	{ .name = "lm_3", .id = LM_3, .base = 0x47000, .len = 0x400,
	  .features = MIXER_MSM8998_MASK, .sblk = &sdm845_lm_sblk,
	  .lm_pair = LM_2, .pingpong = PINGPONG_3 },
};

static const struct dpu_dspp_cfg sm7675_dspp[] = {
	{ .name = "dspp_0", .id = DSPP_0, .base = 0x54000, .len = 0x1800,
	  .sblk = &sdm845_dspp_sblk },
	{ .name = "dspp_1", .id = DSPP_1, .base = 0x56000, .len = 0x1800,
	  .sblk = &sdm845_dspp_sblk },
	{ .name = "dspp_2", .id = DSPP_2, .base = 0x58000, .len = 0x1800,
	  .sblk = &sdm845_dspp_sblk },
};

static const struct dpu_pingpong_cfg sm7675_pp[] = {
	{ .name = "pingpong_0", .id = PINGPONG_0, .base = 0x69000, .len = 0,
	  .sblk = &sc7280_pp_sblk,
	  .merge_3d = MERGE_3D_0, .intr_done = DPU_IRQ_IDX(MDP_SSPP_TOP0_INTR, 8) },
	{ .name = "pingpong_1", .id = PINGPONG_1, .base = 0x6a000, .len = 0,
	  .sblk = &sc7280_pp_sblk,
	  .merge_3d = MERGE_3D_0, .intr_done = DPU_IRQ_IDX(MDP_SSPP_TOP0_INTR, 9) },
	{ .name = "pingpong_2", .id = PINGPONG_2, .base = 0x6b000, .len = 0,
	  .sblk = &sc7280_pp_sblk,
	  .merge_3d = MERGE_3D_1, .intr_done = DPU_IRQ_IDX(MDP_SSPP_TOP0_INTR, 10) },
	{ .name = "pingpong_3", .id = PINGPONG_3, .base = 0x6c000, .len = 0,
	  .sblk = &sc7280_pp_sblk,
	  .merge_3d = MERGE_3D_1, .intr_done = DPU_IRQ_IDX(MDP_SSPP_TOP0_INTR, 11) },
};

static const struct dpu_merge_3d_cfg sm7675_merge_3d[] = {
	{ .name = "merge_3d_0", .id = MERGE_3D_0, .base = 0x4e000, .len = 0x8 },
	{ .name = "merge_3d_1", .id = MERGE_3D_1, .base = 0x4f000, .len = 0x8 },
};

/* Include the two OEM 4HS diagnostic words in these snapshot ranges. */
static const struct dpu_dsc_sub_blks sm7675_dsc_sblk_0 = {
	.enc = {.name = "enc", .base = 0x100, .len = 0x9c},
	.ctl = {.name = "ctl", .base = 0xF00, .len = 0x18},
};

static const struct dpu_dsc_sub_blks sm7675_dsc_sblk_1 = {
	.enc = {.name = "enc", .base = 0x200, .len = 0x9c},
	.ctl = {.name = "ctl", .base = 0xF80, .len = 0x18},
};

/* Uke OEM MDSS >= 10 supports full ICH precision for > 8-bpc DSC. */
static const struct dpu_dsc_cfg sm7675_dsc[] = {
	{ .name = "dce_0_0", .id = DSC_0, .base = 0x80000, .len = 0x6,
	  .features = BIT(DPU_DSC_NATIVE_42x_EN) | BIT(DPU_DSC_FULL_ICH_PREC),
	  .sblk = &sm7675_dsc_sblk_0 },
	{ .name = "dce_0_1", .id = DSC_1, .base = 0x80000, .len = 0x6,
	  .features = BIT(DPU_DSC_NATIVE_42x_EN) | BIT(DPU_DSC_FULL_ICH_PREC),
	  .sblk = &sm7675_dsc_sblk_1 },
	{ .name = "dce_1_0", .id = DSC_2, .base = 0x81000, .len = 0x6,
	  .features = BIT(DPU_DSC_NATIVE_42x_EN) | BIT(DPU_DSC_FULL_ICH_PREC),
	  .sblk = &dsc_sblk_0 },
};

static const struct dpu_intf_cfg sm7675_intf[] = {
	/* OEM 0x35000 relative to MDP @ ae00000 becomes 0x34000 at DPU @ ae01000. */
	{ .name = "intf_0", .id = INTF_0, .base = 0x34000, .len = 0x300,
	  .type = INTF_DP,
	  .controller_id = MSM_DP_CONTROLLER_0, .prog_fetch_lines_worst_case = 24,
	  .intr_underrun = DPU_IRQ_IDX(MDP_SSPP_TOP0_INTR, 24),
	  .intr_vsync = DPU_IRQ_IDX(MDP_SSPP_TOP0_INTR, 25) },
	{ .name = "intf_1", .id = INTF_1, .base = 0x35000, .len = 0x300,
	  .type = INTF_DSI,
	  .controller_id = MSM_DSI_CONTROLLER_0, .prog_fetch_lines_worst_case = 24,
	  .intr_underrun = DPU_IRQ_IDX(MDP_SSPP_TOP0_INTR, 26),
	  .intr_vsync = DPU_IRQ_IDX(MDP_SSPP_TOP0_INTR, 27),
	  .intr_tear_rd_ptr = DPU_IRQ_IDX(MDP_INTF1_TEAR_INTR, 2) },
	{ .name = "intf_2", .id = INTF_2, .base = 0x36000, .len = 0x300,
	  .type = INTF_DSI,
	  .controller_id = MSM_DSI_CONTROLLER_1, .prog_fetch_lines_worst_case = 24,
	  .intr_underrun = DPU_IRQ_IDX(MDP_SSPP_TOP0_INTR, 28),
	  .intr_vsync = DPU_IRQ_IDX(MDP_SSPP_TOP0_INTR, 29),
	  .intr_tear_rd_ptr = DPU_IRQ_IDX(MDP_INTF2_TEAR_INTR, 2) },
	{ .name = "intf_3", .id = INTF_3, .base = 0x37000, .len = 0x300,
	  .type = INTF_DP,
	  .controller_id = MSM_DP_CONTROLLER_0, .prog_fetch_lines_worst_case = 24,
	  .intr_underrun = DPU_IRQ_IDX(MDP_SSPP_TOP0_INTR, 30),
	  .intr_vsync = DPU_IRQ_IDX(MDP_SSPP_TOP0_INTR, 31) },
};

/* Retain donor QoS tables as an explicitly unvalidated integration gate. */
static const struct dpu_perf_cfg sm7675_perf_data = {
	.max_bw_low = 23900000,
	.max_bw_high = 26500000,
	.min_core_ib = 2500000,
	.min_llcc_ib = 0,
	.min_dram_ib = 800000,
	.min_prefill_lines = 35,
	.danger_lut_tbl = { 0x3ffff, 0x3ffff, 0x0 },
	.safe_lut_tbl = { 0xfe00, 0xfe00, 0xffff },
	.qos_lut_tbl = {
		{ .nentry = ARRAY_SIZE(sc7180_qos_linear), .entries = sc7180_qos_linear },
		{ .nentry = ARRAY_SIZE(sc7180_qos_macrotile), .entries = sc7180_qos_macrotile },
		{ .nentry = ARRAY_SIZE(sc7180_qos_nrt), .entries = sc7180_qos_nrt },
	},
	.cdp_cfg = { { .rd_enable = 1, .wr_enable = 1 }, { .rd_enable = 1, .wr_enable = 0 } },
	.clk_inefficiency_factor = 105,
	.bw_inefficiency_factor = 120,
};

/* Donor and OEM SDE_HW_VER_A10 (cliffs); runtime confirmation still pending. */
static const struct dpu_mdss_version sm7675_mdss_ver = {
	.core_major_ver = 10,
	.core_minor_ver = 1,
};

const struct dpu_mdss_cfg dpu_sm7675_cfg = {
	.mdss_ver = &sm7675_mdss_ver,
	.caps = &sm7675_dpu_caps,
	.mdp = &sm8650_mdp,
	.ctl_count = ARRAY_SIZE(sm7675_ctl), .ctl = sm7675_ctl,
	.sspp_count = ARRAY_SIZE(sm7675_sspp), .sspp = sm7675_sspp,
	.mixer_count = ARRAY_SIZE(sm7675_lm), .mixer = sm7675_lm,
	.dspp_count = ARRAY_SIZE(sm7675_dspp), .dspp = sm7675_dspp,
	.pingpong_count = ARRAY_SIZE(sm7675_pp), .pingpong = sm7675_pp,
	.dsc_count = ARRAY_SIZE(sm7675_dsc), .dsc = sm7675_dsc,
	.merge_3d_count = ARRAY_SIZE(sm7675_merge_3d), .merge_3d = sm7675_merge_3d,
	.intf_count = ARRAY_SIZE(sm7675_intf), .intf = sm7675_intf,
	.vbif = &sm8650_vbif,
	.perf = &sm7675_perf_data,
};

#endif
