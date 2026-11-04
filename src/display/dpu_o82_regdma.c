// SPDX-License-Identifier: GPL-2.0-only
/*
 * Cliffs REGDMA3 DB transport. Register/queue contract: MiCode display-drivers
 * 44275c404a677d9d9e5230fedd1af2ef02fc7b9a, msm/sde/sde_hw_reg_dma_v1.c
 * (GPL-2.0-only). The native DPU owns GEM, power, VBIF and paired DSPP state.
 */
#include <linux/dma-mapping.h>
#include <linux/errno.h>
#include <linux/io.h>
#include <linux/iopoll.h>

#include "dpu_hw_ctl.h"
#include "dpu_o82_regdma.h"
#include "o82-regdma.h"

#define REGDMA_OPMODE 0x4
#define REGDMA_ERROR_STATUS 0x170
#define REGDMA_ERROR_CLEAR 0x1b0
#define REGDMA_ERROR_MASK (BIT(0) | BIT(1) | BIT(2) | GENMASK(19, 16))
#define REGDMA_PMU_CLOCK 0x1f0
#define REGDMA_PMU_FORCE (BIT(0) | BIT(16))
#define REGDMA_STATUS 0x44
#define REGDMA_CLEAR 0x48
#define REGDMA_RESET 0x54
#define REGDMA_DONE BIT(3)
#define CTL_REGDMA_TRIGGER 0xd4
#define REGDMA_POLL_US 10
#define REGDMA_TIMEOUT_US 2000

void dpu_o82_regdma_init(struct dpu_o82_regdma *dma, void __iomem *regs)
{
	dma->regs = regs;
	dma->owned_clock_bits = 0;
	dma->quarantined_ctl = 0;
	dma->command_bo = NULL;
	dma->command_vm = NULL;
	dma->command_data = NULL;
	dma->command_iova = 0;
	dma->kms_owner = NULL;
	dma->power_held = false;
	dma->closing = false;
	dma->bus_isolated = false;
	dma->mdp_clock_owned = false;
	dma->pmu_clock_owned = 0;
	mutex_init(&dma->lock);
	mutex_init(&dma->power_lock);
}

static void dpu_o82_regdma_restore_clock(struct dpu_o82_regdma *dma)
{
	u32 value = readl(dma->regs + REGDMA_PMU_CLOCK);

	writel(value & ~dma->owned_clock_bits, dma->regs + REGDMA_PMU_CLOCK);
	readl(dma->regs + REGDMA_PMU_CLOCK);
	dma->owned_clock_bits = 0;
}

static int dpu_o82_regdma_stop(struct dpu_o82_regdma *dma, u32 ctl)
{
	u32 value, offset = ctl * 0x1000;
	int ret;

	writel(BIT(0), dma->regs + REGDMA_OPMODE);
	writel(BIT(0), dma->regs + offset + REGDMA_RESET);
	ret = readl_poll_timeout(dma->regs + offset + REGDMA_RESET, value,
				!value, REGDMA_POLL_US, REGDMA_TIMEOUT_US);
	if (ret) {
		/* Keep both clocks, all backing memory and the attached VM alive. */
		dma->quarantined_ctl = ctl;
		return ret;
	}

	writel(REGDMA_DONE, dma->regs + offset + REGDMA_CLEAR);
	readl(dma->regs + offset + REGDMA_STATUS);
	dma->quarantined_ctl = 0;
	return 0;
}

int dpu_o82_regdma_execute_locked(struct dpu_o82_regdma *dma,
				 struct dpu_hw_ctl *ctl, u64 iova, size_t bytes)
{
	struct o82_regdma_descriptor descriptor;
	u32 value, errors = 0;
	int ret;

	if (!dma || !dma->regs || !ctl || !ctl->hw.blk_addr ||
	    !o82_regdma_make_descriptor(ctl->idx, iova, bytes, &descriptor))
		return -EINVAL;

	lockdep_assert_held(&dma->lock);
	if (dma->closing) {
		ret = -ESHUTDOWN;
		goto out;
	}
	if (dma->quarantined_ctl || dma->bus_isolated) {
		ret = -EBUSY;
		goto out;
	}

