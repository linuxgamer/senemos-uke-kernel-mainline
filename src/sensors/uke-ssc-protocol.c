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

static int ssc_string(struct ssc_field f, char *out, size_t capacity)
{
	size_t i, size = f.bytes.size;

	if (f.type != 2)
		return -EBADMSG;
	/* Some OEM attribute strings include their final NUL in the wire length. */
	if (size && !f.bytes.data[size - 1])
		size--;
	if (!size || size >= capacity)
		return -EBADMSG;
	for (i = 0; i < size; i++)
		if (f.bytes.data[i] < 32 || f.bytes.data[i] > 126)
			return -EBADMSG;
	memcpy(out, f.bytes.data, size);
	out[size] = 0;
	return 0;
}

static int ssc_attribute(struct uke_ssc_view wire, u32 *id, struct uke_ssc_view *values)
{
	struct ssc_field f;
	unsigned int seen = 0;
	int ret;

	while ((ret = ssc_next(&wire, &f)) > 0) {
		if (f.number == 1) {
			if ((seen & 1) || f.type != 0 || f.integer > 0xffffffffULL)
				return -EBADMSG;
			*id = f.integer;
			seen |= 1;
		} else if (f.number == 2) {
			if ((seen & 2) || f.type != 2)
				return -EBADMSG;
			*values = f.bytes;
			seen |= 2;
		}
	}
	return ret < 0 || seen != 3 ? -EBADMSG : 0;
}

static int ssc_primitive(struct uke_ssc_view wire, struct ssc_field *out)
{
	struct ssc_field f;
	bool seen = false;
	int ret;

	while ((ret = ssc_next(&wire, &f)) > 0) {
		if (f.number > 5)
			continue;
		/* Known attributes use primitive values, never recursive tuples. */
		if (seen || f.number == 1)
			return -EBADMSG;
		*out = f;
		seen = true;
	}
	return ret < 0 || !seen ? -EBADMSG : 0;
}

int uke_ssc_decode_attributes(struct uke_ssc_view wire, const char *datatype,
			      const char *api, struct uke_ssc_attributes *out)
{
	const u32 required = (1U << 0) | (1U << 2) | (1U << 3) | (1U << 5) | (1U << 16);
	const u32 known = required | (1U << 6) | (1U << 21) | (1U << 30);
	struct uke_ssc_attributes value = {};
	struct uke_ssc_view list = {};
	struct ssc_field f, entry, primitive;
	char text[129];
	u32 seen = 0, id = 0;
	unsigned int count;
	bool api_seen = false;
	int ret, next;

	if (!ssc_output(wire, out, sizeof(*out)) || !datatype || !api ||
	    !strnlen(datatype, 65) || strnlen(datatype, 65) > 64 ||
	    !strnlen(api, 129) || strnlen(api, 129) > 128)
		return -EINVAL;
	while ((ret = ssc_next(&wire, &f)) > 0) {
		if (f.number != 1)
			continue;
		if (f.type != 2 || ssc_attribute(f.bytes, &id, &list))
			return -EBADMSG;
		if (id > 30 || !(known & (1U << id)))
			continue;
		if (seen & (1U << id))
			return -EBADMSG;
		seen |= 1U << id;
		count = 0;
		while ((next = ssc_next(&list, &entry)) > 0) {
			if (entry.number != 1)
				continue;
			if (entry.type != 2 || ++count > UKE_SSC_RATES_MAX ||
			    ssc_primitive(entry.bytes, &primitive))
				return -EBADMSG;
			if (id != 5 && id != 6 && count != 1)
				return -EBADMSG;
			if (id == 0 || id == 2 || id == 5) {
				if (primitive.number != 2 || ssc_string(primitive, text, sizeof(text)))
					return -EBADMSG;
				if (id == 0)
					memcpy(value.name, text, strlen(text) + 1);
				else if (id == 2) {
					if (strlen(text) >= sizeof(value.datatype))
						return -EBADMSG;
					memcpy(value.datatype, text, strlen(text) + 1);
				} else {
					api_seen |= !strcmp(text, api);
				}
			} else if (id == 3 || id == 21 || id == 30) {
				if (primitive.number != 5 || primitive.type != 0 || primitive.integer > 1)
					return -EBADMSG;
				if (id == 3)
					value.available = primitive.integer;
				else if (id == 21)
					value.physical = primitive.integer;
				else
					value.hlos_incompatible = primitive.integer;
			} else if (id == 16) {
				if (primitive.number != 4 || primitive.type != 1 || primitive.integer > 2)
					return -EBADMSG;
				value.stream_type = primitive.integer;
			} else if (id == 6) {
				if (primitive.number != 3 || primitive.type != 5 ||
				    !ssc_finite(primitive.integer) || !(primitive.integer & 0x7fffffffU) ||
				    (primitive.integer & 0x80000000U))
					return -EBADMSG;
				value.rate[value.rate_count++] = primitive.integer;
			}
		}
		if (next < 0 || !count)
			return -EBADMSG;
	}
	if (ret < 0 || (seen & required) != required)
		return -EBADMSG;
	if (strcmp(value.datatype, datatype) || !api_seen)
		return -ENOMSG;
	*out = value;
	return 0;
}

