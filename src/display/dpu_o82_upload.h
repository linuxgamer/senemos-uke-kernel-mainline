/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef DPU_O82_UPLOAD_H
#define DPU_O82_UPLOAD_H

struct dpu_hw_ctl;
struct dpu_o82_color_input;
struct dpu_o82_regdma;
struct drm_device;
struct drm_gpuvm;

/*
 * The KMS caller retains its DRM device/VM and the validated profile input,
 * reserves both DSPPs and proves both panel halves stopped. Runtime power,
 * MDP REG_DMA clock and VBIF QoS are held throughout execution/recovery.
 * One fixed-size WC GEM buffer belongs to this engine and its display VM.
 * Errors invalidate the complete paired color state. No HDR admission follows
 * merely from successful command execution.
 */
int dpu_o82_upload(struct dpu_o82_regdma *dma, struct drm_device *drm,
		   struct drm_gpuvm *vm, struct dpu_hw_ctl *ctl,
		   const struct dpu_o82_color_input *input, unsigned int dspp_mask);

/*
 * Exclude new KMS submissions before release and VM teardown. Failed engine
 * stop returns EBUSY, retaining every buffer/mapping/VM reference. The caller
 * must retain the owner and all power/clock gates, then recover and retry;
 * devres cleanup or a VM reference alone cannot replace this teardown order.
 */
int dpu_o82_upload_release(struct dpu_o82_regdma *dma);

#endif
