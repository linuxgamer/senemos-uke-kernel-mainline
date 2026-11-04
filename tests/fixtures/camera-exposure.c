// SPDX-License-Identifier: GPL-2.0-only
/* Only the I2C boundary is modeled; the actual production function is imported. */
#include <assert.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef uint8_t u8;
typedef uint32_t u32;
#include "exposure-constants.h"
struct i2c_client { int unused; };
struct v4l2_subdev { struct i2c_client *client; };
struct ov08d10_mode { u32 vts_def; };
struct ov08d10 {
	struct v4l2_subdev sd;
	const struct ov08d10_mode *cur_mode;
};
static struct i2c_client client;
static int timing[2], reads, writes, fail_write, write_error;
static u8 registers[6], values[6];

static struct i2c_client *v4l2_get_subdevdata(struct v4l2_subdev *sd)
{
	assert(sd->client == &client);
	return sd->client;
}
static int i2c_smbus_read_byte_data(struct i2c_client *target, u8 reg)
{
	assert(target == &client && reads < 2);
	assert(reg == (reads ? 0x38 : 0x37));
	return timing[reads++];
}
static int i2c_smbus_write_byte_data(struct i2c_client *target, u8 reg, u8 value)
{
	assert(target == &client && writes < 6);
	registers[writes] = reg;
	values[writes++] = value;
	return writes == fail_write ? write_error : 0;
}

#include "exposure-function.c"

static void defaults(unsigned int hts)
{
	reads = writes = fail_write = 0;
	write_error = -EREMOTEIO;
	timing[0] = hts >> 8;
	timing[1] = hts & 0xff;
	memset(registers, 0, sizeof(registers));
	memset(values, 0, sizeof(values));
}

int main(int argc, char **argv)
{
	struct ov08d10_mode mode = { .vts_def = 2504 };
	struct ov08d10 sensor = { .sd.client = &client, .cur_mode = &mode };

#ifdef EXPOSURE_BEFORE
	assert(argc == 2);
	defaults(1840);
	if (!strcmp(argv[1], "read")) {
		timing[0] = -EREMOTEIO;
		fputs("Before-control: exposure must stop at the failed HTS read\n", stderr);
		int ret = ov08d10_set_exposure(&sensor, 64);
		assert(ret == -EREMOTEIO && writes == 1 && reads == 1);
	} else {
		assert(!strcmp(argv[1], "zero"));
		timing[0] = timing[1] = 0;
		fputs("Before-control: exposure must reject zero HTS before division\n", stderr);
		assert(ov08d10_set_exposure(&sensor, 64) == -EINVAL);
	}
#else
	(void)argc; (void)argv;
	unsigned int cases = 0;
	const u8 sequence[] = { OV08D10_REG_PAGE, OV08D10_REG_PAGE,
		OV08D10_REG_EXPOSURE_H, OV08D10_REG_EXPOSURE_M,
		OV08D10_REG_EXPOSURE_L, OV08D10_REG_GLOBAL_EFFECTIVE };
	for (int smaller = 0; smaller < 2; smaller++) {
		mode.vts_def = smaller ? 3736 : 2504;
		unsigned int hts = smaller ? 1912 : 1840;
		unsigned int exposures[] = { 6, 64, 1024, mode.vts_def - 6 };
		for (unsigned int i = 0; i < 4; i++) {
			defaults(hts);
			uint64_t expected = (uint64_t)exposures[i] * (66 * 36000 / hts) /
				(mode.vts_def - 6);
			assert(!ov08d10_set_exposure(&sensor, exposures[i]));
			assert(reads == 2 && writes == 6);
			assert(!memcmp(registers, sequence, sizeof(sequence)));
			assert(values[0] == 1 && values[1] == 1 && values[5] == 1);
			assert(values[2] == ((expected >> 16) & 0xff));
			assert(values[3] == ((expected >> 8) & 0xff));
			assert(values[4] == (expected & 0xff));
			cases++;
		}
	}
	mode.vts_def = 2504;
	for (int failure = 1; failure <= 6; failure++) {
		defaults(1840);
		fail_write = failure;
		assert(ov08d10_set_exposure(&sensor, 64) == -EREMOTEIO);
		assert(writes == failure && reads == (failure == 1 ? 0 : 2));
		assert(!memcmp(registers, sequence, failure));
		cases++;
	}
	int errors[] = { -EREMOTEIO, -ENXIO };
	for (int index = 0; index < 2; index++) {
		for (unsigned int error = 0; error < 2; error++) {
			defaults(1840);
			timing[index] = errors[error];
			assert(ov08d10_set_exposure(&sensor, 64) == errors[error]);
			assert(writes == 1 && reads == index + 1);
			assert(registers[0] == OV08D10_REG_PAGE && values[0] == 1);
			cases++;
		}
	}
	defaults(0);
	assert(ov08d10_set_exposure(&sensor, 64) == -EINVAL);
	assert(reads == 2 && writes == 1);
	cases++;
	printf("OV08D10 actual exposure: %u valid/fault/zero-timing cases passed; no device I/O\n", cases);
#endif
	return 0;
}
