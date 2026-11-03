// SPDX-License-Identifier: GPL-2.0-only OR MIT
/* Synthetic wire fixtures and independent host floating-point arithmetic. */
#include <assert.h>
#include <errno.h>
#include <limits.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "uke-ssc-protocol.h"

struct bytes { u8 data[UKE_SSC_MESSAGE_MAX + 32]; size_t size; };
static void put(struct bytes *b, u64 n, unsigned int width)
{
	assert(b->size + width <= sizeof(b->data));
	while (width--) { b->data[b->size++] = n; n >>= 8; }
}
static void varint(struct bytes *b, u64 n)
{
	do { u8 byte = n & 127; n >>= 7; put(b, byte | (n ? 128 : 0), 1); } while (n);
}
static void field(struct bytes *b, unsigned int number, const void *data, size_t size)
{
	varint(b, (number << 3) | 2); varint(b, size);
	assert(b->size + size <= sizeof(b->data));
	if (size) memcpy(b->data + b->size, data, size);
	b->size += size;
}
static void integer(struct bytes *b, unsigned int number, u64 value)
{
	varint(b, number << 3); varint(b, value);
}
static void fixed(struct bytes *b, unsigned int number, u64 value, unsigned int width)
{
	varint(b, (number << 3) | (width == 8 ? 1 : 5)); put(b, value, width);
}
static struct uke_ssc_view view(const struct bytes *b)
{
	return (struct uke_ssc_view){ b->data, b->size };
}
static struct bytes suid(u64 low, u64 high)
{
	struct bytes b = {}; fixed(&b, 1, low, 8); fixed(&b, 2, high, 8); return b;
}
static struct bytes sample(bool packed)
{
	const u32 bits[] = { 0x3f800000, 0xc0200000, 0x00000001 };
	struct bytes b = {}, values = {};
	unsigned int i;
	for (i = 0; i < 3; i++) {
		if (packed) put(&values, bits[i], 4);
		else fixed(&b, 1, bits[i], 4);
	}
	if (packed) field(&b, 1, values.data, values.size);
	integer(&b, 2, 3); return b;
}
static struct bytes event_packet(unsigned int count)
{
	struct bytes b = {}, id = suid(0x123, 0x456), payload = sample(true), e = {};
	unsigned int i;
	field(&b, 1, id.data, id.size);
	for (i = 0; i < count; i++) {
		e.size = 0; fixed(&e, 1, 1025, 4); fixed(&e, 2, 12345 + i, 8);
		field(&e, 3, payload.data, payload.size); field(&b, 2, e.data, e.size);
	}
	return b;
}
static void samples(void)
{
	struct uke_ssc_sample out, before;
	struct bytes b, changed;
	unsigned int i, j;
	for (i = 0; i < 2; i++) {
		b = sample(i); memset(&out, 0xa5, sizeof(out));
		assert(!uke_ssc_decode_sample(view(&b), 3, &out));
		assert(out.count == 3 && out.status == 3 && out.value[0] == 0x3f800000 &&
		       out.value[1] == 0xc0200000 && out.value[2] == 1);
		before = out;
		assert(uke_ssc_decode_sample(view(&b), 2, &out));
		assert(!memcmp(&out, &before, sizeof(out)));
		/* Every truncation removes at least the required final status. */
		for (j = 0; j < b.size; j++) {
			assert(uke_ssc_decode_sample((struct uke_ssc_view){b.data, j}, 3, &out));
			assert(!memcmp(&out, &before, sizeof(out)));
		}
		changed = b; integer(&changed, 2, 1);
		assert(uke_ssc_decode_sample(view(&changed), 3, &out));
		changed = b; changed.data[changed.size - 1] = 4;
		assert(uke_ssc_decode_sample(view(&changed), 3, &out));
	}
	for (i = 0; i < 4; i++) {
		b.size = 0; fixed(&b, 1, 0x7f800000U + i, 4); integer(&b, 2, 3);
		assert(uke_ssc_decode_sample(view(&b), 1, &out));
	}
	b.size = 0;
	for (i = 0; i < UKE_SSC_VALUES_MAX; i++) fixed(&b, 1, i, 4);
	integer(&b, 2, 0);
	assert(!uke_ssc_decode_sample(view(&b), 0, &out) && out.count == UKE_SSC_VALUES_MAX && !out.status);
	fixed(&b, 1, 17, 4); assert(uke_ssc_decode_sample(view(&b), 0, &out));
	b.size = 0; field(&b, 1, "abc", 3); integer(&b, 2, 1);
	assert(uke_ssc_decode_sample(view(&b), 0, &out));
	assert(uke_ssc_decode_sample((struct uke_ssc_view){NULL, 1}, 1, &out) == -EINVAL);
	assert(uke_ssc_decode_sample(view(&b), UKE_SSC_VALUES_MAX + 1, &out) == -EINVAL);
	b = sample(true); changed = b;
	assert(uke_ssc_decode_sample(view(&b), 3, (struct uke_ssc_sample *)b.data) == -EINVAL);
	assert(!memcmp(b.data, changed.data, b.size));
}
static void events(void)
{
	struct uke_ssc_events out, before;
	struct bytes b = event_packet(32), duplicate, id = suid(0x123, 0x456);
	unsigned int i;
	assert(!uke_ssc_decode_events(view(&b), (struct uke_ssc_suid){0x123, 0x456}, &out));
	assert(out.count == 32 && out.event[31].ticks == 12376 && out.event[0].message == 1025);
	assert(out.event[0].payload.data >= b.data && out.event[0].payload.data < b.data + b.size);
	before = out;
	assert(uke_ssc_decode_events(view(&b), (struct uke_ssc_suid){0x124, 0x456}, &out) == -ENOMSG);
	assert(!memcmp(&out, &before, sizeof(out)));
	duplicate = b; field(&duplicate, 1, id.data, id.size);
	assert(uke_ssc_decode_events(view(&duplicate), (struct uke_ssc_suid){0x123, 0x456}, &out));
	b = event_packet(33);
	assert(uke_ssc_decode_events(view(&b), (struct uke_ssc_suid){0x123, 0x456}, &out));
	b = event_packet(1);
	for (i = 0; i < b.size; i++) {
		assert(uke_ssc_decode_events((struct uke_ssc_view){b.data, i}, (struct uke_ssc_suid){0x123, 0x456}, &out));
		assert(!memcmp(&out, &before, sizeof(out)));
	}
	b.data[b.size++] = 0; assert(uke_ssc_decode_events(view(&b), (struct uke_ssc_suid){0x123, 0x456}, &out));
}
static void discovery(void)
{
	struct bytes b = {}, id;
	struct uke_ssc_suids out, before;
	unsigned int i;
	field(&b, 1, "accel", 5);
	assert(!uke_ssc_decode_suids(view(&b), "accel", &out) && !out.count);
	for (i = 0; i < 32; i++) { id = suid(i + 1, i + 100); field(&b, 2, id.data, id.size); }
	assert(!uke_ssc_decode_suids(view(&b), "accel", &out) && out.count == 32 && out.suid[31].low == 32);
	before = out;
	assert(uke_ssc_decode_suids(view(&b), "gyro", &out) == -ENOMSG);
	assert(!memcmp(&out, &before, sizeof(out)));
	field(&b, 2, id.data, id.size); assert(uke_ssc_decode_suids(view(&b), "accel", &out));
	b.size = 0; field(&b, 1, "accel", 5); field(&b, 2, id.data, id.size); field(&b, 2, id.data, id.size);
	assert(uke_ssc_decode_suids(view(&b), "accel", &out));
	b.size = 0; field(&b, 1, "accel", 5); field(&b, 1, "accel", 5);
	assert(uke_ssc_decode_suids(view(&b), "accel", &out));
}
static u32 random_state = 0x20261103;
static u32 random32(void)
{
	u32 x = random_state; x ^= x << 13; x ^= x >> 17; x ^= x << 5; return random_state = x;
}
static void numeric(void)
{
	unsigned int i;
	s64 out, expected;
	const u32 edges[] = {0, 0x80000000, 1, 0x80000001, 0x007fffff, 0x00800000,
		0x3f800000, 0xbf800000, 0x3fc00000, 0xbfc00000, 0x5f000000, 0xdf000000,
		0x5effffff, 0xdeffffff, 0x7f7fffff, 0xff7fffff, 0x7f800000, 0xff800000,
		0x7fc00000, 0x7f800001};
	for (i = 0; i < 30000; i++) {
		u32 bits = i < sizeof(edges)/sizeof(edges[0]) ? edges[i] : random32();
		u32 multiplier = i < 40 ? 1 : random32();
		float scalar; long double number;
		memcpy(&scalar, &bits, 4); out = 123;
		int ret = uke_ssc_fixed(bits, multiplier, &out);
		if (!isfinite(scalar)) { assert(ret == -EINVAL && out == 123); continue; }
		number = truncl((long double)scalar * multiplier);
		if (number < -ldexpl(1, 63) || number >= ldexpl(1, 63)) {
			assert(ret == -ERANGE && out == 123); continue;
		}
		expected = number; assert(!ret && out == expected);
	}
	out = 123; assert(!uke_ssc_fixed(0x7f7fffff, 0, &out) && out == 0);
	assert(uke_ssc_fixed(0, 1, NULL) == -EINVAL);
}
static void malformed(void)
{
	struct bytes b = {};
	struct uke_ssc_events events_out, events_before;
	struct uke_ssc_suids suids_out, suids_before;
	struct uke_ssc_sample sample_out, sample_before;
	unsigned int i, j;
	for (i = 0; i < 20000; i++) {
		b.size = random32() % 256;
		for (j = 0; j < b.size; j++) b.data[j] = random32();
		memset(&events_before, 0xa5, sizeof(events_before)); events_out = events_before;
		if (uke_ssc_decode_events(view(&b), (struct uke_ssc_suid){1, 2}, &events_out))
			assert(!memcmp(&events_out, &events_before, sizeof(events_out)));
		memset(&suids_before, 0xa5, sizeof(suids_before)); suids_out = suids_before;
		if (uke_ssc_decode_suids(view(&b), "accel", &suids_out))
			assert(!memcmp(&suids_out, &suids_before, sizeof(suids_out)));
		memset(&sample_before, 0xa5, sizeof(sample_before)); sample_out = sample_before;
		if (uke_ssc_decode_sample(view(&b), 3, &sample_out))
			assert(!memcmp(&sample_out, &sample_before, sizeof(sample_out)));
	}
	/* Overflowing varint and an oversized admission are explicit checks. */
	memset(b.data, 0xff, 11); b.size = 11;
	assert(uke_ssc_decode_sample(view(&b), 0, &sample_out));
	assert(uke_ssc_decode_sample((struct uke_ssc_view){b.data, UKE_SSC_MESSAGE_MAX + 1}, 0, &sample_out) == -EINVAL);
}
int main(void)
{
	samples(); events(); discovery(); numeric(); malformed();
	puts("SSC native decoder: bounded SUID/event/sample parsing, packed floats, unchanged failures and 30000 independent numeric comparisons passed; synthetic host data only");
	return 0;
}
