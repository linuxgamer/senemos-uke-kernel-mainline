/* SPDX-License-Identifier: MIT */
/* Provenance and integration limits: manifests/o82-memory-path-source-20261105.json. */
#ifndef UKE_O82_MEMORY_FORMAT_H
#define UKE_O82_MEMORY_FORMAT_H

#include "o82-hsic-format.h"

/* Private, little-endian semantic payload; not the drm_msm_memcol struct ABI. */
#define O82_MEMORY_VERSION 1U
#define O82_MEMORY_HEADER 16U
#define O82_MEMORY_REGIONS 3U
#define O82_MEMORY_REGION_BYTES 32U
#define O82_MEMORY_BYTES (O82_MEMORY_HEADER + O82_MEMORY_REGIONS * O82_MEMORY_REGION_BYTES)
#define O82_MEMORY_ENABLE_FLAGS 7U
#define O82_MEMORY_PROTECTION_FLAGS 63U
#define O82_PA_MEMORY_ENABLE 0x000000e0U
#define O82_PA_MEMORY_PROTECTION 0x01c60008U
#define O82_PA_MEMORY_MODE_PRESERVE 0x0029ff17U

static inline const unsigned char *o82_memory_region(const unsigned char *data,
						    unsigned int index)
{
	return data + O82_MEMORY_HEADER + index * O82_MEMORY_REGION_BYTES;
}

static inline unsigned int o82_memory_inverse(unsigned int extent)
{
	return extent >= 8 && extent <= 255 ? (131072U + extent) / (2U * extent) : 0;
}

static inline unsigned int o82_memory_bits(unsigned int value)
{
	unsigned int count = 0;

	while (value) {
		count++;
		value >>= 1;
	}
	return count;
}

/* Match round-to-nearest-even binary32 product/division, then truncate.
 * A plain integer quotient changes valid OEM blend values near an integer.
 * The admitted product is at most1536*255*255 and all shifts fit64 bits.
 */
static inline unsigned int o82_memory_blend(unsigned int hue, unsigned int sat,
					   unsigned int val)
{
	unsigned int product, count, shift, top, remainder, exponent, quotient;
	unsigned long long numerator;

	if (hue < 8 || hue > 1536 || sat < 8 || sat > 255 || val < 8 || val > 255)
		return 0;
	product = hue * sat * val;
	count = o82_memory_bits(product);
	if (count > 24) {
		shift = count - 24;
		top = product >> shift;
		remainder = product & ((1U << shift) - 1);
		if (remainder > (1U << (shift - 1)) ||
		    (remainder == (1U << (shift - 1)) && (top & 1)))
			top++;
		product = top << shift;
	}
	exponent = 32 - o82_memory_bits(product) - !!(product & (product - 1));
	numerator = 1ULL << (54 - exponent);
	quotient = numerator / product;
	remainder = numerator % product;
	if (2 * remainder > product || (2 * remainder == product && (quotient & 1)))
		quotient++;
	return quotient >> (23 - exponent);
}

static inline int o82_memory_valid(const unsigned char *data, unsigned long length)
{
	unsigned int i, j, enabled;

	if (!data || length != O82_MEMORY_BYTES ||
	    (o82_hdr_u32(data) & ~O82_MEMORY_ENABLE_FLAGS) ||
	    (o82_hdr_u32(data + 4) & ~O82_MEMORY_PROTECTION_FLAGS) ||
	    o82_hdr_u32(data + 8) != O82_MEMORY_VERSION || o82_hdr_u32(data + 12))
		return 0;
	enabled = o82_hdr_u32(data);
	for (i = 0; i < O82_MEMORY_REGIONS; i++) {
		const unsigned char *p = o82_memory_region(data, i);
		unsigned int p0, hue, ratio, sat, val, extent_s, extent_v;

		if (!(enabled & (1U << i))) {
			for (j = 0; j < O82_MEMORY_REGION_BYTES; j++)
				if (p[j])
					return 0;
			continue;
		}
		p0 = o82_hdr_u32(p);
		hue = p0 & 0x7ff;
		ratio = p0 >> 16;
		sat = o82_hdr_u32(p + 24);
		val = o82_hdr_u32(p + 28);
		extent_s = (sat >> 16) & 255;
		extent_v = (val >> 16) & 255;
		if ((p0 & 0xf800) || hue < 8 || hue > 1536 ||
		    !o82_hsic_signed_code(ratio, 16, 24576) ||
		    o82_hdr_u32(p + 16) > 15 ||
		    (o82_hdr_u32(p + 20) & 0xf800f800U) ||
		    (o82_hdr_u32(p + 20) & 0x7ff) > 1536 ||
		    (o82_hdr_u32(p + 20) >> 16) > 1536 ||
		    (sat & 0xff000000U) || (val & 0xff000000U) || extent_s < 8 || extent_v < 8 ||
		    o82_hdr_u32(p + 8) != (o82_memory_inverse(extent_s) |
					  o82_memory_inverse(extent_v) << 16) ||
		    o82_hdr_u32(p + 12) != o82_memory_blend(hue, extent_s, extent_v))
			return 0;
	}
	return 1;
}

/* One composed replacement, after validating every participating payload.
 * An absent memory payload retains the byte-exact existing v4 PA contract.
 */
static inline unsigned int o82_memory_pa_mode(unsigned int previous,
		const unsigned char *sixzone, const unsigned char *hsic,
		const unsigned char *memory)
{
	static const unsigned int region_bits[] = { 5, 7, 6 };
	static const unsigned int protection_bits[] = { 22, 23, 24, 18, 17, 3 };
	unsigned int mode, i, flags;

	if (!memory)
		return o82_pa_mode(previous, sixzone, hsic);
	mode = previous & ~(O82_PA_SIXZONE_ENABLE | O82_PA_HSIC_ENABLE |
			    O82_PA_MEMORY_ENABLE | O82_PA_MEMORY_PROTECTION);
	if (sixzone)
		mode |= (o82_hdr_u32(sixzone) & 7) << 29;
	if (hsic)
		mode |= (o82_hdr_u32(hsic) & O82_HSIC_FLAGS) << 25;
	flags = o82_hdr_u32(memory);
	for (i = 0; i < 3; i++)
		if (flags & (1U << i))
			mode |= 1U << region_bits[i];
	flags = o82_hdr_u32(memory + 4);
	for (i = 0; i < 6; i++)
		if (flags & (1U << i))
			mode |= 1U << protection_bits[i];
	if (mode & (O82_PA_FEATURES | O82_PA_MEMORY_PROTECTION))
		mode |= O82_PA_ENABLE;
	else
		mode &= ~O82_PA_ENABLE;
	return mode;
}

static inline unsigned int o82_memory_hold_preserve(const unsigned char *sixzone,
						   const unsigned char *memory)
{
	return memory ? (sixzone ? 0 : 0xf000U) : O82_PA_HOLD_PRESERVE;
}

static inline unsigned int o82_memory_pa_hold(unsigned int previous,
		const unsigned char *sixzone, const unsigned char *memory)
{
	unsigned int hold, i;

	if (!memory)
		return o82_sixzone_pa_hold(previous, sixzone);
	hold = o82_sixzone_pa_hold(previous, sixzone) &
		 o82_memory_hold_preserve(sixzone, memory);
	if (sixzone)
		hold |= (unsigned int)sixzone[24] << 12 | (unsigned int)sixzone[25] << 14;
	for (i = 0; i < 3; i++)
		hold |= o82_hdr_u32(o82_memory_region(memory, i) + 16) << (4 * i);
	return hold;
}
#endif
