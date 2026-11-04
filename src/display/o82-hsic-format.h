/* SPDX-License-Identifier: MIT */
#ifndef UKE_O82_HSIC_FORMAT_H
#define UKE_O82_HSIC_FORMAT_H

#include "o82-sixzone-format.h"

/* Explicit active or neutral HSIC: flags, four register words, reserved zero. */
#define O82_HSIC_BYTES 24U
#define O82_HSIC_FLAGS 15U
#define O82_PA_HSIC_ENABLE 0x1e000000U
#define O82_PA_FULL_MODE_PRESERVE 0x01efffffU

static inline int o82_hsic_signed_code(unsigned int value, unsigned int bits,
				     unsigned int limit)
{
	return value < (1U << bits) && (value <= limit || value >= (1U << bits) - limit);
}

static inline int o82_hsic_valid(const unsigned char *data, unsigned long length)
{
	unsigned int flags, hue, saturation, value, contrast;

	if (!data || length != O82_HSIC_BYTES)
		return 0;
	flags = o82_hdr_u32(data);
	hue = o82_hdr_u32(data + 4);
	saturation = o82_hdr_u32(data + 8);
	value = o82_hdr_u32(data + 12);
	contrast = o82_hdr_u32(data + 16);
	return (flags == 0 || flags == O82_HSIC_FLAGS) &&
		o82_hsic_signed_code(hue, 12, 768) && saturation <= 0xffff &&
		o82_hsic_signed_code(saturation & 255, 8, 65) &&
		o82_hsic_signed_code(value, 8, 65) && o82_hsic_signed_code(contrast, 8, 65) &&
		!o82_hdr_u32(data + 20) && (flags || !(hue | saturation | value | contrast));
}

/* Decide PA enable once, after composing both owned features from one snapshot. */
static inline unsigned int o82_pa_mode(unsigned int previous,
				      const unsigned char *sixzone,
				      const unsigned char *hsic)
{
	unsigned int mode = previous & ~(O82_PA_SIXZONE_ENABLE | O82_PA_HSIC_ENABLE);

	if (sixzone)
		mode |= (o82_hdr_u32(sixzone) & 7) << 29;
	if (hsic)
		mode |= (o82_hdr_u32(hsic) & O82_HSIC_FLAGS) << 25;
	if (mode & O82_PA_FEATURES)
		mode |= O82_PA_ENABLE;
	else
		mode &= ~O82_PA_ENABLE;
	return mode;
}
#endif
