/* SPDX-License-Identifier: GPL-2.0-only */
/* Native CAMSS bridge for the Uke CSIPHY 2.2.1 programming helper. */
#ifndef UKE_CAMSS_SM7675_PHY_OPS_H
#define UKE_CAMSS_SM7675_PHY_OPS_H

#include "csiphy-sm7675.h"

static u8 csiphy_sm7675_get_lane_mask(struct csiphy_lanes_cfg *lanes)
{
	u8 mask = BIT(7);
	unsigned int i;

	if (!lanes || !lanes->num_data || lanes->num_data > 4)
		return 0;
	for (i = 0; i < lanes->num_data; i++) {
		u8 bit;

		if (lanes->data[i].pos > 3)
			return 0;
		bit = BIT(lanes->data[i].pos * 2);
		if (mask & bit)
			return 0;
		mask |= bit;
	}
	return mask;
}

static int csiphy_sm7675_lanes_enable(struct csiphy_device *csiphy,
				    struct csiphy_config *cfg,
				    s64 link_frequency, u8 lane_mask)
{
	struct csiphy_sm7675_config config = {
		.link_frequency = link_frequency,
		.timer_rate = csiphy->timer_clk_rate,
	};
	unsigned int i;

	/* Only noncombo D-PHY with the admitted native lane numbering is wired. */
	if (!cfg || !cfg->csi2 || cfg->combo_mode ||
	    !cfg->csi2->lane_cfg.num_data || cfg->csi2->lane_cfg.num_data > 4 ||
	    !lane_mask || csiphy_sm7675_get_lane_mask(&cfg->csi2->lane_cfg) != lane_mask)
		return -EINVAL;
	config.num_lanes = cfg->csi2->lane_cfg.num_data;
	for (i = 0; i < config.num_lanes; i++)
		config.lanes[i] = cfg->csi2->lane_cfg.data[i].pos;
	/* Reviewed candidate tables stay below 1.5 Gbit/s; wiring/deskew needs a device test. */
	config.skew_calibration = false;
	return csiphy_sm7675_program(csiphy->base, &config);
}

static void csiphy_sm7675_lanes_disable(struct csiphy_device *csiphy,
				      struct csiphy_config *cfg)
{
	csiphy_sm7675_stop(csiphy->base);
}

static int csiphy_sm7675_init(struct csiphy_device *csiphy)
{
	struct csiphy_device_regs *regs;

	regs = devm_kzalloc(csiphy->camss->dev, sizeof(*regs), GFP_KERNEL);
	if (!regs)
		return -ENOMEM;
	regs->offset = 0x1000;
	regs->common_status_offset = 0xb0;
	regs->lane_regs = csiphy_sm7675_dphy;
	regs->lane_array_size = ARRAY_SIZE(csiphy_sm7675_dphy);
	csiphy->regs = regs;
	return 0;
}

const struct csiphy_hw_ops csiphy_ops_sm7675 = {
	.get_lane_mask = csiphy_sm7675_get_lane_mask,
	.hw_version_read = csiphy_hw_version_read,
	.reset = csiphy_reset,
	.lanes_enable = csiphy_sm7675_lanes_enable,
	.lanes_disable = csiphy_sm7675_lanes_disable,
	.isr = csiphy_isr,
	.init = csiphy_sm7675_init,
};

#endif /* UKE_CAMSS_SM7675_PHY_OPS_H */
