// SPDX-License-Identifier: GPL-2.0-only OR MIT
/*
 * Bounded native SSC decoding. Protocol: Qualcomm sensinghub commit
 * 329551963bcc063f6a89f6cbca259c5b5c9c4e0b, apis/proto/{sns_client,
 * sns_std_sensor,sns_suid,sns_std_type}.proto (BSD-3-Clause-Clear).
 * Compared with the project's MIT ssc-discovery.cpp and ssc-sample.cpp.
 * This implementation contains no generated protobuf code or floating point.
 */
#include <linux/errno.h>
#include <linux/string.h>
#include "uke-ssc-protocol.h"

struct ssc_field {
	u32 number, type;
	u64 integer;
	struct uke_ssc_view bytes;
};

static u64 ssc_le(const u8 *data, unsigned int bytes)
{
	u64 value = 0;
	unsigned int i;

	for (i = 0; i < bytes; i++)
		value |= (u64)data[i] << (8 * i);
	return value;
}

static int ssc_varint(struct uke_ssc_view *wire, u64 *out)
{
	u64 value = 0;
	unsigned int i;
	u8 byte;

	for (i = 0; i < 10; i++) {
		if (!wire->size)
			return -EBADMSG;
		byte = *wire->data++;
		wire->size--;
		if (i == 9 && byte > 1)
			return -EBADMSG;
		value |= (u64)(byte & 127) << (7 * i);
		if (!(byte & 128)) {
			*out = value;
			return 0;
		}
	}
	return -EBADMSG;
}

static int ssc_next(struct uke_ssc_view *wire, struct ssc_field *field)
{
	u64 key, size;
	int ret;

	if (!wire->size)
		return 0;
	ret = ssc_varint(wire, &key);
	if (ret || key < 8 || key > 0xffffffffULL)
		return -EBADMSG;
	*field = (struct ssc_field){ .number = key >> 3, .type = key & 7 };
	if (!field->type) {
		ret = ssc_varint(wire, &field->integer);
		return ret ? ret : 1;
	}
	if (field->type == 2) {
		ret = ssc_varint(wire, &size);
		if (ret)
			return ret;
	} else if (field->type == 1 || field->type == 5) {
		size = field->type == 1 ? 8 : 4;
	} else {
		return -EBADMSG;
	}
	if (size > wire->size)
		return -EBADMSG;
	field->bytes = (struct uke_ssc_view){ wire->data, (size_t)size };
	if (field->type != 2)
		field->integer = ssc_le(wire->data, size);
	wire->data += size;
	wire->size -= size;
	return 1;
}

static bool ssc_valid(struct uke_ssc_view wire)
{
	return wire.data && wire.size <= UKE_SSC_MESSAGE_MAX;
}

static bool ssc_output(struct uke_ssc_view wire, const void *out, size_t size)
{
	unsigned long a = (unsigned long)wire.data, b = (unsigned long)out;

	if (!ssc_valid(wire) || !out)
		return false;
	/* Do not overwrite borrowed input bytes or rely on wrapping end pointers. */
	return a < b ? b - a >= wire.size : a - b >= size;
}

static bool ssc_same(struct uke_ssc_suid a, struct uke_ssc_suid b)
{
	return a.low == b.low && a.high == b.high;
}

static int ssc_suid(struct uke_ssc_view wire, struct uke_ssc_suid *out)
{
	struct uke_ssc_suid value = {};
	struct ssc_field f;
	unsigned int seen = 0, bit;
	int ret;

	while ((ret = ssc_next(&wire, &f)) > 0) {
		if (f.number != 1 && f.number != 2)
			continue;
		bit = 1U << (f.number - 1);
		if (f.type != 1 || (seen & bit))
			return -EBADMSG;
		seen |= bit;
		if (f.number == 1)
			value.low = f.integer;
		else
			value.high = f.integer;
	}
	if (ret < 0 || seen != 3)
		return -EBADMSG;
	*out = value;
	return 0;
}

static int ssc_event(struct uke_ssc_view wire, struct uke_ssc_event *out)
{
	struct uke_ssc_event value = {};
	struct ssc_field f;
	unsigned int seen = 0, bit;
	int ret;

	while ((ret = ssc_next(&wire, &f)) > 0) {
		if (f.number > 3)
			continue;
		bit = 1U << (f.number - 1);
		if ((seen & bit) || f.type != (f.number == 1 ? 5 : f.number == 2 ? 1 : 2))
			return -EBADMSG;
		seen |= bit;
		if (f.number == 1)
			value.message = f.integer;
		else if (f.number == 2)
			value.ticks = f.integer;
		else
			value.payload = f.bytes;
	}
	if (ret < 0 || seen != 7)
		return -EBADMSG;
	*out = value;
	return 0;
}

