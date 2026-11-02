// SPDX-License-Identifier: GPL-2.0-or-later
/* Uke normal-RAM/THP protocol, from pinned MiCode and measured OEM behavior.
 * Derived from the GPL-2.0-or-later touch-normal-probe.cpp and packet decoder
 * retained in hardware source-family uke-hw 1.5.2. No GPL-3 contact code is used.
 */
#include <linux/errno.h>
#include <linux/string.h>
#include <linux/unaligned.h>

#include "nt36532-uke-protocol.h"

struct nvt_uke_bank {
	u32 offset, address, size;
};

static const struct nvt_uke_bank nvt_uke_banks[] = {
	{ 0x200, 0, 0x174d8 }, { 0x22000, 0x100000, 0x140a0 },
	{ 0, 0x1140a0, 0x100 }, { 0x100, 0x1141a0, 0x100 },
};

int nvt_uke_decode(const u8 *data, size_t size, struct nvt_uke_frame *frame)
{
	const u8 *header;
	u32 length, sum;
	unsigned int offset;

	if (!data || !frame || size != NVT_UKE_FRAME_SIZE)
		return -EINVAL;
	header = data + 256;
	length = get_unaligned_le32(header + 8);
	if (header[0] != 0xa5 || header[1] != 0x61 || length != 0x4bf ||
	    get_unaligned_le32(header + 16) != ~length ||
	    get_unaligned_le16(header + 12) != (get_unaligned_le16(header + 4) ^ 0xffff) ||
	    header[48] != 60 || header[49] != 40 || header[56] != 3 ||
	    (header[24] != 2 && header[24] != 4))
		return -EBADMSG;
	sum = get_unaligned_le16(header + 4);
	for (offset = 0; offset < length * 4; offset += 2)
		sum += get_unaligned_le16(header + 20 + offset);
	if (sum & 0xffff)
		return -EBADMSG;
	/* Keep the counter/type and original signed little-endian matrix intact. */
	frame->counter = get_unaligned_le16(header + 2);
	frame->scan_mode = header[24];
	frame->matrix_le = header + 64;
	return 0;
}

int nvt_uke_watchdog(const u8 *data, size_t size, unsigned int *consecutive)
{
	unsigned int i;

	if (!data || !consecutive || size != NVT_UKE_FRAME_SIZE)
		return -EINVAL;
	for (i = 0; i < 6; i++) {
		if (data[i] != 0xfd && data[i] != 0xfe) {
			*consecutive = 0;
			return 0;
		}
	}
	if (*consecutive < 10) {
		(*consecutive)++;
		return 0;
	}
	*consecutive = 0;
	return data[0];
}

const char *nvt_uke_firmware(enum nvt_uke_variant variant)
{
	switch (variant) {
	case NVT_UKE_CSOT:
		return "qcom/uke/touch/csot/normal.bin";
	case NVT_UKE_TIANMA:
		return "qcom/uke/touch/tm/normal.bin";
	default:
		return NULL;
	}
}

int nvt_uke_variant_from_name(const char *name)
{
	if (name && !strcmp(name, "csot"))
		return NVT_UKE_CSOT;
	if (name && !strcmp(name, "tianma"))
		return NVT_UKE_TIANMA;
	return -EINVAL;
}

int nvt_uke_panel_id(enum nvt_uke_variant variant, int direction, int level)
{
	if (!nvt_uke_firmware(variant))
		return -EINVAL;
	if (direction < 0)
		return direction;
	if (level < 0)
		return level;
	/* Retain the observed CSOT high input; Tianma polarity is not assumed. */
	return direction == 1 && (level == 0 || level == 1) &&
		(variant == NVT_UKE_TIANMA || level == 1) ? 0 : -ENODEV;
}

