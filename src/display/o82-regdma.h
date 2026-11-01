/* SPDX-License-Identifier: MIT */
#ifndef UKE_O82_REGDMA_H
#define UKE_O82_REGDMA_H

/* Exact Cliffs REGDMA3.0 DB queue contract from MiCode display-drivers
 * 44275c404a677d9d9e5230fedd1af2ef02fc7b9a, msm/sde/sde_hw_reg_dma_v1.c.
 * The caller must retain the mapping until completion or a verified reset.
 */
struct o82_regdma_descriptor {
	unsigned int offset;
	unsigned int address;
	unsigned int command;
};

static inline int o82_regdma_make_descriptor(unsigned int ctl,
		unsigned long long iova, unsigned long bytes,
		struct o82_regdma_descriptor *out)
{
	if (!out || ctl < 1 || ctl > 4 || !iova || iova > 0xffffffffULL ||
	    (iova & 255) || bytes < 8 || bytes > 0x3fffU * 4 || (bytes & 3) ||
	    iova + bytes - 1 > 0xffffffffULL)
		return 0;

	/* CTL_0 is1; subtracting1 would address another hardware queue. */
	out->offset = 0x1000U * ctl;
	out->address = (unsigned int)iova;
	out->command = (1U << 24) | (1U << 22) | (bytes / 4);
	return 1;
}
#endif
