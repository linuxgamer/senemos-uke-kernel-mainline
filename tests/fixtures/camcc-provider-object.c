// SPDX-License-Identifier: GPL-2.0-only
/* Object fixture only: no driver registration, binding or hardware execution. */
#include "camcc-sm7675-data.h"
#include "provider/camcc-sm7675-power.h"
#include "provider/camcc-sm7675-owner.h"
#include "provider/camcc-sm7675-clocks.h"

struct regmap *uke_camcc_provider_map_check(struct platform_device *pdev);
const struct dev_pm_ops *uke_camcc_provider_pm_check(void);
const struct qcom_cc_desc *uke_camcc_provider_desc_check(void);
int uke_camcc_provider_failure_check(int error);
int uke_camcc_provider_publication_check(void);
void uke_camcc_provider_detach_check(struct device *dev);
int uke_camcc_provider_clocks_check(void);

struct regmap *uke_camcc_provider_map_check(struct platform_device *pdev)
{
	return cam_cc_owner_create(pdev);
}

int uke_camcc_provider_failure_check(int error) { return cam_cc_owner_probe_failed(error); }
int uke_camcc_provider_publication_check(void) { return cam_cc_owner_begin_publication(); }
void uke_camcc_provider_detach_check(struct device *dev) { cam_cc_owner_detach(dev); }
int uke_camcc_provider_clocks_check(void) { return cam_cc_clocks_init(); }

const struct dev_pm_ops *uke_camcc_provider_pm_check(void)
{
	return &cam_cc_power_pm_ops;
}

const struct qcom_cc_desc *uke_camcc_provider_desc_check(void)
{
	return &cam_cc_sm7675_desc;
}