int nvt_uke_validate_image(const struct nvt_uke_io *io, const u8 *data, size_t size)
{
	static const u8 expected[2][32] = { {
		0xa4, 0xf9, 0x49, 0xfb, 0x89, 0xc7, 0xea, 0xad,
		0x9d, 0xa8, 0x5a, 0x58, 0x85, 0xcd, 0x2d, 0xcc,
		0x1f, 0xff, 0xbf, 0x08, 0xbc, 0x1e, 0x7f, 0xfe,
		0x9f, 0x0b, 0xb9, 0x7c, 0x17, 0x69, 0xb3, 0x10,
	}, {
		0x12, 0xce, 0x26, 0x93, 0xb9, 0x65, 0xa3, 0x5e,
		0x34, 0x69, 0x98, 0x4f, 0xd9, 0x5a, 0xfe, 0xbb,
		0x4c, 0x0a, 0x74, 0x0c, 0xa9, 0x08, 0x15, 0x9b,
		0x0a, 0x5e, 0x6b, 0xda, 0xd5, 0x96, 0x86, 0x19,
	} };
	u8 digest[32];
	int ret;

	if (!io || !io->sha256 || !data || size != NVT_UKE_IMAGE_SIZE ||
	    !nvt_uke_firmware(io->variant))
		return -EINVAL;
	if (get_unaligned_le32(data) != 0x200 || get_unaligned_le32(data + 4) ||
	    get_unaligned_le32(data + 8) != 0x174d7 ||
	    get_unaligned_le32(data + 12) != 0x22000 ||
	    get_unaligned_le32(data + 16) != 0x100000 ||
	    get_unaligned_le32(data + 20) != 0x1409f ||
	    get_unaligned_le32(data + 24) !=
		(io->variant == NVT_UKE_CSOT ? 0xe4bdd7f0U : 0x9441f4bbU) ||
	    get_unaligned_le32(data + 28) !=
		(io->variant == NVT_UKE_CSOT ? 0x89495247U : 0x9c1002baU) ||
	    data[0x20] != 3 || data[0x28] || data[0x29] ||
	    get_unaligned_le32(data + 0xf0) != 0x1140a0 ||
	    get_unaligned_le32(data + 0xf4) != 0xff || get_unaligned_le32(data + 0xf8) ||
	    get_unaligned_le32(data + 0x1f0) != 0x1141a0 ||
	    get_unaligned_le32(data + 0x1f4) != 0xff ||
	    get_unaligned_le32(data + 0x1f8) != 0x100)
		return -EINVAL;
	ret = io->sha256(io->context, data, size, digest);
	if (ret)
		return ret < 0 ? ret : -EIO;
	return memcmp(digest, expected[io->variant], sizeof(digest)) ? -EBADMSG : 0;
}

static bool nvt_uke_ram(u32 address, size_t size)
{
	unsigned int i;

	for (i = 0; i < sizeof(nvt_uke_banks) / sizeof(nvt_uke_banks[0]); i++) {
		const struct nvt_uke_bank *bank = &nvt_uke_banks[i];

		if (address >= bank->address && address - bank->address <= bank->size &&
		    size <= bank->size - (address - bank->address))
			return true;
	}
	return false;
}

static int nvt_uke_guard(const struct nvt_uke_io *io)
{
	int ret;

	if (!io || !io->read || !io->write || !io->check_ready || !io->delay_ms)
		return -EINVAL;
	ret = io->check_ready(io->context);
	return ret > 0 ? -EIO : ret;
}

static int nvt_uke_read(const struct nvt_uke_io *io, u32 address, void *data,
			size_t size, bool fast)
{
	int ret = nvt_uke_guard(io);

	if (ret)
		return ret;
	ret = io->read(io->context, address, data, size, fast);
	return ret > 0 ? -EIO : ret;
}

static int nvt_uke_write(const struct nvt_uke_io *io, u32 address,
			 const void *data, size_t size, bool fast)
{
	int ret = nvt_uke_guard(io);

	if (ret)
		return ret;
	ret = io->write(io->context, address, data, size, fast);
	return ret > 0 ? -EIO : ret;
}

static int nvt_uke_byte(const struct nvt_uke_io *io, u32 address, u8 value)
{
	return nvt_uke_write(io, address, &value, 1, false);
}

static int nvt_uke_wait(const struct nvt_uke_io *io, u32 address,
			unsigned int attempts, unsigned int delay, u8 minimum, u8 maximum)
{
	u8 value;
	unsigned int i;
	int ret;

	for (i = 0; i < attempts; i++) {
		ret = nvt_uke_read(io, address, &value, 1, false);
		if (ret)
			return ret;
		if (value >= minimum && value <= maximum)
			return 0;
		io->delay_ms(io->context, delay);
	}
	return -ETIMEDOUT;
}

static int nvt_uke_custom(const struct nvt_uke_io *io, u8 command, u16 *value)
{
	u8 request[] = { 0xbf, command, 1 }, response[5];
	unsigned int i;
	int ret;

	io->delay_ms(io->context, 35);
	ret = nvt_uke_write(io, 0x11c450, request, sizeof(request), false);
	if (ret)
		return ret;
	for (i = 0; i < 25; i++) {
		io->delay_ms(io->context, 20);
		ret = nvt_uke_read(io, 0x11c450, response, sizeof(response), false);
		if (ret)
			return ret;
		if (!response[0]) {
			*value = get_unaligned_le16(response + 3);
			return 0;
		}
	}
	return -ETIMEDOUT;
}

