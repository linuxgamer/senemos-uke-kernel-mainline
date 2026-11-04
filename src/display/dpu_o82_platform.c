// SPDX-License-Identifier: GPL-2.0-only
/* Uke REGDMA resource admission, from exact Cliffs OEM DT and SDE mapping. */
#include <linux/errno.h>
#include <linux/delay.h>
#include <linux/err.h>
#include <linux/io.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/slab.h>

#include "dpu_kms.h"
#include "dpu_o82_platform.h"
#include "dpu_o82_power.h"
#include "dpu_o82_regdma.h"
#include "dpu_o82_upload.h"
#include "dpu_o82_color.h"

int dpu_o82_platform_init(struct dpu_kms *kms)
{
	struct platform_device *pdev = kms->pdev;
	struct dpu_o82_regdma *dma;
	struct resource *mdp, *regdma;
	void __iomem *regs;

	if (!of_machine_is_compatible("xiaomi,uke") ||
	    !of_machine_is_compatible("qcom,sm7675") ||
	    !of_device_is_compatible(pdev->dev.of_node, "qcom,sm7675-dpu"))
		return 0;
	if (kms->o82_regdma)
		return -EALREADY;
	mdp = platform_get_resource_byname(pdev, IORESOURCE_MEM, "mdp");
	regdma = platform_get_resource_byname(pdev, IORESOURCE_MEM, "regdma");
	if (!mdp || !regdma)
		return -ENODEV;
	if (mdp->start != 0x0ae01000 || mdp->end != 0x0ae8ffff ||
	    regdma->start != 0x0af80000 || regdma->end != 0x0af86fff)
		return -EINVAL;
	dma = devm_kzalloc(&pdev->dev, sizeof(*dma), GFP_KERNEL);
	if (!dma)
		return -ENOMEM;
	regs = devm_ioremap_resource(&pdev->dev, regdma);
	if (IS_ERR(regs))
		return PTR_ERR(regs);
	dpu_o82_regdma_init(dma, regs);
	dma->kms_owner = kms;
	kms->o82_regdma = dma;
	return dpu_o82_color_init(kms);
}

int dpu_o82_platform_suspend(struct dpu_kms *kms)
{
	if (kms->o82_regdma && !dpu_o82_regdma_can_unmap(kms->o82_regdma))
		return -EBUSY;
	if (!kms->o82_regdma)
		return 0;
	if (READ_ONCE(kms->o82_regdma->power_held))
		return -EBUSY;
	return dpu_o82_upload_release(kms->o82_regdma);
}

void dpu_o82_platform_fini(struct dpu_kms *kms)
{
	int ret;

	/* The void KMS destructor cannot refuse devres/VM destruction on return. */
	while ((ret = dpu_o82_power_close(kms))) {
		dev_err_once(&kms->pdev->dev, "REGDMA drain pending: %d\n", ret);
		msleep(20);
	}
	dpu_o82_color_fini(kms);
}
