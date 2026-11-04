// SPDX-License-Identifier: GPL-2.0-only
/*
 * Cliffs IGC4 / gamut4.3 / GC1.8 command encoding, adapted from MiCode Uke
 * display 44275c404a677d9d9e5230fedd1af2ef02fc7b9a:
 * sde_hw_reg_dma_v1.c, sde_hw_reg_dma_v1_color_proc.c, sde_reg_dma.h.
 * Copyright (c) 2021-2023 Qualcomm Innovation Center, Inc. All rights reserved.
 * Copyright (c) 2017-2021, The Linux Foundation. All rights reserved.
 * The native color owner remains responsible for paired stop and DMA lifetime.
 */
#include <linux/errno.h>
#include "dpu_o82_profiles.h"
#include "dpu_o82_lutbus.h"
#include "o82-hsic-format.h"
#include "o82-memory-format.h"

#define O82_IGC_ENTRIES (257U * 3)
#define O82_GAMUT_ENTRIES (4913U * 3)
#define O82_GC_ENTRIES (1024U * 3)
#define O82_IGC_PAD_ENTRIES (258U * 3)
#define O82_GAMUT_PAD_ENTRIES (4916U * 3)
#define O82_REGDMA_DECODE 0x18180114U
#define O82_REGDMA_WRITE 0x10000000U
#define O82_REGDMA_MODIFY 0x20000000U
#define O82_REGDMA_INDEX 0x30000000U
#define O82_REGDMA_LUTBUS 0x60000000U

_Static_assert(DPU_O82_LUTBUS_BYTES ==
	8 + (8 + O82_IGC_PAD_ENTRIES * 2 + 12 + 8) +
	(8 + O82_GAMUT_PAD_ENTRIES * 2 + 12 + 8) + 3 * (8 + 8 + 512 * 4) + 16,
	"Cliffs LUT command stream size must include padding and workaround NOPs");
_Static_assert(DPU_O82_LUTBUS_SIXZONE_BYTES == DPU_O82_LUTBUS_BYTES +
	4 * 8 + 8 + 384 * 5 * 2 + 12 + 6 * 8 + 2 * (8 + 12 + 12),
	"PA includes four HSIC words, SixZone and individual shared mode modifies");
_Static_assert(DPU_O82_LUTBUS_MAX_BYTES == DPU_O82_LUTBUS_SIXZONE_BYTES + 3 * 7 * 8,
	"Memory adds seven broadcast register writes for each region");

struct o82_stream {
	u8 *data;
	size_t at;
};

static unsigned int o82_u16(const u8 *data)
{
	return data[0] | (unsigned int)data[1] << 8;
}

static void o82_put32(struct o82_stream *stream, unsigned int value)
{
	unsigned int i;

	for (i = 0; i < 4; i++)
		stream->data[stream->at++] = value >> (8 * i);
}

static void o82_put16(struct o82_stream *stream, unsigned int value)
{
	stream->data[stream->at++] = value;
	stream->data[stream->at++] = value >> 8;
}

static void o82_write(struct o82_stream *stream, unsigned int reg, unsigned int value)
{
	o82_put32(stream, O82_REGDMA_WRITE | reg);
	o82_put32(stream, value);
}

static void o82_modify(struct o82_stream *stream, unsigned int reg,
		       unsigned int preserve, unsigned int value)
{
	o82_put32(stream, O82_REGDMA_MODIFY | reg);
	o82_put32(stream, preserve);
	o82_put32(stream, value);
}

static bool o82_disjoint(const void *left, size_t left_bytes,
			 const void *right, size_t right_bytes)
{
	unsigned long a = (unsigned long)left, b = (unsigned long)right;

	return a < b ? b - a >= left_bytes : a - b >= right_bytes;
}

static bool o82_table(const u8 *data, unsigned int entries, unsigned int maximum)
{
	unsigned int i;

	for (i = 0; i < entries; i++)
		if (o82_u16(data + 2 * i) > maximum)
			return false;
	return true;
}

