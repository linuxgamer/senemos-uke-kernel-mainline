// SPDX-License-Identifier: GPL-2.0-only
/* Exact Uke LUTDMA clocks/QoS with native runtime-PM and command ownership. */
#include <linux/errno.h>
#include <linux/array_size.h>
#include <linux/io.h>
#include <linux/iopoll.h>
#include <linux/pm_runtime.h>

#include "msm_gem.h"
#include "dpu_hw_top.h"
#include "dpu_hw_vbif.h"
#include "dpu_kms.h"
#include "dpu_hw_catalog.h"
#include "dpu_o82_power.h"
#include "dpu_o82_profiles.h"
#include "dpu_o82_regdma.h"
#include "dpu_o82_upload.h"
#include "o82-hsic-format.h"
#include "o82-memory-format.h"

#define O82_MDP_CLOCK 0x2bc
#define O82_MDP_FORCE BIT(20)
#define O82_PMU_CLOCK 0x1f0
#define O82_PMU_FORCE (BIT(0) | BIT(16))
#define O82_VBIF_HALT 0x200
#define O82_VBIF_STATUS 0x204
#define O82_XIN 7
#define O82_XIN_REQUEST BIT(O82_XIN)
/* Exact Cliffs SDE getter shifts the status right by 16, unlike upstream. */
#define O82_XIN_ACK BIT(O82_XIN + 16)

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
	    kms->hw_vbif->cap->xin_halt_timeout != 0x4000 ||
	    !kms->hw_vbif->ops.set_halt_ctrl || !kms->hw_vbif->ops.set_qos_remap)
		return false;
	clock = &kms->hw_mdp->caps->clk_ctrls[DPU_CLK_CTRL_REG_DMA];
	return clock->reg_off == O82_MDP_CLOCK && clock->bit_off == 20;
}

static int dpu_o82_power_halt(struct dpu_kms *kms)
{
	struct dpu_o82_regdma *dma = kms->o82_regdma;
	struct dpu_hw_vbif *vbif = kms->hw_vbif;
	u32 value;
	int ret;

	lockdep_assert_held(&dma->power_lock);
	vbif->ops.set_halt_ctrl(vbif, O82_XIN, true);
	if (!(readl(vbif->hw.blk_addr + O82_VBIF_HALT) & O82_XIN_REQUEST))
		return -EIO;
	ret = readl_poll_timeout(vbif->hw.blk_addr + O82_VBIF_STATUS, value,
				value & O82_XIN_ACK, 10, vbif->cap->xin_halt_timeout);
	if (ret)
		return ret;
	mutex_lock(&dma->lock);
	dma->bus_isolated = true;
	/* A failed transport reset retained its own previously-clear force bits. */
	dma->pmu_clock_owned |= dma->owned_clock_bits;
	dma->owned_clock_bits = 0;
	mutex_unlock(&dma->lock);
	return 0;
}

