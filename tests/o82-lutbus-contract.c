// SPDX-License-Identifier: GPL-2.0-only
/* Synthetic tables only. Interpret the actual encoded stream; no device I/O. */
#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include "dpu_o82_profiles.h"
#include "dpu_o82_lutbus.h"
#include "o82-hsic-format.h"

static u8 igc[257 * 3 * 2], gamut[4913 * 3 * 2], gc[1024 * 3 * 2];
_Alignas(16) static u8 storage[DPU_O82_LUTBUS_MAX_BYTES + 32], saved[sizeof(storage)];
static u8 sixzone[O82_SIXZONE_BYTES], hsic[O82_HSIC_BYTES];
static u8 *stream;
static size_t cursor, bytes;

static unsigned int word16(const u8 *p) { return p[0] | (unsigned int)p[1] << 8; }
static void set16(u8 *p, unsigned int v) { p[0] = v; p[1] = v >> 8; }
static void set32(u8 *p, unsigned int v) { for (unsigned int i = 0; i < 4; i++) p[i] = v >> (i * 8); }
static unsigned int take32(void)
{
	unsigned int v = 0;
	assert(cursor + 4 <= bytes);
	for (unsigned int i = 0; i < 4; i++) v |= (unsigned int)stream[cursor++] << (8 * i);
	return v;
}
static void expect32(unsigned int expected) { assert(take32() == expected); }
static void lut(unsigned int block, unsigned int transfers, const u8 *input,
		unsigned int elements, unsigned int padded)
{
	expect32(0x60000000 | block);
	expect32(transfers << 16 | (padded * 2 / (transfers * 4)));
	for (unsigned int i = 0; i < padded; i++) {
		assert(cursor + 2 <= bytes);
		assert(word16(stream + cursor) == (i < elements ? word16(input + 2 * i) << 4 : 0));
		cursor += 2;
	}
	/* The hardware workaround is part of the stream, including all three NOPs. */
	expect32(0); expect32(0); expect32(0);
}
static void fill(void)
{
	for (unsigned int i = 0; i < 257; i++) {
		set16(igc + 6 * i, i * 4095 / 256);
		set16(igc + 6 * i + 2, i * i * 4095 / (256 * 256));
		set16(igc + 6 * i + 4, i < 128 ? 0 : (i - 128) * 4095 / 128);
	}
	for (unsigned int i = 0; i < 4913 * 3; i++) set16(gamut + 2 * i, (i * 29) & 4095);
	for (unsigned int i = 0; i < 1024; i++) {
		set16(gc + 6 * i, i); set16(gc + 6 * i + 2, i / 2); set16(gc + 6 * i + 4, i * 3 / 4);
	}
}
static struct dpu_o82_color_input input(void)
{
	return (struct dpu_o82_color_input){ .igc = igc, .gamut = gamut, .gc = gc,
		.primaries = 1, .dither_enabled = true, .dither_strength = 9 };
}
static void refused(struct dpu_o82_color_input *in, unsigned int mask, size_t cap, int error)
{
	memset(storage, 0xa5, sizeof(storage)); memcpy(saved, storage, sizeof(storage)); bytes = 123;
	assert(dpu_o82_lutbus_build(in, mask, storage + 8, cap, &bytes) == error);
	assert(bytes == 123 && !memcmp(storage, saved, sizeof(storage)));
}
static void pa_protocol(void)
{
	set32(sixzone, 15); set32(sixzone + 4, 0xe5cc3319);
	set32(sixzone + 8, 0x160c); set32(sixzone + 12, 0x0ba21555);
	set32(sixzone + 16, 0x3a359b33); set32(sixzone + 20, 0x046904d4);
	sixzone[24] = 1; sixzone[25] = 2; set32(sixzone + 28, 384);
	for (unsigned int i = 0; i < 384 * 5; i++) set16(sixzone + 32 + 2 * i, (i * 23 + 7) % 4096);
	assert(o82_sixzone_valid(sixzone, sizeof(sixzone)));
	const unsigned int masks[] = {3,5,6};
	for (unsigned int m = 0; m < 3; m++) for (unsigned int enabled = 0; enabled < 2; enabled++)
	for (unsigned int hsic_on = 0; hsic_on < 2; hsic_on++) {
		struct dpu_o82_color_input in = input();
		in.pa_managed = true; in.sixzone = enabled ? sixzone : NULL;
		in.sixzone_bytes = enabled ? sizeof(sixzone) : 0;
		memset(hsic, 0, sizeof(hsic));
		if (hsic_on) {set32(hsic,15);set32(hsic+4,0xb3);set32(hsic+8,0x7f20);set32(hsic+12,0x20);set32(hsic+16,0xe0);}
		in.hsic = hsic; in.hsic_bytes = sizeof(hsic);
		in.pa_mode[0] = 0x24100101; in.pa_mode[1] = 0x24100121; in.pa_mode[2] = 0x08110141;
		memset(storage, 0xa5, sizeof(storage)); stream = storage + 8; bytes = 0;
		assert(!dpu_o82_lutbus_build(&in, masks[m], stream, DPU_O82_LUTBUS_MAX_BYTES, &bytes));
		assert(bytes == (enabled ? DPU_O82_LUTBUS_MAX_BYTES : DPU_O82_LUTBUS_PA_OFF_BYTES));
		cursor = DPU_O82_LUTBUS_BYTES;
		const unsigned int scalar_words[] = {0xb3,0x7f20,0x20,0xe0};
		for (unsigned int j=0;j<4;j++) {expect32(0x1000081c+4*j);expect32(hsic_on?scalar_words[j]:0);}
		if (enabled) {
			lut(3, 5, sixzone + 32, 384 * 5, 384 * 5);
			const unsigned int values[] = {0xe5cc3319,0x160c,0x0ba21555,0x3a359b33,0x046904d4};
			for (unsigned int j = 0; j < 5; j++) { expect32(0x10000908 + 4 * j); expect32(values[j]); }
			expect32(0x10000920); expect32(1);
		}
		for (unsigned int i = 0; i < 3; i++) {
			if (!(masks[m] & (1U << i))) continue;
			expect32(0x18180114); expect32((1U << i) << 17);
			if (enabled) { expect32(0x20000840); expect32(0xfff); expect32(0x9000); }
			expect32(0x20000800); expect32(0x01efffff);
			const unsigned int owned=(enabled?0xe0000000:0)|(hsic_on?0x1e000000:0);
			expect32(owned|((owned||i)?0x100000:0));
		}
		assert(cursor == bytes);
		for (unsigned int i = 0; i < 8; i++) assert(storage[i] == 0xa5);
		for (size_t i = bytes + 8; i < sizeof(storage); i++) assert(storage[i] == 0xa5);
	}
	struct dpu_o82_color_input in = input(); in.pa_managed = true;
	in.sixzone = sixzone; in.sixzone_bytes = sizeof(sixzone);
	in.hsic = hsic; in.hsic_bytes = sizeof(hsic);
	refused(&in, 3, DPU_O82_LUTBUS_MAX_BYTES - 1, -ENOSPC);
	in.hsic_bytes--; refused(&in, 3, DPU_O82_LUTBUS_MAX_BYTES, -EINVAL); in.hsic_bytes++;
	in.hsic = NULL; refused(&in, 3, DPU_O82_LUTBUS_MAX_BYTES, -EINVAL); in.hsic = hsic;
	set32(hsic, 1); refused(&in, 3, DPU_O82_LUTBUS_MAX_BYTES, -EINVAL); set32(hsic,15);
	in.sixzone_bytes--; refused(&in, 3, DPU_O82_LUTBUS_MAX_BYTES, -EINVAL); in.sixzone_bytes++;
	in.pa_managed = false; refused(&in, 3, DPU_O82_LUTBUS_MAX_BYTES, -EINVAL); in.pa_managed = true;
	sixzone[26] = 1; refused(&in, 3, DPU_O82_LUTBUS_MAX_BYTES, -EINVAL); sixzone[26] = 0;
	set16(sixzone + 32, 4096); refused(&in, 3, DPU_O82_LUTBUS_MAX_BYTES, -EINVAL);
	set16(sixzone + 32, 7);
	memset(storage, 0xa5, sizeof(storage)); memcpy(storage + 8, sixzone, sizeof(sixzone));
	memcpy(saved, storage, sizeof(storage)); in.sixzone = storage + 8; bytes = 123;
	assert(dpu_o82_lutbus_build(&in, 3, storage + 8, DPU_O82_LUTBUS_MAX_BYTES, &bytes) == -EINVAL);
	assert(bytes == 123 && !memcmp(saved, storage, sizeof(storage)));
	in.sixzone = sixzone;
	memset(storage, 0xa5, sizeof(storage)); memcpy(storage + 8, hsic, sizeof(hsic));
	memcpy(saved, storage, sizeof(storage)); in.hsic = storage + 8; bytes = 123;
	assert(dpu_o82_lutbus_build(&in, 3, storage + 8, DPU_O82_LUTBUS_MAX_BYTES, &bytes) == -EINVAL);
	assert(bytes == 123 && !memcmp(saved, storage, sizeof(storage)));
	puts("Actual composed HSIC/SixZone LUTBUS: five components,192 transfers, exact controls, per-DSPP PA preservation, disable and refusal-before-write passed; no hardware operation");
}
int main(void)
{
	fill();
	const unsigned int masks[] = { 3, 5, 6 }, channels[] = { 1, 2, 0 };
	for (unsigned int m = 0; m < 3; m++) for (unsigned int dither = 0; dither < 2; dither++) {
		struct dpu_o82_color_input in = input();
		in.primaries = m % 2; in.dither_enabled = dither; in.dither_strength = 15;
		memset(storage, 0xa5, sizeof(storage)); stream = storage + 8; bytes = 0; cursor = 0;
		assert(!dpu_o82_lutbus_build(&in, masks[m], stream, DPU_O82_LUTBUS_BYTES, &bytes));
		assert(bytes == DPU_O82_LUTBUS_BYTES);
		for (unsigned int i = 0; i < 8; i++) assert(storage[i] == 0xa5);
		for (size_t i = bytes + 8; i < sizeof(storage); i++) assert(storage[i] == 0xa5);
		expect32(0x18180114); expect32(masks[m] << 17);
		lut(0, 3, igc, 257 * 3, 258 * 3);
		expect32(0x10001264); expect32(dither ? 0x11f : 0x100);
		lut(1, 6, gamut, 4913 * 3, 4916 * 3);
		expect32(0x10001000); expect32(1);
		for (unsigned int channel = 0; channel < 3; channel++) {
			expect32(0x100017c8 + 8 * channel); expect32(0);
			expect32(0x300017c4 + 8 * channel); expect32(512);
			for (unsigned int i = 0; i < 512; i++) {
				unsigned int pair = take32();
				assert((pair & 0xffff) == word16(gc + 2 * (6 * i + channels[channel])));
				assert((pair >> 16) == word16(gc + 2 * (6 * i + 3 + channels[channel])));
			}
		}
		expect32(0x100017dc); expect32(1); expect32(0x100017c0); expect32(1);
		assert(cursor == bytes);
	}
	struct dpu_o82_color_input in = input();
	refused(NULL, 3, DPU_O82_LUTBUS_BYTES, -EINVAL);
	const unsigned int bad_masks[] = { 0, 1, 2, 4, 7, 8, ~0U };
	for (unsigned int i = 0; i < sizeof(bad_masks) / sizeof(*bad_masks); i++)
		refused(&in, bad_masks[i], DPU_O82_LUTBUS_BYTES, -EINVAL);
	refused(&in, 3, DPU_O82_LUTBUS_BYTES - 1, -ENOSPC);
	in.primaries = 2; refused(&in, 3, DPU_O82_LUTBUS_BYTES, -EINVAL);
	in = input(); in.dither_strength = 16; refused(&in, 3, DPU_O82_LUTBUS_BYTES, -EINVAL);
	in = input(); in.igc = NULL; refused(&in, 3, DPU_O82_LUTBUS_BYTES, -EINVAL);
	in = input(); in.gamut = NULL; refused(&in, 3, DPU_O82_LUTBUS_BYTES, -EINVAL);
	in = input(); in.gc = NULL; refused(&in, 3, DPU_O82_LUTBUS_BYTES, -EINVAL);
	in = input();
	for (unsigned int which = 0; which < 3; which++) {
		u8 *p = which == 0 ? igc : which == 1 ? gamut : gc;
		unsigned int old = word16(p + 14);
		set16(p + 14, which == 2 ? 1024 : 4096);
		refused(&in, 3, DPU_O82_LUTBUS_BYTES, -EINVAL); set16(p + 14, old);
	}
	set16(igc + sizeof(igc) - 2, 4094);
	refused(&in, 3, DPU_O82_LUTBUS_BYTES, -EINVAL); set16(igc + sizeof(igc) - 2, 4095);
	bytes = 123;
	assert(dpu_o82_lutbus_build(&in, 3, NULL, DPU_O82_LUTBUS_BYTES, &bytes) == -EINVAL);
	assert(dpu_o82_lutbus_build(&in, 3, storage, sizeof(storage), NULL) == -EINVAL);
	assert(bytes == 123);
	u8 before[sizeof(igc)]; memcpy(before, igc, sizeof(igc));
	assert(dpu_o82_lutbus_build(&in, 3, igc, DPU_O82_LUTBUS_BYTES, &bytes) == -EINVAL);
	assert(bytes == 123 && !memcmp(before, igc, sizeof(igc)));
	memset(storage, 0xa5, sizeof(storage)); memcpy(saved, storage, sizeof(storage));
	assert(dpu_o82_lutbus_build(&in, 3, storage, sizeof(storage), (size_t *)(storage + 16)) == -EINVAL);
	assert(!memcmp(storage, saved, sizeof(storage)));
	pa_protocol();
	puts("Actual Cliffs IGC4/gamut4.3/GC1.8 stream: all paired DSPP masks, RGB/GBR packing, endpoints, LUT alignment/padding, three-NOP workaround, bounds and refusal-before-write passed; no DMA or hardware operation");
}
