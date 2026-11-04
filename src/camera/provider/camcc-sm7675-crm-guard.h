/* SPDX-License-Identifier: GPL-2.0-only */
/* Uke CRM mode admission for the direct-programming CAMCC implementation. */
#ifndef UKE_CAMCC_SM7675_CRM_GUARD_H
#define UKE_CAMCC_SM7675_CRM_GUARD_H

#include <linux/io.h>
#include <linux/ioport.h>
#include <linux/string.h>

/* Exact Cliffs OEM CRM base and enable register; never write either here. */
#define CAM_CC_CRM_START 0x0add7000
#define CAM_CC_CRM_SIZE 0x2000
#define CAM_CC_CRM_ENABLE 0xc
#define CAM_CC_CRM_AHB_GATE 0x13318

static struct {
	void __iomem *base;
	bool owned;
	bool checked;
	bool firmware_enabled;
} cam_cc_crm_guard;

static int cam_cc_crm_guard_map(struct platform_device *pdev)
{
	struct resource *res;

	if (cam_cc_crm_guard.owned || cam_cc_crm_guard.base)
		return -EBUSY;
	res = platform_get_resource_byname(pdev, IORESOURCE_MEM, "crm");
	if (!res || res->start != CAM_CC_CRM_START ||
	    resource_size(res) != CAM_CC_CRM_SIZE)
		return -EINVAL;
	if (!request_mem_region(res->start, resource_size(res), dev_name(&pdev->dev)))
		return -EBUSY;
	cam_cc_crm_guard.base = ioremap(res->start, resource_size(res));
	if (!cam_cc_crm_guard.base) {
		release_mem_region(res->start, resource_size(res));
		return -ENOMEM;
	}
	cam_cc_crm_guard.owned = true;
	return 0;
}

/* Call only with the controller's rails, iface and runtime-PM reference held. */
static int cam_cc_crm_guard_admit(void)
{
	unsigned int gate;
	int ret;

	if (!cam_cc_crm_guard.owned || !cam_cc_crm_guard.base || !cam_cc_power.map)
		return -ENODEV;
	ret = cam_cc_power_access(&cam_cc_power, 0);
	if (ret)
		return ret;
	ret = regmap_read(cam_cc_power.map, CAM_CC_CRM_AHB_GATE, &gate);
	if (ret)
		return ret;
	if (!(gate & BIT(0)))
		return -EHOSTDOWN;
	cam_cc_crm_guard.firmware_enabled =
		readl(cam_cc_crm_guard.base + CAM_CC_CRM_ENABLE) != 0;
	cam_cc_crm_guard.checked = true;
	/* Active CRM requires a distinct vote/LUT implementation, not SW RCG ops. */
	return cam_cc_crm_guard.firmware_enabled ? -EOPNOTSUPP : 0;
}

/* Only the unpublished, unpowered clean-failure path may release this mapping. */
static void cam_cc_crm_guard_put(void)
{
	if (!cam_cc_crm_guard.owned)
		return;
	iounmap(cam_cc_crm_guard.base);
	release_mem_region(CAM_CC_CRM_START, CAM_CC_CRM_SIZE);
	memset(&cam_cc_crm_guard, 0, sizeof(cam_cc_crm_guard));
}

#endif /* UKE_CAMCC_SM7675_CRM_GUARD_H */
