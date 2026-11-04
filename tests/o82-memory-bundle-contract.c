// SPDX-License-Identifier: GPL-2.0-only
/* Synthetic v5 bundle -> actual kernel loader -> actual command encoder. */
#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <linux/firmware.h>
#include "dpu_o82_profiles.h"
#include "dpu_o82_lutbus.h"
#include "o82-color-firmware.h"

static unsigned char data[O82_COLOR_FW_HEADER + O82_COLOR_FW_RECORD +
	O82_COLOR_FW_DATA_BYTES + O82_SIXZONE_BYTES + O82_HSIC_BYTES + O82_MEMORY_BYTES + 1];
static unsigned char commands[DPU_O82_LUTBUS_MAX_BYTES];
static struct firmware fixture;
static unsigned int panel, requests, releases, memory_at;
static int modern_error, legacy_error;

int request_firmware_direct(const struct firmware **fw, const char *name, struct device *dev)
{
	char expected[64];
	int ret;

	assert(dev);
	requests++;
	snprintf(expected, sizeof(expected), "qcom/sm7675/uke/o82-%02x-color-v5.bin", panel);
	if (!strcmp(name, expected)) {
		ret = modern_error;
	} else {
		snprintf(expected, sizeof(expected), "qcom/sm7675/uke/o82-%02x-color-v4.bin", panel);
		assert(!strcmp(name, expected));
		ret = legacy_error;
	}
	*fw = ret ? NULL : &fixture;
	return ret;
}
void release_firmware(const struct firmware *fw) { assert(fw == &fixture); releases++; }

