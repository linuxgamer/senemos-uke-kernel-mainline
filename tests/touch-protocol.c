/* SPDX-License-Identifier: GPL-2.0-or-later */
#include <assert.h>
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <linux/unaligned.h>
#include "../src/input/nt36532-uke-protocol.h"

#ifndef NVT_TEST_VARIANT
#define NVT_TEST_VARIANT NVT_UKE_CSOT
#endif

static u8 image[NVT_UKE_IMAGE_SIZE], ram[0x1142a0], packet[NVT_UKE_FRAME_SIZE];
static unsigned int step, fail_step, guard_step, stop_guard, reads, writes, hashes;
static unsigned int ready_writes, bank_writes, bank_reads, busy, scans, last_command;
static unsigned int charger_writes, command_writes, command_reads, delay_total;
static int hash_error, callback_error;
static bool hash_bad, foreign, single, corrupt_bank, stuck_copy, stuck_boot;
static bool bad_metadata, bad_mode, bad_charger, connected;
static int guard(void *ctx)
{
	assert(ctx == image);
	return ++guard_step == stop_guard ? -ESHUTDOWN : 0;
}
static int operation(void)
{
	return ++step == fail_step ? callback_error : 0;
}
static void delay(void *ctx, unsigned int ms)
{
	assert(ctx == image && (ms == 1 || ms == 5 || ms == 10 || ms == 20 || ms == 35));
	delay_total += ms;
}
static int hash(void *ctx, const u8 *data, size_t size, u8 digest[32])
{
	static const u8 expected[2][32] = { {
		0xa4,0xf9,0x49,0xfb,0x89,0xc7,0xea,0xad,0x9d,0xa8,0x5a,0x58,0x85,0xcd,0x2d,0xcc,
		0x1f,0xff,0xbf,0x08,0xbc,0x1e,0x7f,0xfe,0x9f,0x0b,0xb9,0x7c,0x17,0x69,0xb3,0x10
	}, {
		0x12,0xce,0x26,0x93,0xb9,0x65,0xa3,0x5e,0x34,0x69,0x98,0x4f,0xd9,0x5a,0xfe,0xbb,
		0x4c,0x0a,0x74,0x0c,0xa9,0x08,0x15,0x9b,0x0a,0x5e,0x6b,0xda,0xd5,0x96,0x86,0x19
	} };
	assert(ctx == image && data == image && size == sizeof(image));
	hashes++;
	memcpy(digest, expected[NVT_TEST_VARIANT], 32);
	digest[0] ^= hash_bad;
	return hash_error;
}
static int read_data(void *ctx, u32 address, void *data, size_t size, bool fast)
{
	u8 *out = data;
	int ret = operation();

	assert(ctx == image && size && size <= NVT_UKE_FRAME_SIZE);
	if (ret)
		return ret;
	reads++;
	memset(out, 0, size);
	if (fast && address == 0x11c400 && size == NVT_UKE_FRAME_SIZE) {
		memcpy(out, packet, size);
	} else if (fast) {
		assert(address <= sizeof(ram) && size <= sizeof(ram) - address && size <= NVT_UKE_CHUNK);
		memcpy(out, ram + address, size);
		out[0] ^= corrupt_bank;
		bank_reads++;
	} else if (address == 0x1fb104 && size == 6) {
		out[3] = foreign ? 0 : 0x32; out[4] = 0x65; out[5] = 3;
	} else if (address == 0x1fb12c && size == 1) {
		out[0] = single;
	} else if (address == 0x1fc925 && size == 1) {
		out[0] = stuck_copy;
	} else if (address == 0x11c460 && size == 1) {
		out[0] = stuck_boot ? 0 : scans++ < 2 ? 0xa0 : 0xa1;
	} else if (address == 0x11c478 && size == 16) {
		memcpy(out, (u8[]){0x11,0xee,60,40,0x7d,0,0x53,0x70}, 8);
		out[0] ^= bad_metadata;
	} else if (address == 0x11c450 && (size == 1 || size == 5)) {
		command_reads++;
		if (busy) { out[0] = 0xbf; busy--; }
		if (size == 5)
			put_unaligned_le16(last_command == 0x10 ? (connected ^ bad_charger) :
				bad_mode ? 2 : last_command == 1, out + 3);
	} else {
		assert(0 && "unreviewed read");
	}
	return 0;
}
static int write_data(void *ctx, u32 address, const void *data, size_t size, bool fast)
{
	const u8 *bytes = data;
	int ret = operation();

	assert(ctx == image && size && size <= NVT_UKE_CHUNK);
	if (ret)
		return ret;
	writes++;
	if (fast) {
		assert(address <= sizeof(ram) && size <= sizeof(ram) - address);
		memcpy(ram + address, data, size);
		bank_writes++;
	} else if (address == 0x1fb43e) {
		assert(size == 1 && (bytes[0] == 0x69 || bytes[0] == 0xaa));
	} else if (address == 0x1fb104) {
		assert(size == 6 && !memcmp(bytes, (u8[6]){0}, 6));
	} else if (address == 0x11c460) {
		assert(size == 6 && !memcmp(bytes, (u8[6]){0}, 6));
	} else if (address == 0x11c450) {
		if (size == 3) {
			assert(bytes[0] == 0xbf && bytes[2] == 1);
			last_command = bytes[1]; command_writes++;
		} else if (size == 5) {
			assert(bytes[0] == 0xbf && bytes[1] == 0x10 && !bytes[2] && bytes[3] <= 1 && !bytes[4]);
			connected = bytes[3]; charger_writes++;
		} else {
			assert(size == 2 && bytes[0] == 0xae && !bytes[1]);
		}
	} else if (address == 0x1fb50d) {
		assert(size == 1 && bytes[0] == 1 && bank_reads == bank_writes && bank_reads);
		ready_writes++;
	} else {
		assert((address == 0x1fb528 && size == 3) || (address == 0x1fb518 && size == 3) ||
		       (address == 0x1fb500 && size == 4) || (address == 0x1fb52c && size == 3) ||
		       (address == 0x1fb530 && size == 3) || (address == 0x1fb504 && size == 4) ||
		       (address == 0x1fc925 && size == 1 && bytes[0] == 0x56));
		if (address == 0x1fb500) assert(size == 4 && !memcmp(bytes, image + 24, 4));
		if (address == 0x1fb504) assert(size == 4 && !memcmp(bytes, image + 28, 4));
	}
	return 0;
}
static const struct nvt_uke_io io = { image, read_data, write_data, guard, delay, hash, NVT_TEST_VARIANT };
static void reset(void)
{
	step = guard_step = reads = writes = hashes = ready_writes = 0;
	bank_reads = bank_writes = busy = scans = last_command = 0;
	charger_writes = command_writes = command_reads = delay_total = 0;
	fail_step = stop_guard = UINT_MAX;
	hash_error = 0; callback_error = -EREMOTEIO;
	hash_bad = foreign = single = corrupt_bank = stuck_copy = stuck_boot = false;
	bad_metadata = bad_mode = bad_charger = connected = false;
	memset(ram, 0, sizeof(ram));
}
static void layout(void)
{
	memset(image, 0, sizeof(image));
	put_unaligned_le32(0x200, image);
	put_unaligned_le32(0x174d7, image + 8);
	put_unaligned_le32(0x22000, image + 12);
	put_unaligned_le32(0x100000, image + 16);
	put_unaligned_le32(0x1409f, image + 20);
	put_unaligned_le32(NVT_TEST_VARIANT == NVT_UKE_CSOT ? 0xe4bdd7f0U : 0x9441f4bbU, image + 24);
	put_unaligned_le32(NVT_TEST_VARIANT == NVT_UKE_CSOT ? 0x89495247U : 0x9c1002baU, image + 28);
	image[0x20] = 3;
	put_unaligned_le32(0x1140a0, image + 0xf0);
	put_unaligned_le32(0xff, image + 0xf4);
	put_unaligned_le32(0x1141a0, image + 0x1f0);
	put_unaligned_le32(0xff, image + 0x1f4);
	put_unaligned_le32(0x100, image + 0x1f8);
}
static void frame_checks(void)
{
	struct nvt_uke_frame frame = {0}, previous;
	u8 *header = packet + 256;
	unsigned int i, consecutive = 0;
	u32 sum = 0;

	memset(packet, 0, sizeof(packet));
	header[0] = 0xa5; header[1] = 0x61;
	put_unaligned_le16(65535, header + 2);
	put_unaligned_le32(0x4bf, header + 8);
	put_unaligned_le32(~0x4bfU, header + 16);
	header[24] = 4; header[48] = 60; header[49] = 40; header[56] = 3;
	put_unaligned_le16(0x8000, header + 64);
	put_unaligned_le16(0x7fff, header + 66);
	for (i = 0; i < 0x4bf * 4; i += 2) sum += get_unaligned_le16(header + 20 + i);
	put_unaligned_le16((u16)-sum, header + 4);
	put_unaligned_le16(get_unaligned_le16(header + 4) ^ 0xffff, header + 12);
	assert(!nvt_uke_decode(packet, sizeof(packet), &frame));
	assert(frame.counter == 65535 && frame.scan_mode == 4 && frame.matrix_le == header + 64);
	assert((s16)get_unaligned_le16(frame.matrix_le) == -32768);
	assert((s16)get_unaligned_le16(frame.matrix_le + 2) == 32767);
	previous = frame;
	for (i = 0; i < sizeof(packet); i++) {
		assert(nvt_uke_decode(packet, i, &frame) == -EINVAL);
		assert(!memcmp(&previous, &frame, sizeof(frame)));
	}
	assert(nvt_uke_decode(NULL, sizeof(packet), &frame) == -EINVAL);
	assert(nvt_uke_decode(packet, sizeof(packet), NULL) == -EINVAL);
	for (i = 256; i < 256 + 20 + 0x4bf * 4; i++) {
		/* Counter is intentionally outside the vendor checksum. */
		if (i == 258 || i == 259 || i == 262 || i == 263 || i == 270 || i == 271) continue;
		packet[i] ^= 1;
		assert(nvt_uke_decode(packet, sizeof(packet), &frame) == -EBADMSG);
		assert(!memcmp(&previous, &frame, sizeof(frame)));
		packet[i] ^= 1;
	}
	memset(packet, 0xfd, 6);
	for (i = 0; i < 10; i++) assert(!nvt_uke_watchdog(packet, sizeof(packet), &consecutive));
	assert(nvt_uke_watchdog(packet, sizeof(packet), &consecutive) == 0xfd && !consecutive);
	memset(packet, 0xfe, 6); consecutive = UINT_MAX;
	assert(nvt_uke_watchdog(packet, sizeof(packet), &consecutive) == 0xfe && !consecutive);
	packet[4] = 0;
	assert(!nvt_uke_watchdog(packet, sizeof(packet), &consecutive) && !consecutive);
	assert(nvt_uke_watchdog(packet, 5, &consecutive) == -EINVAL);
}
int main(void)
{
	unsigned int operations, guards, i;
	struct nvt_uke_io invalid = io;
	assert(nvt_uke_variant_from_name("csot") == NVT_UKE_CSOT);
	assert(nvt_uke_variant_from_name("tianma") == NVT_UKE_TIANMA);
	assert(nvt_uke_variant_from_name(NULL) < 0 && nvt_uke_variant_from_name("unknown") < 0);
	for (enum nvt_uke_variant v = NVT_UKE_CSOT; v <= NVT_UKE_TIANMA; v++) {
		assert(nvt_uke_firmware(v));
		assert(!nvt_uke_panel_id(v, 1, v == NVT_UKE_CSOT));
		assert(nvt_uke_panel_id(v, 1, v != NVT_UKE_CSOT) == (v == NVT_UKE_CSOT ? -ENODEV : 0));
		assert(nvt_uke_panel_id(v, 1, 2) == -ENODEV);
		assert(nvt_uke_panel_id(v, 0, v == NVT_UKE_CSOT) == -ENODEV);
		assert(nvt_uke_panel_id(v, -EIO, 0) == -EIO);
		assert(nvt_uke_panel_id(v, 1, -EAGAIN) == -EAGAIN);
	}
	assert(!nvt_uke_firmware(2) && nvt_uke_panel_id(2, 1, 0) == -EINVAL);

	frame_checks(); layout(); reset();
	/* The synthetic digest callback tests admission; it is not a real firmware hash. */
	assert(!nvt_uke_boot(&io, image, sizeof(image), false));
	assert(hashes == 1 && ready_writes == 1 && bank_reads == bank_writes && bank_reads > 100);
	assert(command_writes == 3 && command_reads == 3);
	operations = step; guards = guard_step;
	reset(); invalid.variant = 2;
	assert(nvt_uke_boot(&invalid, image, sizeof(image), false) == -EINVAL && !step);
	invalid = io;
	invalid.variant = NVT_TEST_VARIANT == NVT_UKE_CSOT ? NVT_UKE_TIANMA : NVT_UKE_CSOT;
	reset(); assert(nvt_uke_boot(&invalid, image, sizeof(image), false) < 0 && !step);
	invalid = io;
	for (i = 1; i <= operations; i++) {
		reset(); fail_step = i;
		assert(nvt_uke_boot(&io, image, sizeof(image), false) == -EREMOTEIO && step == i);
	}
	for (i = 1; i <= guards; i++) {
		reset(); stop_guard = i;
		assert(nvt_uke_boot(&io, image, sizeof(image), false) == -ESHUTDOWN);
		assert(guard_step == i);
	}
	reset(); assert(!nvt_uke_boot(&io, image, sizeof(image), true));
	reset(); hash_bad = true; assert(nvt_uke_boot(&io, image, sizeof(image), false) == -EBADMSG && !step);
	reset(); hash_error = -EIO; assert(nvt_uke_boot(&io, image, sizeof(image), false) == -EIO && !step);
	reset(); hash_error = 1; assert(nvt_uke_boot(&io, image, sizeof(image), false) == -EIO && !step);
	reset(); image[0x28] = 1; assert(nvt_uke_boot(&io, image, sizeof(image), false) == -EINVAL && !step && !hashes); layout();
	assert(nvt_uke_validate_image(&io, image, sizeof(image) - 1) == -EINVAL);
	reset(); foreign = true; assert(nvt_uke_boot(&io, image, sizeof(image), false) == -ENODEV && !bank_writes);
	reset(); single = true; assert(nvt_uke_boot(&io, image, sizeof(image), false) == -ENODEV && !bank_writes);
	reset(); corrupt_bank = true; assert(nvt_uke_boot(&io, image, sizeof(image), false) == -EBADMSG && !ready_writes);
	reset(); stuck_copy = true; assert(nvt_uke_boot(&io, image, sizeof(image), false) == -ETIMEDOUT && !ready_writes);
	reset(); stuck_boot = true; assert(nvt_uke_boot(&io, image, sizeof(image), false) == -ETIMEDOUT);
	reset(); bad_metadata = true; assert(nvt_uke_boot(&io, image, sizeof(image), false) == -ENODEV);
	reset(); bad_mode = true; assert(nvt_uke_boot(&io, image, sizeof(image), false) == -EPROTO);
	reset(); invalid.check_ready = NULL; assert(nvt_uke_boot(&invalid, image, sizeof(image), false) == -EINVAL && !step);
	reset(); busy = 2; assert(!nvt_uke_charger(&io, true) && charger_writes == 1 && command_writes == 1);
	reset(); bad_charger = true; assert(nvt_uke_charger(&io, true) == -EPROTO);
	reset(); busy = 100; assert(nvt_uke_charger(&io, true) == -ETIMEDOUT && command_reads == 25);
	reset(); assert(!nvt_uke_read_frame(&io, packet));
	reset(); stop_guard = 2; assert(nvt_uke_read_frame(&io, packet) == -ESHUTDOWN && reads == 1);
	reset(); fail_step = 1; callback_error = 1; assert(nvt_uke_read_frame(&io, packet) == -EIO);
	printf("Kernel-C THP protocol: %u transfer faults and %u panel guard faults refused; frame/layout/loader/command checks passed (host fixtures only).\n", operations, guards);
	return 0;
}