static void o82_lutbus(struct o82_stream *stream, unsigned int block,
			unsigned int transfer_words, const u8 *table,
			unsigned int entries, unsigned int padded_entries)
{
	unsigned int i;

	o82_put32(stream, O82_REGDMA_LUTBUS | block);
	o82_put32(stream, (transfer_words << 16) | (padded_entries * 2 / (transfer_words * 4)));
	for (i = 0; i < padded_entries; i++)
		o82_put16(stream, i < entries ? o82_u16(table + 2 * i) << 4 : 0);
	/* Exact OEM workaround: residual LUT data plus the next opcode exceed4 DWORDs. */
	for (i = 0; i < 3; i++)
		o82_put32(stream, 0);
}

static void o82_pa(struct o82_stream *stream,
			const struct dpu_o82_color_input *input, unsigned int mask)
{
	const u8 *data = input->sixzone;
	unsigned int i, value;

	/* Full preset replacement clears stale scalar words even in neutral mode. */
	for (i = 0; i < 4; i++)
		o82_write(stream, 0x81c + 4 * i, o82_hdr_u32(input->hsic + 4 + 4 * i));
	if (data) {
		o82_lutbus(stream, 3, 5, data + O82_SIXZONE_HEADER, 384 * 5, 384 * 5);
		for (i = 0; i < 5; i++)
			o82_write(stream, 0x908 + 4 * i, o82_hdr_u32(data + 4 + 4 * i));
		o82_write(stream, 0x920, (o82_hdr_u32(data) >> 3) & 1);
	}
	if (input->memory) {
		unsigned int region;

		for (region = 0; region < O82_MEMORY_REGIONS; region++) {
			const u8 *p = o82_memory_region(input->memory, region);

			o82_write(stream, 0x880 + 20 * region, o82_hdr_u32(p));
			o82_write(stream, 0x884 + 20 * region, o82_hdr_u32(p + 4));
			for (i = 0; i < 3; i++)
				o82_write(stream, 0x888 + 20 * region + 4 * i, o82_hdr_u32(p + 20 + 4 * i));
			o82_write(stream, 0x8bc + 8 * region, o82_hdr_u32(p + 8));
			o82_write(stream, 0x8c0 + 8 * region, o82_hdr_u32(p + 12));
		}
	}
	for (i = 0; i < 3; i++) {
		if (!(mask & (1U << i)))
			continue;
		o82_put32(stream, O82_REGDMA_DECODE);
		o82_put32(stream, (1U << i) << 17);
		if (data || input->memory) {
			unsigned int preserve = o82_memory_hold_preserve(data, input->memory);

			value = o82_memory_pa_hold(input->pa_hold[i], data, input->memory) & ~preserve;
			o82_modify(stream, 0x840, preserve, value);
		}
		value = input->memory ? O82_PA_MEMORY_MODE_PRESERVE : O82_PA_FULL_MODE_PRESERVE;
		o82_modify(stream, 0x800, value,
			o82_memory_pa_mode(input->pa_mode[i], data, input->hsic, input->memory) & ~value);
	}
}