	value = readl(dma->regs + REGDMA_PMU_CLOCK);
	dma->owned_clock_bits = REGDMA_PMU_FORCE & ~value;
	writel(value | REGDMA_PMU_FORCE, dma->regs + REGDMA_PMU_CLOCK);
	if ((readl(dma->regs + REGDMA_PMU_CLOCK) & REGDMA_PMU_FORCE) !=
	    REGDMA_PMU_FORCE) {
		ret = -EIO;
		goto restore_clock;
	}

	/* Discard an old descriptor before accepting a new buffer address. */
	ret = dpu_o82_regdma_stop(dma, ctl->idx);
	if (ret)
		goto out;

	writel(REGDMA_ERROR_MASK, dma->regs + REGDMA_ERROR_CLEAR);
	if ((readl(dma->regs + REGDMA_ERROR_STATUS) & REGDMA_ERROR_MASK) ||
	    (readl(dma->regs + descriptor.offset + REGDMA_STATUS) & REGDMA_DONE)) {
		ret = -EIO;
		goto restore_clock;
	}

	/* Publish the complete LUT before the hardware can fetch its descriptor. */
	dma_wmb();
	writel(descriptor.address, dma->regs + descriptor.offset);
	writel(descriptor.command, dma->regs + descriptor.offset + 4);
	wmb();
	writel(BIT(0), ctl->hw.blk_addr + CTL_REGDMA_TRIGGER);
	ret = readl_poll_timeout(dma->regs + descriptor.offset + REGDMA_STATUS,
				value, (value & REGDMA_DONE) ||
				(readl(dma->regs + REGDMA_ERROR_STATUS) & REGDMA_ERROR_MASK),
				REGDMA_POLL_US, REGDMA_TIMEOUT_US);
	errors = readl(dma->regs + REGDMA_ERROR_STATUS) & REGDMA_ERROR_MASK;
	if (ret || errors) {
		int stop_ret = dpu_o82_regdma_stop(dma, ctl->idx);

		ret = errors ? -EIO : ret;
		if (stop_ret)
			goto out;
	} else {
		writel(REGDMA_DONE, dma->regs + descriptor.offset + REGDMA_CLEAR);
		readl(dma->regs + descriptor.offset + REGDMA_STATUS);
	}

restore_clock:
	dpu_o82_regdma_restore_clock(dma);
out:
	return ret;
}

int dpu_o82_regdma_execute(struct dpu_o82_regdma *dma, struct dpu_hw_ctl *ctl,
			 u64 iova, size_t bytes)
{
	int ret;

	if (!dma || !dma->regs)
		return -EINVAL;
	mutex_lock(&dma->lock);
	/* An owned GEM buffer excludes every unrelated raw IOVA submission. */
	ret = dma->closing ? -ESHUTDOWN :
		dma->command_bo || READ_ONCE(dma->power_held) ? -EBUSY :
		dpu_o82_regdma_execute_locked(dma, ctl, iova, bytes);
	mutex_unlock(&dma->lock);
	return ret;
}

int dpu_o82_regdma_recover(struct dpu_o82_regdma *dma)
{
	int ret = 0;

	if (!dma || !dma->regs)
		return -EINVAL;
	mutex_lock(&dma->lock);
	if (dma->quarantined_ctl) {
		ret = dpu_o82_regdma_stop(dma, dma->quarantined_ctl);
		if (!ret)
			dpu_o82_regdma_restore_clock(dma);
	}
	mutex_unlock(&dma->lock);
	return ret;
}

int dpu_o82_regdma_reset_isolated(struct dpu_o82_regdma *dma)
{
	u32 ctl;
	int ret = 0;

	if (!dma || !dma->regs)
		return -EINVAL;
	mutex_lock(&dma->lock);
	if (!dma->bus_isolated) {
		ret = -EPERM;
		goto out;
	}
	/* A previous owner may have left a stale descriptor in any DB queue. */
	for (ctl = 1; ctl <= 4; ctl++) {
		ret = dpu_o82_regdma_stop(dma, ctl);
		if (ret)
			break;
	}
out:
	mutex_unlock(&dma->lock);
	return ret;
}

bool dpu_o82_regdma_can_unmap(struct dpu_o82_regdma *dma)
{
	bool safe;

	if (!dma || !dma->regs)
		return false;
	mutex_lock(&dma->lock);
	safe = !dma->quarantined_ctl || dma->bus_isolated;
	mutex_unlock(&dma->lock);
	return safe;
}
