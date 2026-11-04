/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef DPU_O82_PLATFORM_H
#define DPU_O82_PLATFORM_H

struct dpu_kms;

/* Reserve the exact Uke REGDMA resource without reading or programming it. */
int dpu_o82_platform_init(struct dpu_kms *kms);
/* Runtime clocks must remain enabled while the transport retains ownership. */
int dpu_o82_platform_suspend(struct dpu_kms *kms);

/* Wait for safe DMA drain before hardware teardown or explicit MMU detach. */
void dpu_o82_platform_fini(struct dpu_kms *kms);

#endif
