/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef DPU_O82_POWER_H
#define DPU_O82_POWER_H

struct dpu_kms;
struct dpu_hw_ctl;
struct dpu_o82_color_input;

/*
 * The KMS atomic caller reserves both DSPPs and proves both output halves
 * stopped. This wrapper owns runtime power, MDP/REGDMA force bits and the exact
 * LUTDMA QoS setup. It preserves pre-existing force bits. Errors invalidate
 * the complete paired color state; a failed stop or cleanup retains power
 * and refuses further submissions and system-suspend clock release.
 * Managed PA reads require the exact admitted Uke DSPP catalog. The wrapper
 * owns both snapshots and post-upload control readback before dropping power.
 */
int dpu_o82_power_upload(struct dpu_kms *kms, struct dpu_hw_ctl *ctl,
			 const struct dpu_o82_color_input *input, unsigned int dspp_mask);

/* Exclude new atomic callers before recovery, memory release and VM detach. */
int dpu_o82_power_recover(struct dpu_kms *kms);

/* Permanently close admission; errors retain all resources needed for retry. */
int dpu_o82_power_close(struct dpu_kms *kms);

#endif
