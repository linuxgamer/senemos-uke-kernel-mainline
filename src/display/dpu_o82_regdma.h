/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef DPU_O82_REGDMA_H
#define DPU_O82_REGDMA_H

#include <linux/mutex.h>
#include <linux/types.h>

struct dpu_hw_ctl;

/* One owner for the entire Cliffs REGDMA3 DB engine, including its clocks. */
struct dpu_o82_regdma {
	void __iomem *regs;
	struct mutex lock;
	u32 owned_clock_bits;
	u32 quarantined_ctl;
};

void dpu_o82_regdma_init(struct dpu_o82_regdma *dma, void __iomem *regs);

/*
 * The caller holds runtime power, the MDP REG_DMA clock and display modeset
 * exclusion. Both panel halves must remain stopped throughout the upload.
 * The buffer is WC/coherent or already synchronized for device access. Its
 * contents and IOMMU mapping remain pinned until this call returns AND
 * dpu_o82_regdma_can_unmap() is true. An error invalidates the entire paired
 * color state, even if reset completed. Never enable a half-programmed panel.
 */
int dpu_o82_regdma_execute(struct dpu_o82_regdma *dma, struct dpu_hw_ctl *ctl,
			 u64 iova, size_t bytes);

/* Retry a failed stop with power and both clock gates still held. */
int dpu_o82_regdma_recover(struct dpu_o82_regdma *dma);

/* The owner excludes new submissions while releasing buffers or detaching VM. */
bool dpu_o82_regdma_can_unmap(struct dpu_o82_regdma *dma);

#endif