static void word(unsigned int at, unsigned int value)
{
	for (unsigned int b = 0; b < 4; b++) data[at + b] = value >> (8 * b);
}
static void checksum(void) { word(20, o82_hdr_crc32(data + 24, fixture.size - 24)); }
static void make_fixture(unsigned int mask, unsigned int protection, bool six, bool hsic, bool blocked)
{
	static const unsigned char hashes[2][32] = {
		{0xbd,0x88,0xeb,0x94,0x13,0x4e,0x5f,0x62,0xc0,0x5e,0xeb,0xaa,0x0a,0x9e,0x4b,0x52,
		 0x67,0x96,0x83,0x63,0xf7,0x2f,0x44,0x00,0x18,0xb9,0x8a,0x15,0xd1,0xbd,0x91,0x22},
		{0x2b,0x64,0x42,0xce,0x0e,0x8f,0xef,0x6d,0x1b,0x00,0x8c,0xde,0xca,0x38,0x38,0x45,
		 0x02,0x82,0x86,0x8d,0x38,0x5f,0x6e,0x30,0x56,0xc0,0xa4,0xce,0x2b,0x89,0x49,0xd8},
	};
	unsigned int r = O82_COLOR_FW_HEADER, cursor = r + O82_COLOR_FW_RECORD;
	unsigned int flags = O82_COLOR_OP_IGC | O82_COLOR_OP_GC;

	memset(data, 0, sizeof(data));
	memcpy(data, O82_COLOR_FW_MEMORY_MAGIC, 8); word(8, O82_COLOR_FW_MEMORY_VERSION);
	word(12, panel); word(24, 1); word(28, O82_COLOR_FW_RECORD);
	memcpy(data + 32, hashes[panel == 0x42], 32);
	word(64, O82_HDR_NOMINAL_PEAK_NITS); word(68, O82_HDR_NOMINAL_BLACK_10000); word(72, cursor);
	strcpy((char *)data + r, "standard_P3"); data[r + 96] = 1;
	if (mask || protection) flags |= O82_COLOR_OP_MEMORY;
	if (six) flags |= O82_COLOR_OP_SIXZONE;
	if (hsic) flags |= O82_COLOR_OP_HSIC;
	if (blocked) flags |= O82_COLOR_OP_HDR;
	word(r + 72, flags); word(r + 76, blocked ? O82_COLOR_BLOCK_HDR : 0);
	memory_at = 0;
	if (!blocked) {
		word(r + 80, cursor); word(r + 84, O82_COLOR_FW_DATA_BYTES);
		for (unsigned int curve = 0; curve < 2; curve++)
			for (unsigned int c = 0; c < 3; c++) {
				unsigned int end = cursor + curve * O82_COLOR_FW_CURVE_BYTES + (256 * 3 + c) * 2;
				data[end] = 255; data[end + 1] = 15;
			}
		cursor += O82_COLOR_FW_DATA_BYTES;
		if (six) {
			word(r + 136, cursor); word(r + 140, O82_SIXZONE_BYTES);
			word(cursor, 7); word(cursor + 28, O82_SIXZONE_SAMPLES);
			data[cursor + 24] = 3; data[cursor + 25] = 3;
			cursor += O82_SIXZONE_BYTES;
		}
		word(r + 144, cursor); word(r + 148, O82_HSIC_BYTES);
		if (hsic) { word(cursor, 15); word(cursor + 4, 0xb3); word(cursor + 12, 0x20); }
		cursor += O82_HSIC_BYTES;
		memory_at = cursor;
		word(r + 152, cursor); word(r + 156, O82_MEMORY_BYTES);
		word(cursor, mask); word(cursor + 4, protection); word(cursor + 8, 1);
		for (unsigned int i = 0; i < 3; i++) if (mask & (1U << i)) {
			unsigned int at = cursor + 16 + 32 * i;
			word(at, 8); word(at + 4, 0x12345678U + i); word(at + 8, 0x20002000);
			word(at + 12, 4194304); word(at + 16, i + 1);
			word(at + 20, 0x01800000); word(at + 24, 0x0008de1f); word(at + 28, 0x0008fb07);
		}
		cursor += O82_MEMORY_BYTES;
	}
	word(r + 88, cursor); word(r + 92, 1); data[cursor++] = 'x';
	fixture.data = data; fixture.size = cursor; word(16, cursor); checksum();
	assert(o82_color_fw_valid(data, fixture.size, panel));
}
static void refused(struct dpu_o82_profiles *p, struct device *dev, int error, unsigned int count)
{
	unsigned int before = requests, freed = releases;
	assert(dpu_o82_profiles_load(p, dev, panel) == error);
	assert(!p->fw && requests == before + count);
	assert(releases == freed + (error == -EBADMSG || error == -EOPNOTSUPP));
}
int main(void)
{
	struct dpu_o82_profiles p = { 0 };
	struct dpu_o82_color_input input = { 0 }, retained;
	struct device dev = { 0 };
	unsigned int cases = 0;
	size_t size;

	for (unsigned int variant = 0; variant < 2; variant++) {
		panel = variant ? 0x42 : 0x36;
		for (unsigned int mask = 0; mask < 8; mask++)
			for (unsigned int protection = 0; protection < 64; protection++)
				for (unsigned int six = 0; six < 2; six++) {
					bool hsic = !!(protection & 1);
					make_fixture(mask, protection, six, hsic, false);
					unsigned int before = requests;
					assert(!dpu_o82_profiles_load(&p, &dev, panel) && requests == before + 1);
					for (unsigned int wide = 0; wide < 2; wide++)
						for (unsigned int pq = 0; pq < 2; pq++) {
							assert(!dpu_o82_profiles_input(&p, wide, pq, &input));
							assert(input.memory == data + memory_at && input.memory_bytes == O82_MEMORY_BYTES);
							assert(o82_hdr_u32(input.memory) == mask && o82_hdr_u32(input.memory + 4) == protection);
							assert(o82_memory_valid(input.memory, input.memory_bytes));
							assert(input.pa_managed && !!input.sixzone == !!six);
						}
					/* Actual command output includes explicit active or neutral memory. */
					assert(!dpu_o82_lutbus_build(&input, 3, commands, sizeof(commands), &size));
					assert(size == (six ? DPU_O82_LUTBUS_MAX_BYTES : DPU_O82_LUTBUS_MEMORY_BYTES));
					retained = input;
					assert(dpu_o82_profiles_input(&p, 2, 0, &input) == -EINVAL);
					assert(!memcmp(&input, &retained, sizeof(input)));
					dpu_o82_profiles_unload(&p); cases++;
				}
		make_fixture(7, 63, true, true, true);
		refused(&p, &dev, -EOPNOTSUPP, 1);
		make_fixture(7, 63, true, true, false);
		for (unsigned int byte = 0; byte < 16; byte++) {
			data[memory_at + byte] ^= 128; checksum();
			refused(&p, &dev, -EBADMSG, 1);
			data[memory_at + byte] ^= 128;
		}
		checksum();
		/* CRC repair must not hide missing payloads, flag mismatch or noncanonical offsets. */
		const unsigned int offsets[] = {152, 156, 72, 76};
		for (unsigned int i = 0; i < sizeof(offsets) / sizeof(offsets[0]); i++) {
			unsigned int at = O82_COLOR_FW_HEADER + offsets[i], old = o82_hdr_u32(data + at);
			word(at, i == 0 ? 0xffffffffU : i == 1 ? 0 : i == 2 ? old ^ O82_COLOR_OP_MEMORY : O82_COLOR_BLOCK_MEMORY);
			checksum(); refused(&p, &dev, -EBADMSG, 1); word(at, old);
		}
		checksum();
		for (unsigned int i = 0; i < 2; i++) {
			modern_error = i ? -ENOMEM : -EACCES;
			refused(&p, &dev, modern_error, 1);
		}
		modern_error = -ENOENT; legacy_error = -ENOENT;
		refused(&p, &dev, -ENOENT, 2);
		legacy_error = 0;
		/* A v5 file served under a v4 path cannot change ownership through fallback. */
		refused(&p, &dev, -EBADMSG, 2);
		modern_error = 0;
		make_fixture(0, 0, false, false, true);
		memcpy(data, O82_COLOR_FW_MAGIC, 8); word(8, O82_COLOR_FW_VERSION); checksum();
		assert(o82_color_fw_valid(data, fixture.size, panel));
		/* A v4 file under the preferred v5 name is also a terminal error. */
		refused(&p, &dev, -EBADMSG, 1);
		modern_error = -ENOENT;
		refused(&p, &dev, -EOPNOTSUPP, 2);
		modern_error = 0;
	}
	assert(!p.fw);
	printf("Actual v5 memory bundle/loader/encoder: %u paired-panel active, neutral and protection-only cases passed; four input variants, repaired-CRC tampering, strict path versions and ENOENT-only fallback passed\n", cases);
	return 0;
}
