/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Copyright (c) 2023, Qualcomm Innovation Center, Inc. All rights reserved.
 * Uke CSIPHY 2.2.1 D-PHY table, from the pinned Xiaomi camera-kernel.
 * Native programming helper; no platform match or hardware activation.
 */
#ifndef UKE_CAMSS_CSIPHY_SM7675_H
#define UKE_CAMSS_CSIPHY_SM7675_H

#include <linux/delay.h>
#include <linux/io.h>

/* Include after camss-csiphy-3ph-1-0.c for its native register-entry type. */
static const struct csiphy_lane_regs csiphy_sm7675_dphy[] = {
	{0x0E94, 0x00, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x0EA0, 0x00, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x0E90, 0x0f, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x0E98, 0x08, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x0E94, 0x07, 0xD1, CSIPHY_DEFAULT_PARAMS},
	{0x0094, 0x00, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x00A0, 0x00, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x0090, 0x0f, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x0098, 0x08, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x0094, 0x07, 0xD1, CSIPHY_DEFAULT_PARAMS},
	{0x0494, 0x00, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x04A0, 0x00, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x0490, 0x0f, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x0498, 0x08, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x0494, 0x07, 0xD1, CSIPHY_DEFAULT_PARAMS},
	{0x0894, 0x00, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x08A0, 0x00, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x0890, 0x0f, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x0898, 0x08, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x0894, 0x07, 0xD1, CSIPHY_DEFAULT_PARAMS},
	{0x0C94, 0x00, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x0CA0, 0x00, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x0C90, 0x0f, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x0C98, 0x08, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x0C94, 0x07, 0xD1, CSIPHY_DEFAULT_PARAMS},
	{0x0E30, 0x00, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x0E28, 0x04, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x0E00, 0x80, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x0E0C, 0xFF, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x0E38, 0x1F, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x0E2C, 0x01, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x0E34, 0x0F, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x0E1C, 0x0A, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x0E14, 0x60, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x0E3C, 0xB8, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x0E04, 0x0C, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x0E20, 0x00, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x0E08, 0x19, 0x00, CSIPHY_SETTLE_CNT_LOWER_BYTE},
	{0x0E10, 0x52, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x0030, 0x00, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x0000, 0x8E, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x0038, 0xFE, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x002C, 0x01, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x0034, 0x0F, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x001C, 0x0A, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x0014, 0x60, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x003C, 0xB8, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x0004, 0x0C, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x0020, 0x00, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x0008, 0x19, 0x00, CSIPHY_SETTLE_CNT_LOWER_BYTE},
	{0x0010, 0x52, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x0430, 0x00, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x0400, 0x8E, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x0438, 0xFE, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x042C, 0x01, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x0434, 0x0F, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x041C, 0x0A, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x0414, 0x60, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x043C, 0xB8, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x0404, 0x0C, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x0420, 0x00, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x0408, 0x19, 0x00, CSIPHY_SETTLE_CNT_LOWER_BYTE},
	{0x0410, 0x52, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x0830, 0x00, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x0800, 0x8E, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x0838, 0xFE, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x082C, 0x01, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x0834, 0x0F, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x081C, 0x0A, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x0814, 0x60, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x083C, 0xB8, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x0804, 0x0C, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x0820, 0x00, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x0808, 0x19, 0x00, CSIPHY_SETTLE_CNT_LOWER_BYTE},
	{0x0810, 0x52, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x0C30, 0x00, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x0C00, 0x8E, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x0C38, 0xFE, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x0C2C, 0x01, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x0C34, 0x0F, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x0C1C, 0x0A, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x0C14, 0x60, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x0C3C, 0xB8, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x0C04, 0x0C, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x0C20, 0x00, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x0C08, 0x19, 0x00, CSIPHY_SETTLE_CNT_LOWER_BYTE},
	{0x0C10, 0x52, 0x00, CSIPHY_DEFAULT_PARAMS},
	{0x0094, 0xD7, 0x00, CSIPHY_SKEW_CAL},
	{0x005C, 0x04, 0x00, CSIPHY_SKEW_CAL},
	{0x0060, 0xBD, 0x00, CSIPHY_SKEW_CAL},
	{0x0064, 0x7F, 0x00, CSIPHY_SKEW_CAL},
	{0x0494, 0xD7, 0x00, CSIPHY_SKEW_CAL},
	{0x045C, 0x04, 0x00, CSIPHY_SKEW_CAL},
	{0x0460, 0xBD, 0x00, CSIPHY_SKEW_CAL},
	{0x0464, 0x7F, 0x00, CSIPHY_SKEW_CAL},
	{0x0894, 0xD7, 0x00, CSIPHY_SKEW_CAL},
	{0x085C, 0x04, 0x00, CSIPHY_SKEW_CAL},
	{0x0860, 0xBD, 0x00, CSIPHY_SKEW_CAL},
	{0x0864, 0x7F, 0x00, CSIPHY_SKEW_CAL},
	{0x0C94, 0xD7, 0x00, CSIPHY_SKEW_CAL},
	{0x0C5C, 0x04, 0x00, CSIPHY_SKEW_CAL},
	{0x0C60, 0xBD, 0x00, CSIPHY_SKEW_CAL},
	{0x0C64, 0x7F, 0x00, CSIPHY_SKEW_CAL},
};

