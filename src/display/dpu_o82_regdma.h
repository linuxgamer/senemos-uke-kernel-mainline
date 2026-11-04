/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef DPU_O82_REGDMA_H
#define DPU_O82_REGDMA_H

#include <linux/mutex.h>
#include <linux/types.h>

struct dpu_hw_ctl;
struct dpu_kms;
struct drm_gem_object;
struct drm_gpuvm;

/* One owner for the entire Cliffs REGDMA3 DB engine, including its clocks. */
struct dpu_o82_regdma {
	void __iomem *regs;
	struct mutex lock;
	/* Outer power owner always precedes the transport mutex. */
	struct mutex power_lock;
	struct dpu_kms *kms_owner;
	bool power_held;
	bool closing;
	/* Set only after the exact Uke VBIF xin7 acknowledgement. */
	bool bus_isolated;
	bool mdp_clock_owned;
	u32 pmu_clock_owned;
	u32 owned_clock_bits;
	u32 quarantined_ctl;
	/* One GEM command owner, serialized by the same transport mutex. */
	struct drm_gem_object *command_bo;
	struct drm_gpuvm *command_vm;
	void *command_data;
	u64 command_iova;
};

/* Initialize once, before any command owner or hardware submission exists. */
void dpu_o82_regdma_init(struct dpu_o82_regdma *dma, void __iomem *regs);

/*
 * The caller holds runtime power, the MDP REG_DMA clock and display modeset
 * exclusion. Both panel halves must remain stopped throughout the upload.
 * The buffer is WC/coherent or already synchronized for device access. Its
 * contents and IOMMU mapping remain pinned until this call returns AND
 * dpu_o82_regdma_can_unmap() is true. An error invalidates the entire paired
 * color state, even if reset completed. Never enable a half-programmed panel.
 * Once the GEM command owner exists, this raw interface returns EBUSY.
 */
int dpu_o82_regdma_execute(struct dpu_o82_regdma *dma, struct dpu_hw_ctl *ctl,
			 u64 iova, size_t bytes);

/* Internal command-owner entry; caller holds dma->lock and all power gates. */
int dpu_o82_regdma_execute_locked(struct dpu_o82_regdma *dma,
				 struct dpu_hw_ctl *ctl, u64 iova, size_t bytes);

/* Retry a failed stop with power and both clock gates still held. */
int dpu_o82_regdma_recover(struct dpu_o82_regdma *dma);

/* Power owner holds both gates; keep xin7 halted until every queue resets. */
int dpu_o82_regdma_reset_isolated(struct dpu_o82_regdma *dma);

/* The owner excludes new submissions while releasing buffers or detaching VM. */
bool dpu_o82_regdma_can_unmap(struct dpu_o82_regdma *dma);

#endif
