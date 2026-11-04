/* SPDX-License-Identifier: MIT */
#ifndef UKE_O82_SIXZONE_FORMAT_H
#define UKE_O82_SIXZONE_FORMAT_H

#include "uke-o82-hdr-format.h"

/* Private little-endian words followed by 384 unshifted five-component tuples. */
#define O82_SIXZONE_SAMPLES 384U
#define O82_SIXZONE_HEADER 32U
#define O82_SIXZONE_BYTES (O82_SIXZONE_HEADER + O82_SIXZONE_SAMPLES * 5U * 2U)
#define O82_PA_MODE_PRESERVE 0x1fefffffU
#define O82_PA_HOLD_PRESERVE 0x00000fffU
#define O82_PA_ENABLE 0x00100000U
#define O82_PA_SIXZONE_ENABLE 0xe0000000U
#define O82_PA_FEATURES 0xfe0100e0U

static inline unsigned int o82_sixzone_inverse(unsigned int value)
{
	unsigned int inverse = value ? 65536U / value : 0;

	return inverse > 32767U ? 32767U : inverse;
}

static inline int o82_sixzone_valid(const unsigned char *data, unsigned long length)
{
	unsigned int flags, threshold, offsets, saturation, i;

	if (!data || length != O82_SIXZONE_BYTES)
		return 0;
	flags = o82_hdr_u32(data);
	threshold = o82_hdr_u32(data + 4);
	offsets = o82_hdr_u32(data + 8);
	saturation = o82_hdr_u32(data + 16);
	if ((flags != 7 && flags != 15) || data[24] > 3 || data[25] > 3 ||
	    data[26] || data[27] || o82_hdr_u32(data + 28) != O82_SIXZONE_SAMPLES ||
	    (threshold & 255) > (threshold >> 24) ||
	    ((threshold >> 8) & 255) > ((threshold >> 16) & 255) ||
	    offsets > 65535 || (!(offsets & 255) && data[24] != 3) ||
	    (!(offsets >> 8) && data[25] != 3) ||
	    o82_hdr_u32(data + 12) != (o82_sixzone_inverse(offsets & 255) |
				     o82_sixzone_inverse(offsets >> 8) << 16) ||
	    (saturation & 255) > ((saturation >> 8) & 255) ||
	    ((saturation >> 16) & 255) + (saturation >> 24) > 255 ||
	    o82_hdr_u32(data + 20) != (o82_sixzone_inverse((saturation >> 16) & 255) |
				     o82_sixzone_inverse(saturation >> 24) << 16))
		return 0;
	for (i = 0; i < O82_SIXZONE_SAMPLES * 5; i++)
		if (o82_hdr_u16(data + O82_SIXZONE_HEADER + 2 * i) > 4095)
			return 0;
	return 1;
}

/* Match OEM disable semantics while preserving another PA feature's state. */
static inline unsigned int o82_sixzone_pa_mode(unsigned int previous,
					     const unsigned char *data)
{
	unsigned int mode = previous & ~O82_PA_SIXZONE_ENABLE;

	if (data)
		return (mode & ~O82_PA_ENABLE) | O82_PA_ENABLE |
			(o82_hdr_u32(data) & 7) << 29;
	if (!(mode & O82_PA_FEATURES))
		mode &= ~O82_PA_ENABLE;
	return mode;
}

static inline unsigned int o82_sixzone_pa_hold(unsigned int previous,
					     const unsigned char *data)
{
	return data ? (previous & O82_PA_HOLD_PRESERVE) |
		      (unsigned int)data[24] << 12 | (unsigned int)data[25] << 14 : previous;
}
#endif
