// SPDX-License-Identifier: GPL-2.0-only
/* Exact Uke LUTDMA clocks/QoS with native runtime-PM and command ownership. */
#include <linux/errno.h>
#include <linux/array_size.h>
#include <linux/io.h>
#include <linux/pm_runtime.h>

#include "msm_gem.h"
#include "dpu_hw_top.h"
#include "dpu_hw_vbif.h"
#include "dpu_kms.h"
#include "dpu_o82_power.h"
#include "dpu_o82_regdma.h"
#include "dpu_o82_upload.h"

#define O82_MDP_CLOCK 0x2bc
#define O82_MDP_FORCE BIT(20)
#define O82_PMU_CLOCK 0x1f0
#define O82_PMU_FORCE (BIT(0) | BIT(16))

static bool dpu_o82_power_ready(struct dpu_kms *kms)
{
	const struct dpu_clk_ctrl_reg *clock;

	if (!kms || !kms->o82_regdma || !kms->o82_regdma->regs ||
	    kms->o82_regdma->kms_owner != kms ||
	    !kms->pdev || !kms->dev || !kms->base.vm ||
	    kms->base.vm->drm != kms->dev || !to_msm_vm(kms->base.vm)->managed ||
	    !kms->hw_mdp || !kms->hw_mdp->hw.blk_addr || !kms->hw_mdp->caps ||
	    !kms->hw_mdp->ops.setup_clk_force_ctrl || !kms->hw_vbif ||
	    !kms->hw_vbif->hw.blk_addr || !kms->hw_vbif->cap ||
	    kms->hw_vbif->cap->qos_rp_remap_size != 0x40 ||
	    !kms->hw_vbif->ops.set_qos_remap)
		return false;
	clock = &kms->hw_mdp->caps->clk_ctrls[DPU_CLK_CTRL_REG_DMA];
	return clock->reg_off == O82_MDP_CLOCK && clock->bit_off == 20;
}

static int dpu_o82_power_release(struct dpu_kms *kms)
{
	struct dpu_o82_regdma *dma = kms->o82_regdma;
	u32 value;
	int ret;

	lockdep_assert_held(&dma->power_lock);
	if (!dpu_o82_regdma_can_unmap(dma))
		return -EBUSY;
	mutex_lock(&dma->lock);
	if (dma->pmu_clock_owned) {
		value = readl(dma->regs + O82_PMU_CLOCK);
		writel(value & ~dma->pmu_clock_owned, dma->regs + O82_PMU_CLOCK);
		if (readl(dma->regs + O82_PMU_CLOCK) & dma->pmu_clock_owned) {
			mutex_unlock(&dma->lock);
			return -EIO;
		}
		dma->pmu_clock_owned = 0;
	}
	mutex_unlock(&dma->lock);
	if (dma->mdp_clock_owned) {
		kms->hw_mdp->ops.setup_clk_force_ctrl(kms->hw_mdp, DPU_CLK_CTRL_REG_DMA, false);
		if (readl(kms->hw_mdp->hw.blk_addr + O82_MDP_CLOCK) & O82_MDP_FORCE)
			return -EIO;
		dma->mdp_clock_owned = false;
	}
	/* Permit the runtime callback only after all owned gates are released. */
	WRITE_ONCE(dma->power_held, false);
	ret = pm_runtime_put_sync(&kms->pdev->dev);
	if (ret < 0) {
		pm_runtime_get_noresume(&kms->pdev->dev);
		WRITE_ONCE(dma->power_held, true);
		return ret;
	}
	return 0;
}

int dpu_o82_power_upload(struct dpu_kms *kms, struct dpu_hw_ctl *ctl,
			 const struct dpu_o82_color_input *input, unsigned int dspp_mask)
{
	static const u32 priority[] = {4, 4, 4, 4, 5, 5, 5, 5};
	struct dpu_o82_regdma *dma;
	u32 value;
	unsigned int level;
	int ret, cleanup;

	if (!dpu_o82_power_ready(kms) || !input || !ctl ||
	    (dspp_mask != 3 && dspp_mask != 5 && dspp_mask != 6))
		return -EINVAL;
	dma = kms->o82_regdma;
	mutex_lock(&dma->power_lock);
	if (READ_ONCE(dma->power_held)) {
		ret = -EBUSY;
		goto out;
	}
	/* Covers forced system suspend while runtime resume is still pending. */
	WRITE_ONCE(dma->power_held, true);
	ret = pm_runtime_resume_and_get(&kms->pdev->dev);
	if (ret < 0) {
		WRITE_ONCE(dma->power_held, false);
		goto out;
	}
	dma->mdp_clock_owned = kms->hw_mdp->ops.setup_clk_force_ctrl(
		kms->hw_mdp, DPU_CLK_CTRL_REG_DMA, true);
	if (!(readl(kms->hw_mdp->hw.blk_addr + O82_MDP_CLOCK) & O82_MDP_FORCE)) {
		ret = -EIO;
		goto release;
	}
	mutex_lock(&dma->lock);
	value = readl(dma->regs + O82_PMU_CLOCK);
	dma->pmu_clock_owned = O82_PMU_FORCE & ~value;
	writel(value | O82_PMU_FORCE, dma->regs + O82_PMU_CLOCK);
	ret = (readl(dma->regs + O82_PMU_CLOCK) & O82_PMU_FORCE) == O82_PMU_FORCE ? 0 : -EIO;
	mutex_unlock(&dma->lock);
	if (ret)
		goto release;
	for (level = 0; level < ARRAY_SIZE(priority); level++) {
		if (!kms->hw_vbif->ops.set_qos_remap(kms->hw_vbif, 7, level, priority[level])) {
			ret = -EIO;
			goto release;
		}
	}
	ret = dpu_o82_upload(dma, kms->dev, kms->base.vm, ctl, input, dspp_mask);
release:
	cleanup = dpu_o82_power_release(kms);
	if (!ret)
		ret = cleanup;
out:
	mutex_unlock(&dma->power_lock);
	return ret;
}

int dpu_o82_power_recover(struct dpu_kms *kms)
{
	struct dpu_o82_regdma *dma;
	int ret = 0;

	if (!dpu_o82_power_ready(kms))
		return -EINVAL;
	dma = kms->o82_regdma;
	mutex_lock(&dma->power_lock);
	if (READ_ONCE(dma->power_held)) {
		ret = dpu_o82_regdma_recover(dma);
		if (!ret)
			ret = dpu_o82_power_release(kms);
	}
	mutex_unlock(&dma->power_lock);
	return ret;
}
