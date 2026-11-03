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

static void attribute(struct bytes *root, unsigned int id, const struct bytes *primitive)
{
	struct bytes values = {}, a = {};
	field(&values, 1, primitive->data, primitive->size);
	integer(&a, 1, id); field(&a, 2, values.data, values.size);
	field(root, 1, a.data, a.size);
}

static struct bytes metadata(void)
{
	struct bytes root = {}, p = {};
	field(&p, 2, "Synthetic motion", 16); attribute(&root, 0, &p);
	p.size = 0; field(&p, 2, "accel", 5); attribute(&root, 2, &p);
	p.size = 0; integer(&p, 5, 1); attribute(&root, 3, &p);
	attribute(&root, 21, &p);
	p.size = 0; field(&p, 2, "sns_accel.proto", 15); attribute(&root, 5, &p);
	p.size = 0; fixed(&p, 3, 0x41200000, 4); attribute(&root, 6, &p);
	p.size = 0; fixed(&p, 4, 0, 8); attribute(&root, 16, &p);
	return root;
}

static void attributes(void)
{
	struct bytes b = metadata(), p = {}, changed;
	struct uke_ssc_attributes out, before;
	unsigned int i;
	assert(!uke_ssc_decode_attributes(view(&b), "accel", "sns_accel.proto", &out));
	assert(!strcmp(out.name, "Synthetic motion") && !strcmp(out.datatype, "accel"));
	assert(out.available && out.physical && !out.hlos_incompatible && !out.stream_type);
	assert(out.rate_count == 1 && out.rate[0] == 0x41200000);
	before = out;
	assert(uke_ssc_decode_attributes(view(&b), "gyro", "sns_accel.proto", &out) == -ENOMSG);
	assert(uke_ssc_decode_attributes(view(&b), "accel", "sns_gyro.proto", &out) == -ENOMSG);
	assert(!memcmp(&out, &before, sizeof(out)));
	for (i = 0; i < b.size; i++) {
		assert(uke_ssc_decode_attributes((struct uke_ssc_view){b.data, i}, "accel", "sns_accel.proto", &out));
		assert(!memcmp(&out, &before, sizeof(out)));
	}
	integer(&p, 5, 0); attribute(&b, 30, &p);
	assert(!uke_ssc_decode_attributes(view(&b), "accel", "sns_accel.proto", &out) && !out.hlos_incompatible);
	b = metadata(); p.size = 0; integer(&p, 5, 1); attribute(&b, 30, &p);
	assert(!uke_ssc_decode_attributes(view(&b), "accel", "sns_accel.proto", &out) && out.hlos_incompatible);
	/* A duplicate attribute never silently changes availability. */
	attribute(&b, 3, &p);
	assert(uke_ssc_decode_attributes(view(&b), "accel", "sns_accel.proto", &out));
	/* Unknown attributes are framed, without assigning their vendor semantics. */
	b = metadata(); p.size = 0; integer(&p, 5, 1); attribute(&b, 500, &p);
	assert(!uke_ssc_decode_attributes(view(&b), "accel", "sns_accel.proto", &out));
	b = metadata(); changed = b;
	assert(uke_ssc_decode_attributes(view(&b), "accel", "sns_accel.proto", (struct uke_ssc_attributes *)b.data) == -EINVAL);
	assert(!memcmp(b.data, changed.data, b.size));
}

