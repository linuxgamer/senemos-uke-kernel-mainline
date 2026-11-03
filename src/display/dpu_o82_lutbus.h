/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef DPU_O82_LUTBUS_H
#define DPU_O82_LUTBUS_H

#include <linux/types.h>

struct dpu_o82_color_input;

/* One broadcast upload for the two DSPPs of the stopped internal output. */
#define DPU_O82_LUTBUS_BYTES 37316U

/*
 * The input belongs to a validated, retained dpu_o82_profiles firmware object.
 * The caller owns a separate WC/coherent output buffer and holds that object's
 * lifetime/exclusion. This function only encodes commands: it does not grant
 * DSPP ownership, map memory, start DMA, flush a CTL or enable an output.
 * dspp_mask uses zero-based hardware indices; only two of Cliffs' three DSPPs
 * may be selected. On error neither the output nor *bytes is changed.
 */
int dpu_o82_lutbus_build(const struct dpu_o82_color_input *input,
			unsigned int dspp_mask, void *buffer, size_t capacity,
			size_t *bytes);

#endif