int nvt_uke_boot(const struct nvt_uke_io *io, const u8 *data, size_t size, bool idle_reset)
{
	static const struct {
		u32 address;
		u8 bytes[4], count;
	} setup[] = {
		{ 0x1fb528, { 0, 0, 0 }, 3 },
		{ 0x1fb518, { 0xd7, 0x74, 1 }, 3 },
		{ 0x1fb500, { 0xf0, 0xd7, 0xbd, 0xe4 }, 4 },
		{ 0x1fb52c, { 0, 0, 0x10 }, 3 },
		{ 0x1fb530, { 0x9f, 0x40, 1 }, 3 },
		{ 0x1fb504, { 0x47, 0x52, 0x49, 0x89 }, 4 },
	};
	u8 scratch[NVT_UKE_CHUNK], trim[6], topology, metadata[16];
	u8 zero[6] = { 0 }, boot[] = { 0xae, 0 };
	u16 mode;
	unsigned int i, offset, chunk;
	int ret;

	ret = nvt_uke_guard(io);
	if (ret)
		return ret;
	ret = nvt_uke_validate_image(io, data, size);
	if (ret)
		return ret;
	if (idle_reset) {
		ret = nvt_uke_byte(io, 0x1fb43e, 0xaa);
		if (ret)
			return ret;
		io->delay_ms(io->context, 10);
	}
	ret = nvt_uke_byte(io, 0x1fb43e, 0x69);
	if (ret)
		return ret;
	io->delay_ms(io->context, 5);
	ret = nvt_uke_write(io, 0x1fb104, zero, sizeof(zero), false);
	if (ret)
		return ret;
	ret = nvt_uke_read(io, 0x1fb104, trim, sizeof(trim), false);
	if (ret)
		return ret;
	ret = nvt_uke_read(io, 0x1fb12c, &topology, 1, false);
	if (ret)
		return ret;
	if (trim[3] != 0x32 || trim[4] != 0x65 || trim[5] != 3 || (topology & 1))
		return -ENODEV;
	ret = nvt_uke_byte(io, 0x1fb43e, 0x69);
	if (ret)
		return ret;
	io->delay_ms(io->context, 5);
	for (i = 0; i < sizeof(setup) / sizeof(setup[0]); i++) {
		const u8 *bytes = setup[i].bytes;

		/* Supplier CRCs come only from the fully hash-admitted OEM image. */
		if (setup[i].address == 0x1fb500)
			bytes = data + 24;
		else if (setup[i].address == 0x1fb504)
			bytes = data + 28;
		ret = nvt_uke_write(io, setup[i].address, bytes, setup[i].count, false);
		if (ret)
			return ret;
	}
	ret = nvt_uke_byte(io, 0x1fc925, 0x56);
	if (ret)
		return ret;
	for (i = 0; i < sizeof(nvt_uke_banks) / sizeof(nvt_uke_banks[0]); i++) {
		const struct nvt_uke_bank *bank = &nvt_uke_banks[i];

		for (offset = 0; offset < bank->size; offset += chunk) {
			chunk = bank->size - offset;
			if (chunk > NVT_UKE_CHUNK)
				chunk = NVT_UKE_CHUNK;
			if (!nvt_uke_ram(bank->address + offset, chunk) ||
			    bank->offset + offset > size || chunk > size - (bank->offset + offset))
				return -EINVAL;
			ret = nvt_uke_write(io, bank->address + offset, data + bank->offset + offset,
					    chunk, true);
			if (ret)
				return ret;
		}
	}
	ret = nvt_uke_wait(io, 0x1fc925, 200, 1, 0, 0);
	if (ret)
		return ret;
	for (i = 0; i < sizeof(nvt_uke_banks) / sizeof(nvt_uke_banks[0]); i++) {
		const struct nvt_uke_bank *bank = &nvt_uke_banks[i];

		for (offset = 0; offset < bank->size; offset += chunk) {
			chunk = bank->size - offset;
			if (chunk > sizeof(scratch))
				chunk = sizeof(scratch);
			ret = nvt_uke_read(io, bank->address + offset, scratch, chunk, true);
			if (ret)
				return ret;
			if (memcmp(scratch, data + bank->offset + offset, chunk))
				return -EBADMSG;
		}
	}
	ret = nvt_uke_write(io, 0x11c460, zero, sizeof(zero), false);
	if (!ret)
		ret = nvt_uke_write(io, 0x11c450, boot, sizeof(boot), false);
	if (!ret)
		ret = nvt_uke_byte(io, 0x1fb50d, 1);
	if (ret)
		return ret;
	io->delay_ms(io->context, 5);
	ret = nvt_uke_wait(io, 0x11c460, 50, 10, 0xa0, 0xaf);
	if (ret)
		return ret;
	ret = nvt_uke_read(io, 0x11c478, metadata, sizeof(metadata), false);
	if (ret)
		return ret;
	if (memcmp(metadata, (const u8[]){ 0x11, 0xee, 60, 40, 0x7d, 0, 0x53, 0x70 }, 8))
		return -ENODEV;
	ret = nvt_uke_wait(io, 0x11c460, 50, 10, 0xa1, 0xaf);
	if (ret)
		return ret;
	for (i = 0; i < 3; i++) {
		ret = nvt_uke_custom(io, ((const u8[]){ 1, 5, 0x0e })[i], &mode);
		if (ret)
			return ret;
		if (mode != (i == 0 ? 1 : 0))
			return -EPROTO;
	}
	return nvt_uke_guard(io);
}

