// SPDX-License-Identifier: GPL-2.0-only
/*
 * Copyright (c) 2023, Qualcomm Innovation Center, Inc. All rights reserved.
 * Catalog attribution is retained in camcc-sm7675-data.h.
 * Permanent native Uke ownership and registration integration.
 */
#include <linux/init.h>
#include <linux/sysfs.h>

#define CAM_CC_SM7675_GDSC_FLAGS \
	(POLL_CFG_GDSCR | RETAIN_FF_ENABLE | GDSC_CONTROLLER_PM)
#include "camcc-sm7675-data.h"
#include "provider/camcc-sm7675-power.h"
#include "provider/camcc-sm7675-owner.h"
#include "provider/camcc-sm7675-crm-guard.h"
#include "provider/camcc-sm7675-clocks.h"
#include "provider/camcc-sm7675-handoff.h"
#include "provider/camcc-sm7675-registration.h"

static ssize_t controller_state_show(struct device *dev,
				    struct device_attribute *attribute, char *buffer)
{
	if (READ_ONCE(cam_cc_power.fault))
		return sysfs_emit(buffer, "fault %d\n", READ_ONCE(cam_cc_power.primary_error));
	return sysfs_emit(buffer, "%s\n", cam_cc_native.synchronized ? "ready" : "handoff-pending");
}
static DEVICE_ATTR_RO(controller_state);

static ssize_t crm_mode_show(struct device *dev,
			    struct device_attribute *attribute, char *buffer)
{
	/* Cached probe observation; sysfs must not read an unpowered register. */
	if (!READ_ONCE(cam_cc_crm_guard.checked))
		return sysfs_emit(buffer, "unchecked\n");
	return sysfs_emit(buffer, "%s\n", READ_ONCE(cam_cc_crm_guard.firmware_enabled) ?
			  "firmware-enabled-refused" : "direct-programming");
}
static DEVICE_ATTR_RO(crm_mode);

static struct attribute *cam_cc_native_attrs[] = {
	&dev_attr_controller_state.attr,
	&dev_attr_crm_mode.attr,
	NULL,
};
ATTRIBUTE_GROUPS(cam_cc_native);

static void cam_cc_native_remove(struct platform_device *pdev)
{
	cam_cc_owner_detach(&pdev->dev);
}

static void cam_cc_native_shutdown(struct platform_device *pdev)
{
	cam_cc_owner_detach(&pdev->dev);
}

static const struct of_device_id cam_cc_native_match[] = {
	{ .compatible = "qcom,sm7675-camcc" },
	{ }
};
MODULE_DEVICE_TABLE(of, cam_cc_native_match);

static struct platform_driver cam_cc_native_driver = {
	.probe = cam_cc_native_probe,
	.remove = cam_cc_native_remove,
	.shutdown = cam_cc_native_shutdown,
	.driver = {
		.name = "camcc-sm7675",
		.of_match_table = cam_cc_native_match,
		.pm = &cam_cc_power_pm_ops,
		.sync_state = cam_cc_native_sync_state,
		.suppress_bind_attrs = true,
		.dev_groups = cam_cc_native_groups,
	},
};

#ifdef UKE_CAMCC_OBJECT_TEST
const struct platform_driver *uke_camcc_native_object_check(void);
const struct platform_driver *uke_camcc_native_object_check(void)
{
	/* Keep the complete descriptor and driver checked in this unlinked object. */
	if (cam_cc_sm7675_desc.num_clks != ARRAY_SIZE(cam_cc_sm7675_clocks))
		return NULL;
	return &cam_cc_native_driver;
}
#else
static int __init cam_cc_native_init(void)
{
	return platform_driver_register(&cam_cc_native_driver);
}
subsys_initcall(cam_cc_native_init);
#endif

MODULE_DESCRIPTION("SM7675 Uke native camera clock and power controller");
MODULE_LICENSE("GPL");
