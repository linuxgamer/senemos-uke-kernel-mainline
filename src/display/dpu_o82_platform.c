// SPDX-License-Identifier: GPL-2.0-only
/* Uke REGDMA resource admission, from exact Cliffs OEM DT and SDE mapping. */
#include <linux/errno.h>
#include <linux/err.h>
#include <linux/io.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/slab.h>

#include "dpu_kms.h"
#include "dpu_o82_platform.h"
#include "dpu_o82_regdma.h"

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
	kms->o82_regdma = dma;
	return 0;
}

int dpu_o82_platform_suspend(struct dpu_kms *kms)
{
	if (kms->o82_regdma && !dpu_o82_regdma_can_unmap(kms->o82_regdma))
		return -EBUSY;
	return 0;
}
