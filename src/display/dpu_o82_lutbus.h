/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef DPU_O82_LUTBUS_H
#define DPU_O82_LUTBUS_H

#include <linux/types.h>

struct dpu_o82_color_input;

/* One broadcast upload for the two DSPPs of the stopped internal output. */
#define DPU_O82_LUTBUS_BYTES 37316U
#define DPU_O82_LUTBUS_PA_OFF_BYTES (DPU_O82_LUTBUS_BYTES + 72U)
#define DPU_O82_LUTBUS_SIXZONE_BYTES (DPU_O82_LUTBUS_BYTES + 4004U)
#define DPU_O82_LUTBUS_MEMORY_BYTES (DPU_O82_LUTBUS_PA_OFF_BYTES + 168U + 24U)
#define DPU_O82_LUTBUS_MAX_BYTES (DPU_O82_LUTBUS_SIXZONE_BYTES + 168U)

/*
 * The input belongs to a validated, retained dpu_o82_profiles firmware object.
 * The caller owns a separate WC/coherent output buffer and holds that object's
 * lifetime/exclusion. This function only encodes commands: it does not grant
 * DSPP ownership, map memory, start DMA, flush a CTL or enable an output.
 * dspp_mask uses zero-based hardware indices; only two of Cliffs' three DSPPs
 * may be selected. Managed PA appends paired enable/disable from powered
 * snapshots, with explicit active/neutral HSIC; SixZone adds its bounded
 * private payload. An explicit memory payload replaces all three region words,
 * their holds and protection in the same final PA modify; absence retains v4.
 * On error neither the
 * output nor *bytes is changed. Capacity must cover the selected stream size.
 */
int dpu_o82_lutbus_build(const struct dpu_o82_color_input *input,
			unsigned int dspp_mask, void *buffer, size_t capacity,
			size_t *bytes);

#endif
