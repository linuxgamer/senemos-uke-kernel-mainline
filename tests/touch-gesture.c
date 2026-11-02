/* SPDX-License-Identifier: GPL-2.0-or-later */
#include <assert.h>
#include <errno.h>
#include <limits.h>
#include <string.h>
#include <linux/unaligned.h>
#include "../src/input/nt36532-uke-protocol.h"

static unsigned calls, guards, fail_call, stop_guard, setting_writes, command;
static unsigned events[8], event_count;
static bool busy, wrong;
static u16 values[256];
static int ready(void *context)
{
	assert(context == values);
	return ++guards == stop_guard ? -ESHUTDOWN : 0;
}
static int operation(void)
{
	return ++calls == fail_call ? -EREMOTEIO : 0;
}
static void delay(void *context, unsigned int ms)
{
	assert(context == values && (ms == 20 || ms == 35));
}
static int write_data(void *context, u32 address, const void *data, size_t size, bool fast)
{
	const u8 *bytes = data;
	int ret = operation();

	assert(context == values && address == 0x11c450 && !fast);
	if (ret)
		return ret;
	if (size == 5) {
		assert(bytes[0] == 0xbf && !bytes[2]);
		assert(bytes[1] == 0x11 || bytes[1] == 0x1b || bytes[1] == 0x15);
		values[bytes[1]] = get_unaligned_le16(bytes + 3);
		setting_writes++;
		if (!busy)
			events[event_count++] = bytes[1];
	} else if (size == 3) {
		assert(bytes[0] == 0xbf && bytes[2] == 1);
		command = bytes[1];
		events[event_count++] = 0x100 | command;
	} else if (size == 2) {
		assert(!memcmp(data, (u8[]){0x7b, 0}, 2));
		events[event_count++] = 0x7b;
	} else {
		assert(size == 1 && bytes[0] == 0x13);
		events[event_count++] = 0x13;
	}
	assert(event_count <= 6);
	return 0;
}
static int read_data(void *context, u32 address, void *data, size_t size, bool fast)
{
	u8 *bytes = data;
	int ret = operation();

	assert(context == values && address == 0x11c450 && !fast);
	if (ret)
		return ret;
	assert(size == 1 || size == 5);
	memset(data, 0, size);
	bytes[0] = busy ? 0xbf : 0;
	if (size == 5)
		put_unaligned_le16(values[command] ^ wrong, bytes + 3);
	return 0;
}
static const struct nvt_uke_io io = { values, read_data, write_data, ready, delay, NULL, NVT_UKE_CSOT };
static void reset(void)
{
	calls = guards = setting_writes = event_count = command = 0;
	fail_call = stop_guard = UINT_MAX;
	busy = wrong = false;
	memset(values, 0, sizeof(values));
}
static void checksum(u8 *packet)
{
	unsigned int sum = 0;
	for (unsigned int i = 0; i < NVT_UKE_GESTURE_SIZE - 1; i++)
		sum += packet[i];
	packet[NVT_UKE_GESTURE_SIZE - 1] = (u8)-sum;
}
int main(void)
{
	u8 packet[NVT_UKE_GESTURE_SIZE] = { 15 << 3 };
	unsigned int operations, checks;
	const unsigned int sequence[] = { 0x11, 0x111, 0x1b, 0x11b, 0x7b, 0x13 };

	checksum(packet);
	assert(nvt_uke_double_tap(packet, sizeof(packet)) == 1);
	for (unsigned int i = 0; i < sizeof(packet); i++) {
		packet[i] ^= 1;
		assert(nvt_uke_double_tap(packet, sizeof(packet)) == -EBADMSG);
		packet[i] ^= 1;
	}
	for (unsigned int id = 0; id < 32; id++) {
		packet[0] = (u8)(id << 3);
		checksum(packet);
		assert(nvt_uke_double_tap(packet, sizeof(packet)) == (id == 15));
	}
	packet[0] = 30 << 3; packet[1] = 1; packet[2] = 15; checksum(packet);
	assert(nvt_uke_double_tap(packet, sizeof(packet)) == 1);
	packet[1] = 2; checksum(packet);
	assert(!nvt_uke_double_tap(packet, sizeof(packet)));
	for (unsigned int size = 0; size < sizeof(packet); size++)
		assert(nvt_uke_double_tap(packet, size) == -EINVAL);
	assert(nvt_uke_double_tap(NULL, sizeof(packet)) == -EINVAL);

	reset(); assert(!nvt_uke_gesture_enter(&io));
	assert(event_count == 6 && !memcmp(events, sequence, sizeof(sequence)));
	assert(values[0x11] == 1 && !values[0x1b]);
	operations = calls; checks = guards;
	for (unsigned int i = 1; i <= operations; i++) {
		reset(); fail_call = i;
		assert(nvt_uke_gesture_enter(&io) == -EREMOTEIO && calls == i);
	}
	for (unsigned int i = 1; i <= checks; i++) {
		reset(); stop_guard = i;
		assert(nvt_uke_gesture_enter(&io) == -ESHUTDOWN && guards == i);
	}
	reset(); busy = true;
	assert(nvt_uke_gesture_enter(&io) == -ETIMEDOUT && setting_writes == 5);
	reset(); wrong = true;
	assert(nvt_uke_gesture_enter(&io) == -EPROTO && event_count == 2);
	assert(nvt_uke_gesture_enter(NULL) == -EINVAL);

	reset(); assert(!nvt_uke_coordinate_mode(&io, true));
	assert(values[0x15] == 1 && setting_writes == 1 && event_count == 2);
	assert(events[0] == 0x15 && events[1] == 0x115);
	operations = calls; checks = guards;
	for (unsigned int i = 1; i <= operations; i++) {
		reset(); fail_call = i;
		assert(nvt_uke_coordinate_mode(&io, true) == -EREMOTEIO && calls == i);
	}
	for (unsigned int i = 1; i <= checks; i++) {
		reset(); stop_guard = i;
		assert(nvt_uke_coordinate_mode(&io, true) == -ESHUTDOWN && guards == i);
	}
	reset(); values[0x15] = 1;
	assert(!nvt_uke_coordinate_mode(&io, false) && !values[0x15]);
	reset(); busy = true;
	assert(nvt_uke_coordinate_mode(&io, true) == -ETIMEDOUT && setting_writes == 5);
	reset(); wrong = true;
	assert(nvt_uke_coordinate_mode(&io, true) == -EPROTO && event_count == 2);
	assert(nvt_uke_coordinate_mode(NULL, true) == -EINVAL);
}