struct ssc_writer { u8 data[UKE_SSC_REQUEST_MAX]; size_t size; };

int uke_ssc_decode_proximity(struct uke_ssc_view wire, bool sar,
			     struct uke_ssc_proximity *out)
{
	struct uke_ssc_proximity value = {};
	struct ssc_field f;
	unsigned int seen = 0, bit;
	int ret;

	if (!ssc_output(wire, out, sizeof(*out)))
		return -EINVAL;
	while ((ret = ssc_next(&wire, &f)) > 0) {
		if (f.number > 3)
			continue;
		bit = 1U << (f.number - 1);
		if (seen & bit)
			return -EBADMSG;
		seen |= bit;
		if (f.number == 2 && sar) {
			/* SAR's additional payload is vendor bytes, never interpreted as ADC. */
			if (f.type != 2)
				return -EBADMSG;
			continue;
		}
		if (f.type != 0 || f.integer > (f.number == 1 ? 1 : f.number == 3 ? 3 : 0xffffffffULL))
			return -EBADMSG;
		if (f.number == 1)
			value.near = f.integer;
		else if (f.number == 2) {
			value.adc = f.integer;
			value.has_adc = true;
		} else {
			value.status = f.integer;
		}
	}
	if (ret < 0 || (seen & (sar ? 5U : 7U)) != (sar ? 5U : 7U))
		return -EBADMSG;
	*out = value;
	return 0;
}

static void ssc_put(struct ssc_writer *w, u64 value, unsigned int bytes)
{
	while (bytes--) {
		w->data[w->size++] = value;
		value >>= 8;
	}
}

static void ssc_put_varint(struct ssc_writer *w, u64 value)
{
	do {
		u8 byte = value & 127;

		value >>= 7;
		ssc_put(w, byte | (value ? 128 : 0), 1);
	} while (value);
}

static void ssc_put_bytes(struct ssc_writer *w, unsigned int field,
			  const void *data, size_t bytes)
{
	ssc_put_varint(w, (field << 3) | 2);
	ssc_put_varint(w, bytes);
	if (bytes)
		memcpy(w->data + w->size, data, bytes);
	w->size += bytes;
}

int uke_ssc_encode_request(enum uke_ssc_command command, struct uke_ssc_suid suid,
			   const char *datatype, u32 rate_bits,
			   u8 *out, size_t capacity, size_t *bytes)
{
	struct ssc_writer client = {}, uid = {}, standard = {}, payload = {};
	const u8 suspend[] = { 8, 1, 16, command <= UKE_SSC_ATTRIBUTES ? 0 : 1 };
	static const u32 message[] = { 512, 1, 513, 514, 10 };
	size_t name_size = datatype ? strnlen(datatype, 65) : 0;
	unsigned long a = (unsigned long)out, b = (unsigned long)bytes;
	unsigned int i;

	if (!out || !bytes || (unsigned int)command > UKE_SSC_DISABLE)
		return -EINVAL;
	if (command == UKE_SSC_LOOKUP) {
		if (!name_size || name_size > 64 || rate_bits ||
		    suid.low != 0xababababababababULL || suid.high != suid.low)
			return -EINVAL;
		for (i = 0; i < name_size; i++)
			if (!((datatype[i] >= 'a' && datatype[i] <= 'z') || datatype[i] == '_'))
				return -EINVAL;
		ssc_put_bytes(&payload, 1, datatype, name_size);
		ssc_put(&payload, 0x0110, 2); /* register_updates = true */
		ssc_put(&payload, 0x0018, 2); /* default_only = false */
	} else if (name_size) {
		return -EINVAL;
	}
	if (command == UKE_SSC_STREAM) {
		if (!ssc_finite(rate_bits) || !rate_bits || (rate_bits & 0x80000000U))
			return -EINVAL;
		ssc_put(&payload, 0x0d, 1);
		ssc_put(&payload, rate_bits, 4);
	} else if (rate_bits) {
		return -EINVAL;
	}
	if (payload.size)
		ssc_put_bytes(&standard, 2, payload.data, payload.size);
	ssc_put(&uid, 0x09, 1); ssc_put(&uid, suid.low, 8);
	ssc_put(&uid, 0x11, 1); ssc_put(&uid, suid.high, 8);
	ssc_put_bytes(&client, 1, uid.data, uid.size);
	ssc_put(&client, 0x15, 1); ssc_put(&client, message[command], 4);
	ssc_put_bytes(&client, 3, suspend, sizeof(suspend));
	/* Empty standard requests deliberately omit their optional payload field. */
	ssc_put_bytes(&client, 4, standard.data, standard.size);
	if (capacity < client.size)
		return -ENOSPC;
	if (a < b ? b - a < client.size : a - b < sizeof(*bytes))
		return -EINVAL;
	memcpy(out, client.data, client.size);
	*bytes = client.size;
	return 0;
}