int uke_ssc_decode_events(struct uke_ssc_view wire, struct uke_ssc_suid expected,
			 struct uke_ssc_events *out)
{
	struct uke_ssc_events value = {};
	struct uke_ssc_suid actual;
	struct ssc_field f;
	bool seen = false;
	int ret;

	if (!ssc_output(wire, out, sizeof(*out)))
		return -EINVAL;
	while ((ret = ssc_next(&wire, &f)) > 0) {
		if (f.number == 1) {
			if (seen || f.type != 2 || ssc_suid(f.bytes, &actual))
				return -EBADMSG;
			if (!ssc_same(actual, expected))
				return -ENOMSG;
			seen = true;
		} else if (f.number == 2) {
			if (f.type != 2 || value.count == UKE_SSC_EVENTS_MAX ||
			    ssc_event(f.bytes, &value.event[value.count]))
				return -EBADMSG;
			value.count++;
		}
	}
	if (ret < 0 || !seen || !value.count)
		return -EBADMSG;
	*out = value;
	return 0;
}

static bool ssc_finite(u32 value)
{
	return (value & 0x7f800000U) != 0x7f800000U;
}

int uke_ssc_decode_sample(struct uke_ssc_view wire, unsigned int dimensions,
			 struct uke_ssc_sample *out)
{
	struct uke_ssc_sample value = {};
	struct ssc_field f;
	size_t offset;
	bool seen = false;
	u32 number;
	int ret;

	if (!ssc_output(wire, out, sizeof(*out)) || dimensions > UKE_SSC_VALUES_MAX)
		return -EINVAL;
	while ((ret = ssc_next(&wire, &f)) > 0) {
		if (f.number == 2) {
			if (seen || f.type != 0 || f.integer > 3)
				return -EBADMSG;
			value.status = f.integer;
			seen = true;
		} else if (f.number == 1) {
			if ((f.type != 2 && f.type != 5) || f.bytes.size % 4)
				return -EBADMSG;
			for (offset = 0; offset < f.bytes.size; offset += 4) {
				if (value.count == UKE_SSC_VALUES_MAX)
					return -EBADMSG;
				number = ssc_le(f.bytes.data + offset, 4);
				if (!ssc_finite(number))
					return -EBADMSG;
				value.value[value.count++] = number;
			}
		}
	}
	if (ret < 0 || !seen || !value.count || (dimensions && value.count != dimensions))
		return -EBADMSG;
	*out = value;
	return 0;
}

int uke_ssc_decode_suids(struct uke_ssc_view wire, const char *datatype,
			struct uke_ssc_suids *out)
{
	struct uke_ssc_suids value = {};
	struct uke_ssc_suid actual;
	struct ssc_field f;
	size_t name_size;
	unsigned int i;
	bool seen = false;
	int ret;

	if (!ssc_output(wire, out, sizeof(*out)) || !datatype)
		return -EINVAL;
	name_size = strnlen(datatype, 65);
	if (!name_size || name_size > 64)
		return -EINVAL;
	while ((ret = ssc_next(&wire, &f)) > 0) {
		if (f.number == 1) {
			if (seen || f.type != 2)
				return -EBADMSG;
			if (f.bytes.size != name_size || memcmp(f.bytes.data, datatype, name_size))
				return -ENOMSG;
			seen = true;
		} else if (f.number == 2) {
			if (f.type != 2 || value.count == UKE_SSC_SUIDS_MAX || ssc_suid(f.bytes, &actual))
				return -EBADMSG;
			for (i = 0; i < value.count; i++)
				if (ssc_same(actual, value.suid[i]))
					return -EBADMSG;
			value.suid[value.count++] = actual;
		}
	}
	if (ret < 0 || !seen)
		return -EBADMSG;
	*out = value;
	return 0;
}

int uke_ssc_fixed(u32 ieee754, u32 multiplier, s64 *out)
{
	u64 magnitude, limit;
	unsigned int exponent = (ieee754 >> 23) & 255;
	bool negative = ieee754 >> 31;
	int shift;

	if (!out || !ssc_finite(ieee754))
		return -EINVAL;
	/* A 24-bit significand times a 32-bit multiplier fits in u64. */
	magnitude = ((ieee754 & 0x7fffffU) | (exponent ? 0x800000U : 0)) * (u64)multiplier;
	shift = (exponent ? (int)exponent - 127 : -126) - 23;
	limit = negative ? 1ULL << 63 : (1ULL << 63) - 1;
	if (shift >= 0) {
		if (magnitude && (shift >= 64 || magnitude > (limit >> shift)))
			return -ERANGE;
		magnitude = magnitude ? magnitude << shift : 0;
	} else {
		magnitude = shift <= -64 ? 0 : magnitude >> -shift;
		if (magnitude > limit)
			return -ERANGE;
	}
	/* Avoid signed negation overflow for the exactly representable S64_MIN. */
	*out = negative ? -(s64)(magnitude - !!magnitude) - !!magnitude : (s64)magnitude;
	return 0;
}
