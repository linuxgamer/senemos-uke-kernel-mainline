// SPDX-License-Identifier: GPL-2.0-only
#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <linux/firmware.h>
#include "dpu_o82_profiles.h"
#include "o82-color-firmware.h"

static unsigned char bytes[O82_COLOR_FW_HEADER + 2 * O82_COLOR_FW_RECORD + O82_COLOR_FW_DATA_BYTES + 2];
static struct firmware fixture;
static unsigned int requests, releases;
static int request_error;

int request_firmware_direct(const struct firmware **fw, const char *name, struct device *dev)
{
	assert(dev && !strcmp(name, "qcom/sm7675/uke/o82-42-color-v2.bin"));
	requests++;
	if (request_error)
		return request_error;
	*fw = &fixture;
	return 0;
}
void release_firmware(const struct firmware *fw) { assert(fw == &fixture); releases++; }

static void word(size_t at, unsigned int value)
{
	for (unsigned int byte = 0; byte < 4; byte++) bytes[at + byte] = value >> (byte * 8);
}
static void make_fixture(bool missing_default, bool blocked_default)
{
	const unsigned char hash[] = {
		0x2b,0x64,0x42,0xce,0x0e,0x8f,0xef,0x6d,0x1b,0x00,0x8c,0xde,0xca,0x38,0x38,0x45,
		0x02,0x82,0x86,0x8d,0x38,0x5f,0x6e,0x30,0x56,0xc0,0xa4,0xce,0x2b,0x89,0x49,0xd8,
	};
	unsigned int cursor = O82_COLOR_FW_HEADER + 2 * O82_COLOR_FW_RECORD;

	memset(bytes, 0, sizeof(bytes));
	memcpy(bytes, O82_COLOR_FW_MAGIC, 8);
	word(8, O82_COLOR_FW_VERSION); word(12, 0x42); word(24, 2); word(28, O82_COLOR_FW_RECORD);
	memcpy(bytes + 32, hash, 32);
	word(64, O82_HDR_NOMINAL_PEAK_NITS); word(68, O82_HDR_NOMINAL_BLACK_10000); word(72, cursor);
	for (unsigned int index = 0; index < 2; index++) {
		unsigned int record = O82_COLOR_FW_HEADER + index * O82_COLOR_FW_RECORD;
		bool blocked = !index || blocked_default;

		strcpy((char *)bytes + record, !index ? "blocked" : missing_default ? "z_no_default" : "standard_P3");
		word(record + 64, 1);
		word(record + 72, O82_COLOR_OP_IGC | O82_COLOR_OP_GC | (blocked ? O82_COLOR_OP_MEMORY : 0));
		word(record + 76, blocked ? O82_COLOR_BLOCK_MEMORY : 0);
		bytes[record + 96] = 1;
		if (!blocked) {
			word(record + 80, cursor); word(record + 84, O82_COLOR_FW_DATA_BYTES);
			for (unsigned int curve = 0; curve < 2; curve++)
				for (unsigned int channel = 0; channel < 3; channel++) {
					unsigned int endpoint = cursor + curve * O82_COLOR_FW_CURVE_BYTES + (256 * 3 + channel) * 2;
					bytes[endpoint] = 255; bytes[endpoint + 1] = 15;
				}
			cursor += O82_COLOR_FW_DATA_BYTES;
		}
		word(record + 88, cursor); word(record + 92, 1); bytes[cursor++] = 'x';
	}
	word(16, cursor); word(20, o82_hdr_crc32(bytes + 24, cursor - 24));
	fixture.data = bytes; fixture.size = cursor;
	assert(o82_color_fw_valid(bytes, cursor, 0x42));
}
int main(void)
{
	struct dpu_o82_profiles profiles = { 0 };
	struct dpu_o82_color_input input = { 0 }, retained;
	struct device dev = { 0 };
	unsigned int before;

	make_fixture(false, false);
	assert(dpu_o82_profiles_load(&profiles, &dev, 0x99) == -EINVAL && !requests);
	assert(dpu_o82_profiles_load(NULL, &dev, 0x42) == -EINVAL && !requests);
	assert(dpu_o82_profiles_load(&profiles, NULL, 0x42) == -EINVAL && !requests);
	request_error = -ENOENT;
	assert(dpu_o82_profiles_load(&profiles, &dev, 0x42) == -ENOENT && !profiles.fw && !releases);
	request_error = 0;
	bytes[20] ^= 1;
	assert(dpu_o82_profiles_load(&profiles, &dev, 0x42) == -EBADMSG && !profiles.fw && releases == 1);
	make_fixture(true, false);
	assert(dpu_o82_profiles_load(&profiles, &dev, 0x42) == -ENOENT && !profiles.fw && releases == 2);
	make_fixture(false, true);
	assert(dpu_o82_profiles_load(&profiles, &dev, 0x42) == -EOPNOTSUPP && !profiles.fw && releases == 3);
	make_fixture(false, false);
	assert(!dpu_o82_profiles_load(&profiles, &dev, 0x42) && profiles.selected == 1);
	before = requests;
	assert(dpu_o82_profiles_load(&profiles, &dev, 0x42) == -EBUSY && requests == before && releases == 3);
	for (unsigned int wide = 0; wide < 2; wide++)
		for (unsigned int pq = 0; pq < 2; pq++) {
			assert(!dpu_o82_profiles_input(&profiles, wide, pq, &input));
			assert(input.primaries == 1 && input.igc && input.gamut && input.gc);
			assert(input.gamut == bytes + 417 + 2 * O82_COLOR_FW_CURVE_BYTES + wide * O82_COLOR_FW_CUBE_BYTES);
			assert(input.igc == bytes + 417 + pq * O82_COLOR_FW_CURVE_BYTES);
		}
	retained = input;
	assert(dpu_o82_profiles_input(&profiles, 2, 0, &input) == -EINVAL);
    assert(input.igc == retained.igc && input.gamut == retained.gamut &&
           input.gc == retained.gc && input.primaries == retained.primaries &&
           input.dither_strength == retained.dither_strength && input.dither_enabled == retained.dither_enabled);
	assert(dpu_o82_profiles_select(&profiles, "blocked") == -EOPNOTSUPP && profiles.selected == 1);
	assert(dpu_o82_profiles_select(&profiles, "absent") == -ENOENT && profiles.selected == 1);
	assert(dpu_o82_profiles_select(&profiles, NULL) == -EINVAL && profiles.selected == 1);
	assert(!dpu_o82_profiles_select(&profiles, "standard_P3"));
	dpu_o82_profiles_unload(&profiles);
	assert(!profiles.fw && releases == 4);
	assert(dpu_o82_profiles_input(&profiles, 0, 0, &input) == -ENODEV);
    assert(input.igc == retained.igc && input.gamut == retained.gamut &&
           input.gc == retained.gc && input.primaries == retained.primaries &&
           input.dither_strength == retained.dither_strength && input.dither_enabled == retained.dither_enabled);
	dpu_o82_profiles_unload(&profiles); dpu_o82_profiles_unload(NULL);
	assert(releases == 4);
	puts("Actual kernel preset loader: missing/corrupt data, default admission, refusal, all four inputs and lifetime passed");
	return 0;
}