static void requests(void)
{
	static const u8 expected[] = {
		0x0a,0x12,0x09,0x23,0x01,0,0,0,0,0,0,0x11,0x56,0x04,0,0,0,0,0,0,
		0x15,1,0,0,0,0x1a,4,8,1,16,0,0x22,0
	};
	u8 out[256], saved[256];
	size_t size, keep;
	struct uke_ssc_suid sensor = {0x123,0x456}, lookup = {0xababababababababULL,0xababababababababULL};
	unsigned int command;
	memset(out, 0xa5, sizeof(out)); size = 999;
	assert(!uke_ssc_encode_request(UKE_SSC_ATTRIBUTES, sensor, NULL, 0, out, sizeof(out), &size));
	assert(size == sizeof(expected) && !memcmp(out, expected, size) && out[size] == 0xa5);
	for (command = UKE_SSC_ATTRIBUTES; command <= UKE_SSC_DISABLE; command++) {
		u32 message[] = {512,1,513,514,10};
		assert(!uke_ssc_encode_request(command, sensor, NULL, command == UKE_SSC_STREAM ? 0x41200000 : 0, out, sizeof(out), &size));
		assert(out[20] == 0x15 && !memcmp(out, expected, 20));
		assert(out[21] == (message[command] & 255) && out[22] == (message[command] >> 8));
		assert(out[30] == (command == UKE_SSC_ATTRIBUTES ? 0 : 1));
		if (command == UKE_SSC_STREAM) {
			const u8 tail[] = {0x22,7,0x12,5,0x0d,0,0,0x20,0x41};
			assert(size == 40 && !memcmp(out + 31, tail, sizeof(tail)));
		} else assert(size == sizeof(expected) && !out[32]);
	}
	assert(!uke_ssc_encode_request(UKE_SSC_LOOKUP, lookup, "accel", 0, out, sizeof(out), &size));
	const u8 lookup_tail[] = {0x22,13,0x12,11,0x0a,5,'a','c','c','e','l',0x10,1,0x18,0};
	assert(size == 46 && !memcmp(out + 31, lookup_tail, sizeof(lookup_tail)));
	memcpy(saved, out, sizeof(out)); keep = size;
	assert(uke_ssc_encode_request(UKE_SSC_LOOKUP, lookup, "accel", 0, out, size - 1, &size) == -ENOSPC);
	assert(size == keep && !memcmp(out, saved, sizeof(out)));
	assert(uke_ssc_encode_request(UKE_SSC_LOOKUP, sensor, "accel", 0, out, sizeof(out), &size) == -EINVAL);
	assert(uke_ssc_encode_request(UKE_SSC_LOOKUP, lookup, "accel/foreign", 0, out, sizeof(out), &size) == -EINVAL);
	assert(uke_ssc_encode_request(UKE_SSC_STREAM, sensor, NULL, 0x7f800000, out, sizeof(out), &size) == -EINVAL);
	assert(uke_ssc_encode_request(UKE_SSC_STREAM, sensor, NULL, 0xbf800000, out, sizeof(out), &size) == -EINVAL);
	assert(uke_ssc_encode_request(UKE_SSC_ATTRIBUTES, sensor, "accel", 0, out, sizeof(out), &size) == -EINVAL);
	assert(uke_ssc_encode_request(UKE_SSC_DISABLE + 1, sensor, NULL, 0, out, sizeof(out), &size) == -EINVAL);
	assert(uke_ssc_encode_request(UKE_SSC_ATTRIBUTES, sensor, NULL, 0, out, sizeof(out), (size_t *)out) == -EINVAL);
	assert(!memcmp(out, saved, sizeof(out)));
}

static void proximity(void)
{
	struct bytes b = {};
	struct uke_ssc_proximity out, before;
	unsigned int i;
	integer(&b, 1, 1); integer(&b, 2, 12345); integer(&b, 3, 3);
	assert(!uke_ssc_decode_proximity(view(&b), false, &out));
	assert(out.near && out.has_adc && out.adc == 12345 && out.status == 3);
	before = out;
	for (i = 0; i < b.size; i++) {
		assert(uke_ssc_decode_proximity((struct uke_ssc_view){b.data, i}, false, &out));
		assert(!memcmp(&out, &before, sizeof(out)));
	}
	integer(&b, 1, 0); assert(uke_ssc_decode_proximity(view(&b), false, &out));
	b.size = 0; integer(&b, 1, 2); integer(&b, 2, 0); integer(&b, 3, 3);
	assert(uke_ssc_decode_proximity(view(&b), false, &out));
	b.size = 0; integer(&b, 1, 0); integer(&b, 3, 0);
	assert(!uke_ssc_decode_proximity(view(&b), true, &out));
	assert(!out.near && !out.has_adc && !out.status);
	field(&b, 2, "vendor bytes", 12);
	assert(!uke_ssc_decode_proximity(view(&b), true, &out) && !out.has_adc);
	assert(uke_ssc_decode_proximity(view(&b), false, &out));
	b.size = 0; integer(&b, 1, 0); integer(&b, 2, 0x100000000ULL); integer(&b, 3, 3);
	assert(uke_ssc_decode_proximity(view(&b), false, &out));
}
int main(void)
{
	samples(); events(); discovery(); numeric(); malformed(); attributes(); requests(); proximity();
	puts("SSC native decoder: bounded SUID/event/sample parsing, packed floats, unchanged failures and 30000 independent numeric comparisons passed; synthetic host data only");
	puts("SSC native metadata and requests: exact API/type, availability, physical/stream fields, rates, APSS delivery, disable, golden bytes and unchanged rejection checks passed");
	return 0;
}