int dpu_o82_lutbus_build(const struct dpu_o82_color_input *input,
			unsigned int dspp_mask, void *buffer, size_t capacity,
			size_t *bytes)
{
	static const unsigned int gc_channel[] = { 1, 2, 0 }; /* hardware G/B/R */
	struct o82_stream stream = { .data = buffer };
	size_t needed;
	unsigned int i, channel, value;
	const u8 *table[3];
	const unsigned int entries[] = { O82_IGC_ENTRIES, O82_GAMUT_ENTRIES, O82_GC_ENTRIES };

	if (!input || !buffer || !bytes || !input->igc || !input->gamut || !input->gc ||
	    (dspp_mask != 3 && dspp_mask != 5 && dspp_mask != 6) ||
	    input->primaries > 1 || input->dither_strength > 15)
		return -EINVAL;
	if ((input->sixzone || input->sixzone_bytes) &&
	    (!input->pa_managed || !o82_sixzone_valid(input->sixzone, input->sixzone_bytes)))
		return -EINVAL;
	if ((input->pa_managed || input->hsic || input->hsic_bytes) &&
	    (!input->pa_managed || !o82_hsic_valid(input->hsic, input->hsic_bytes)))
		return -EINVAL;
	if ((input->memory || input->memory_bytes) &&
	    (!input->pa_managed || !o82_memory_valid(input->memory, input->memory_bytes)))
		return -EINVAL;
	needed = !input->pa_managed ? DPU_O82_LUTBUS_BYTES : input->sixzone ?
		 DPU_O82_LUTBUS_SIXZONE_BYTES : DPU_O82_LUTBUS_PA_OFF_BYTES;
	if (input->memory)
		needed += 168 + (input->sixzone ? 0 : 24);
	if (capacity < needed)
		return -ENOSPC;
	table[0] = input->igc; table[1] = input->gamut; table[2] = input->gc;
	if (!o82_disjoint(buffer, needed, bytes, sizeof(*bytes)) ||
	    !o82_disjoint(buffer, needed, input, sizeof(*input)) ||
	    !o82_disjoint(bytes, sizeof(*bytes), input, sizeof(*input)))
		return -EINVAL;
	for (i = 0; i < 3; i++)
		if (!o82_disjoint(buffer, needed, table[i], 2 * entries[i]) ||
		    !o82_disjoint(bytes, sizeof(*bytes), table[i], 2 * entries[i]) ||
		    !o82_table(table[i], entries[i], i == 2 ? 1023 : 4095))
			return -EINVAL;
	if (input->sixzone && (!o82_disjoint(buffer, needed, input->sixzone, input->sixzone_bytes) ||
	    !o82_disjoint(bytes, sizeof(*bytes), input->sixzone, input->sixzone_bytes)))
		return -EINVAL;
	if (input->hsic && (!o82_disjoint(buffer, needed, input->hsic, input->hsic_bytes) ||
	    !o82_disjoint(bytes, sizeof(*bytes), input->hsic, input->hsic_bytes)))
		return -EINVAL;
	if (input->memory && (!o82_disjoint(buffer, needed, input->memory, input->memory_bytes) ||
	    !o82_disjoint(bytes, sizeof(*bytes), input->memory, input->memory_bytes)))
		return -EINVAL;
	/* IGC4's257th sample is the explicit full-scale endpoint in the OEM ABI. */
	for (channel = 0; channel < 3; channel++)
		if (o82_u16(input->igc + 2 * (256 * 3 + channel)) != 4095)
			return -EINVAL;

	/* Every rejection above occurs before the first output byte is written. */
	o82_put32(&stream, O82_REGDMA_DECODE);
	o82_put32(&stream, dspp_mask << 17);
	/* IGC4 and gamut4.3 use the ordinary DSPP selector, not IGC3.1's shared port. */
	o82_lutbus(&stream, 0, 3, input->igc, O82_IGC_ENTRIES, O82_IGC_PAD_ENTRIES);
	value = 1U << 8;
	if (input->dither_enabled)
		value |= (1U << 4) | input->dither_strength;
	o82_write(&stream, 0x1264, value);
	/* Four interleaved hardware banks hold4913 logical RGB points plus3 unused points. */
	o82_lutbus(&stream, 1, 6, input->gamut, O82_GAMUT_ENTRIES, O82_GAMUT_PAD_ENTRIES);
	o82_write(&stream, 0x1000, 1); /* mode17, map/scaling already baked into the cube */
	for (channel = 0; channel < 3; channel++) {
		o82_write(&stream, 0x17c8 + 8 * channel, 0);
		o82_put32(&stream, O82_REGDMA_INDEX | (0x17c4 + 8 * channel));
		o82_put32(&stream, 512);
		for (i = 0; i < 512; i++) {
			unsigned int even = o82_u16(input->gc + 2 * (6 * i + gc_channel[channel]));
			unsigned int odd = o82_u16(input->gc + 2 * (6 * i + 3 + gc_channel[channel]));

			o82_put32(&stream, even | odd << 16);
		}
	}
	o82_write(&stream, 0x17dc, 1); /* GC table swap */
	o82_write(&stream, 0x17c0, 1); /* GC enable; no8-bit rounding */
	if (input->pa_managed)
		o82_pa(&stream, input, dspp_mask);
	*bytes = stream.at;
	return 0;
}