int nvt_uke_read_frame(const struct nvt_uke_io *io, u8 data[NVT_UKE_FRAME_SIZE])
{
	int ret;

	if (!data)
		return -EINVAL;
	ret = nvt_uke_read(io, 0x11c400, data, NVT_UKE_FRAME_SIZE, true);
	return ret ? ret : nvt_uke_guard(io);
}

int nvt_uke_charger(const struct nvt_uke_io *io, bool connected)
{
	u8 request[] = { 0xbf, 0x10, 0, connected, 0 };
	u16 value;
	int ret = nvt_uke_guard(io);

	if (ret)
		return ret;
	io->delay_ms(io->context, 35);
	ret = nvt_uke_write(io, 0x11c450, request, sizeof(request), false);
	if (!ret) {
		io->delay_ms(io->context, 20);
		ret = nvt_uke_wait(io, 0x11c450, 25, 20, 0, 0);
	}
	if (!ret)
		ret = nvt_uke_custom(io, 0x10, &value);
	if (ret)
		return ret;
	return value == connected ? nvt_uke_guard(io) : -EPROTO;
}

/* Direct Uke GPL module 9bb7c433: bounded extended-command ACK and readback. */
static int nvt_uke_setting(const struct nvt_uke_io *io, u8 command, u16 value)
{
	u8 request[] = { 0xbf, command, 0, (u8)value, (u8)(value >> 8) }, ack;
	u16 actual;
	unsigned int i;
	int ret;

	io->delay_ms(io->context, 35);
	for (i = 0; i < 5; i++) {
		ret = nvt_uke_write(io, 0x11c450, request, sizeof(request), false);
		if (ret)
			return ret;
		io->delay_ms(io->context, 20);
		ret = nvt_uke_read(io, 0x11c450, &ack, 1, false);
		if (ret)
			return ret;
		if (!ack)
			break;
	}
	if (i == 5)
		return -ETIMEDOUT;
	ret = nvt_uke_custom(io, command, &actual);
	if (ret)
		return ret;
	return actual == value ? 0 : -EPROTO;
}

int nvt_uke_coordinate_mode(const struct nvt_uke_io *io, bool enabled)
{
	int ret = nvt_uke_guard(io);

	if (!ret)
		ret = nvt_uke_setting(io, 0x15, enabled);
	return ret ? ret : nvt_uke_guard(io);
}

int nvt_uke_gesture_enter(const struct nvt_uke_io *io)
{
	const u8 pen_off[] = { 0x7b, 0 };
	int ret = nvt_uke_guard(io);

	if (ret)
		return ret;
	ret = nvt_uke_setting(io, 0x11, 1);
	if (!ret)
		ret = nvt_uke_setting(io, 0x1b, 0);
	if (ret)
		return ret;
	io->delay_ms(io->context, 35);
	ret = nvt_uke_write(io, 0x11c450, pen_off, sizeof(pen_off), false);
	if (ret)
		return ret;
	io->delay_ms(io->context, 35);
	/* Gesture entry has no ACK polling in the exact Uke implementation. */
	return nvt_uke_byte(io, 0x11c450, 0x13);
}

int nvt_uke_double_tap(const u8 *data, size_t size)
{
	unsigned int i, sum = 0;
	u8 id;

	if (!data || size != NVT_UKE_GESTURE_SIZE)
		return -EINVAL;
	for (i = 0; i < NVT_UKE_GESTURE_SIZE; i++)
		sum += data[i];
	if (sum & 0xff)
		return -EBADMSG;
	id = data[0] >> 3;
	if (id == 30 && data[1] == 1)
		id = data[2];
	return id == 15 ? 1 : 0;
}