struct csiphy_sm7675_config {
	u8 num_lanes;
	u8 lanes[4];
	u64 link_frequency;
	u64 timer_rate;
	bool skew_calibration;
};

/* Validate all arithmetic and lane positions before the first MMIO write. */
static int csiphy_sm7675_parameters(const struct csiphy_sm7675_config *config,
				  u8 *lane_mask, u8 *settle_count)
{
	u64 ui, period, settle;
	unsigned int i;
	u8 mask = BIT(7);

	if (!config || !lane_mask || !settle_count ||
	    !config->num_lanes || config->num_lanes > ARRAY_SIZE(config->lanes) ||
	    config->timer_rate != 400000000 || !config->link_frequency ||
	    config->link_frequency > 750000000)
		return -EINVAL;
	for (i = 0; i < config->num_lanes; i++) {
		u8 bit;

		if (config->lanes[i] > 3)
			return -EINVAL;
		bit = BIT(config->lanes[i] * 2);
		if (mask & bit)
			return -EINVAL;
		mask |= bit;
	}
	/* Same D-PHY prepare equation as stable CAMSS, before its u8 cast. */
	ui = 1000000000000ULL / (2 * config->link_frequency);
	period = 1000000000000ULL / config->timer_rate;
	settle = (85000 + 6 * ui) / period;
	if (settle < 6 || settle - 6 > 255)
		return -ERANGE;
	*lane_mask = mask;
	*settle_count = settle - 6;
	return 0;
}

/* Caller must own the powered PHY, clocks, rails, IRQ and runtime reference. */
static int csiphy_sm7675_program(void __iomem *base,
				const struct csiphy_sm7675_config *config)
{
	u8 lane_mask, settle_count;
	size_t i;
	int ret;

	if (!base)
		return -EINVAL;
	ret = csiphy_sm7675_parameters(config, &lane_mask, &settle_count);
	if (ret)
		return ret;

	/* Keep reset asserted while the exact Uke mission table is programmed. */
	writel(1, base + 0x1000);
	usleep_range(1, 6);
	writel(lane_mask, base + 0x1014);
	writel(0, base + 0x1084);
	writel(0, base + 0x108c);
	usleep_range(1, 6);
	writel(0x7a, base + 0x101c);
	writel(1, base + 0x1018);
	for (i = 0; i < ARRAY_SIZE(csiphy_sm7675_dphy); i++) {
		const struct csiphy_lane_regs *entry = &csiphy_sm7675_dphy[i];
		u32 value;

		switch (entry->csiphy_param_type) {
		case CSIPHY_DEFAULT_PARAMS:
			value = entry->reg_data;
			break;
		case CSIPHY_SETTLE_CNT_LOWER_BYTE:
			value = settle_count;
			break;
		case CSIPHY_SKEW_CAL:
			/* OEM writes zero when calibration is disabled; it does not skip. */
			value = config->skew_calibration ? entry->reg_data : 0;
			break;
		default:
			/* The admitted immutable D-PHY table contains only these kinds. */
			return -EINVAL;
		}
		writel(value, base + entry->reg_addr);
		if (entry->delay_us)
			usleep_range(entry->delay_us, entry->delay_us + 5);
	}
	/* Native CAMSS does not consume PHY IRQs for frame completion. */
	for (i = 0; i < 11; i++)
		writel(0, base + 0x102c + i * 4);
	writel(2, base + 0x1000);
	return 0;
}

static void csiphy_sm7675_stop(void __iomem *base)
{
	writel(0, base + 0x1014);
	writel(1, base + 0x1000);
	usleep_range(1, 6);
	writel(0, base + 0x1084);
	writel(0, base + 0x108c);
	usleep_range(1, 6);
	writel(0, base + 0x101c);
	writel(0, base + 0x1018);
}

#endif /* UKE_CAMSS_CSIPHY_SM7675_H */