static int dpu_o82_power_rearm(struct dpu_kms *kms)
{
	struct dpu_o82_regdma *dma = kms->o82_regdma;
	struct dpu_hw_vbif *vbif = kms->hw_vbif;
	u32 value;
	int ret;

	lockdep_assert_held(&dma->power_lock);
	if (!dma->bus_isolated &&
	    !(readl(vbif->hw.blk_addr + O82_VBIF_HALT) & O82_XIN_REQUEST) &&
	    !(readl(vbif->hw.blk_addr + O82_VBIF_STATUS) & O82_XIN_ACK))
		return 0;
	ret = dpu_o82_power_halt(kms);
	if (ret)
		return ret;
	ret = dpu_o82_regdma_reset_isolated(dma);
	if (ret)
		return ret;
	/* Never expose a previous owner's stale IOVA by clearing halt first. */
	vbif->ops.set_halt_ctrl(vbif, O82_XIN, false);
	ret = readl_poll_timeout(vbif->hw.blk_addr + O82_VBIF_STATUS, value,
				!(value & O82_XIN_ACK), 10, vbif->cap->xin_halt_timeout);
	if (ret || (readl(vbif->hw.blk_addr + O82_VBIF_HALT) & O82_XIN_REQUEST))
		return ret ? ret : -EIO;
	mutex_lock(&dma->lock);
	dma->bus_isolated = false;
	mutex_unlock(&dma->lock);
	return 0;
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

static int dpu_o82_pa_snapshot(struct dpu_kms *kms,
			       struct dpu_o82_color_input *input, unsigned int mask)
{
	static const unsigned int bases[] = { 0x54000, 0x56000, 0x58000 };
	unsigned int i;

	if ((input->memory || input->memory_bytes) &&
	    (!input->pa_managed || !o82_memory_valid(input->memory, input->memory_bytes)))
		return -EINVAL;
	if (!input->pa_managed)
		return 0;
	if (!o82_hsic_valid(input->hsic, input->hsic_bytes))
		return -EINVAL;
	if (!kms->mmio || !kms->catalog || !kms->catalog->dspp || kms->catalog->dspp_count != 3)
		return -EINVAL;
	for (i = 0; i < 3; i++) {
		const struct dpu_dspp_cfg *cfg = &kms->catalog->dspp[i];

		if (cfg->id != DSPP_0 + i || cfg->base != bases[i] || cfg->len != 0x1800)
			return -EINVAL;
	}
	for (i = 0; i < 3; i++) {
		void __iomem *base = kms->mmio + bases[i];

		if (!(mask & BIT(i)))
			continue;
		input->pa_mode[i] = readl(base + 0x800);
		input->pa_hold[i] = readl(base + 0x840);
	}
	return 0;
}

static int dpu_o82_pa_verify(struct dpu_kms *kms,
			     const struct dpu_o82_color_input *input, unsigned int mask)
{
	unsigned int i, j;

	if (!input->pa_managed)
		return 0;
	for (i = 0; i < 3; i++) {
		void __iomem *base = kms->mmio + kms->catalog->dspp[i].base;

		if (!(mask & BIT(i)))
			continue;
		if (readl(base + 0x800) != o82_memory_pa_mode(input->pa_mode[i], input->sixzone,
							   input->hsic, input->memory) ||
		    readl(base + 0x840) != o82_memory_pa_hold(input->pa_hold[i], input->sixzone,
							   input->memory))
			return -EIO;
		for (j = 0; j < 4; j++)
			if (readl(base + 0x81c + 4 * j) != o82_hdr_u32(input->hsic + 4 + 4 * j))
				return -EIO;
		if (input->memory) {
			unsigned int region;

			for (region = 0; region < O82_MEMORY_REGIONS; region++) {
				const u8 *p = o82_memory_region(input->memory, region);

				if (readl(base + 0x880 + 20 * region) != o82_hdr_u32(p) ||
				    readl(base + 0x884 + 20 * region) != o82_hdr_u32(p + 4) ||
				    readl(base + 0x8bc + 8 * region) != o82_hdr_u32(p + 8) ||
				    readl(base + 0x8c0 + 8 * region) != o82_hdr_u32(p + 12))
					return -EIO;
				for (j = 0; j < 3; j++)
					if (readl(base + 0x888 + 20 * region + 4 * j) !=
					    o82_hdr_u32(p + 20 + 4 * j))
						return -EIO;
			}
		}
		if (!input->sixzone)
			continue;
		for (j = 0; j < 5; j++)
			if (readl(base + 0x908 + 4 * j) != o82_hdr_u32(input->sixzone + 4 + 4 * j))
				return -EIO;
		if (readl(base + 0x920) != ((o82_hdr_u32(input->sixzone) >> 3) & 1))
			return -EIO;
	}
	return 0;
}

int dpu_o82_power_upload(struct dpu_kms *kms, struct dpu_hw_ctl *ctl,
			 const struct dpu_o82_color_input *input, unsigned int dspp_mask)
{
	static const u32 priority[] = {4, 4, 4, 4, 5, 5, 5, 5};
	struct dpu_o82_regdma *dma;
	struct dpu_o82_color_input prepared;
	u32 value;
	unsigned int level;
	int ret, cleanup;

	if (!dpu_o82_power_ready(kms) || !input || !ctl ||
	    (dspp_mask != 3 && dspp_mask != 5 && dspp_mask != 6))
		return -EINVAL;
	prepared = *input;
	dma = kms->o82_regdma;
	mutex_lock(&dma->power_lock);
	if (READ_ONCE(dma->closing)) {
		ret = -ESHUTDOWN;
		goto out;
	}
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
	ret = dpu_o82_power_rearm(kms);
	if (ret)
		goto release;
	for (level = 0; level < ARRAY_SIZE(priority); level++) {
		if (!kms->hw_vbif->ops.set_qos_remap(kms->hw_vbif, 7, level, priority[level])) {
			ret = -EIO;
			goto release;
		}
	}
	ret = dpu_o82_pa_snapshot(kms, &prepared, dspp_mask);
	if (ret)
		goto release;
	ret = dpu_o82_upload(dma, kms->dev, kms->base.vm, ctl, &prepared, dspp_mask);
	if (!ret)
		ret = dpu_o82_pa_verify(kms, &prepared, dspp_mask);
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
	if (READ_ONCE(dma->closing)) {
		ret = -ESHUTDOWN;
	} else if (READ_ONCE(dma->power_held)) {
		ret = dpu_o82_regdma_recover(dma);
		if (!ret)
			ret = dpu_o82_power_release(kms);
	}
	mutex_unlock(&dma->power_lock);
	return ret;
}

int dpu_o82_power_close(struct dpu_kms *kms)
{
	struct dpu_o82_regdma *dma = kms->o82_regdma;
	int ret = 0;

	if (!dma)
		return 0;
	mutex_lock(&dma->power_lock);
	mutex_lock(&dma->lock);
	WRITE_ONCE(dma->closing, true);
	mutex_unlock(&dma->lock);
	if (!dpu_o82_regdma_can_unmap(dma)) {
		if (!READ_ONCE(dma->power_held) || !dpu_o82_power_ready(kms)) {
			ret = -EHOSTDOWN;
			goto out;
		}
		ret = dpu_o82_regdma_recover(dma);
		if (ret) {
			ret = dpu_o82_power_halt(kms);
			if (ret)
				goto out;
		}
	}
	ret = dpu_o82_upload_release(dma);
	if (!ret && READ_ONCE(dma->power_held))
		ret = dpu_o82_power_release(kms);
out:
	mutex_unlock(&dma->power_lock);
	return ret;
}
