/* SPDX-License-Identifier: MIT */
#ifndef O82_COLOR_FIRMWARE_H
#define O82_COLOR_FIRMWARE_H

#include "uke-o82-hdr-format.h"
#include "o82-sixzone-format.h"
#include "o82-hsic-format.h"
#include "o82-memory-format.h"

/* Private little-endian bundle; names and all active operations stay distinct. */
#define O82_COLOR_FW_MAGIC "O82COLR4"
#define O82_COLOR_FW_VERSION 4
#define O82_COLOR_FW_MEMORY_MAGIC "O82COLR5"
#define O82_COLOR_FW_MEMORY_VERSION 5
#define O82_COLOR_FW_HEADER 96
#define O82_COLOR_FW_RECORD 160
#define O82_COLOR_FW_LIMIT (8 * 1024 * 1024)
#define O82_COLOR_FW_MAX_PRESETS 64
#define O82_COLOR_FW_CURVE_BYTES (257 * 3 * 2)
#define O82_COLOR_FW_CUBE_BYTES (4913 * 3 * 2)
#define O82_COLOR_FW_GC_BYTES (1024 * 3 * 2)
#define O82_COLOR_FW_DATA_BYTES (2 * O82_COLOR_FW_CURVE_BYTES + \
		2 * O82_COLOR_FW_CUBE_BYTES + O82_COLOR_FW_GC_BYTES)

#define O82_COLOR_OP_IGC 1U
#define O82_COLOR_OP_GAMUT 2U
#define O82_COLOR_OP_GC 4U
#define O82_COLOR_OP_HSIC 8U
#define O82_COLOR_OP_SIXZONE 16U
#define O82_COLOR_OP_MEMORY 32U
#define O82_COLOR_OP_HDR 64U
#define O82_COLOR_OP_DITHER 128U

#define O82_COLOR_BLOCK_HSIC 1U
#define O82_COLOR_BLOCK_SIXZONE 2U
#define O82_COLOR_BLOCK_MEMORY 4U
#define O82_COLOR_BLOCK_HDR 8U

static inline const unsigned char *o82_color_fw_record(const unsigned char *data,
		unsigned int index)
{
	return data + O82_COLOR_FW_HEADER + index * O82_COLOR_FW_RECORD;
}

static inline int o82_color_fw_zero(const unsigned char *data, unsigned int length)
{
	unsigned int i;

	for (i = 0; i < length; i++)
		if (data[i])
			return 0;
	return 1;
}

static inline int o82_color_fw_name(const unsigned char *record)
{
	unsigned int i;

	for (i = 0; i < 64 && record[i]; i++)
		if (!((record[i] >= 'a' && record[i] <= 'z') ||
		      (record[i] >= 'A' && record[i] <= 'Z') ||
		      (record[i] >= '0' && record[i] <= '9') ||
		      record[i] == '_' || record[i] == ' '))
			return 0;
	return i && i < 64 && record[0] != ' ' && record[i - 1] != ' ' &&
		o82_color_fw_zero(record + i, 64 - i);
}

static inline int o82_color_fw_tables(const unsigned char *data)
{
	unsigned int curve, channel, i, previous, value;

	for (curve = 0; curve < 2; curve++) {
		for (channel = 0; channel < 3; channel++) {
			previous = 0;
			for (i = 0; i < 257; i++) {
				value = o82_hdr_u16(data + (i * 3 + channel) * 2);
				if (value > 4095 || value < previous || (!i && value))
					return 0;
				previous = value;
			}
			if (previous != 4095)
				return 0;
		}
		data += O82_COLOR_FW_CURVE_BYTES;
	}
	for (i = 0; i < 2 * 4913 * 3; i++)
		if (o82_hdr_u16(data + i * 2) > 4095)
			return 0;
	data += 2 * O82_COLOR_FW_CUBE_BYTES;
	for (channel = 0; channel < 3; channel++) {
		previous = 0;
		for (i = 0; i < 1024; i++) {
			value = o82_hdr_u16(data + (i * 3 + channel) * 2);
			if (value > 1023 || value < previous)
				return 0;
			previous = value;
		}
	}
	return 1;
}

static inline int o82_color_fw_valid(const unsigned char *data,
		unsigned long length, unsigned int panel)
{
	static const unsigned char hashes[2][32] = {
		{0xbd,0x88,0xeb,0x94,0x13,0x4e,0x5f,0x62,0xc0,0x5e,0xeb,0xaa,0x0a,0x9e,0x4b,0x52,
		 0x67,0x96,0x83,0x63,0xf7,0x2f,0x44,0x00,0x18,0xb9,0x8a,0x15,0xd1,0xbd,0x91,0x22},
		{0x2b,0x64,0x42,0xce,0x0e,0x8f,0xef,0x6d,0x1b,0x00,0x8c,0xde,0xca,0x38,0x38,0x45,
		 0x02,0x82,0x86,0x8d,0x38,0x5f,0x6e,0x30,0x56,0xc0,0xa4,0xce,0x2b,0x89,0x49,0xd8},
	};
	const unsigned char *record, *previous = 0;
	unsigned int i, count, cursor, size, offset, flags, blocked, version;

	if (!data || length < O82_COLOR_FW_HEADER || length > O82_COLOR_FW_LIMIT ||
	    (panel != 0x36 && panel != 0x42))
		return 0;
	version = o82_hdr_u32(data + 8);
	if (version != O82_COLOR_FW_VERSION && version != O82_COLOR_FW_MEMORY_VERSION)
		return 0;
	for (i = 0; i < 8; i++)
		if (data[i] != (version == O82_COLOR_FW_VERSION ?
			       O82_COLOR_FW_MAGIC[i] : O82_COLOR_FW_MEMORY_MAGIC[i]))
			return 0;
	if (o82_hdr_u32(data + 12) != panel || o82_hdr_u32(data + 16) != length ||
	    o82_hdr_u32(data + 28) != O82_COLOR_FW_RECORD ||
	    o82_hdr_u32(data + 64) != O82_HDR_NOMINAL_PEAK_NITS ||
	    o82_hdr_u32(data + 68) != O82_HDR_NOMINAL_BLACK_10000 ||
	    !o82_color_fw_zero(data + 76, 20))
		return 0;
	for (i = 0; i < 32; i++)
		if (data[32 + i] != hashes[panel == 0x42][i])
			return 0;
	count = o82_hdr_u32(data + 24);
	if (!count || count > O82_COLOR_FW_MAX_PRESETS)
		return 0;
	cursor = O82_COLOR_FW_HEADER + count * O82_COLOR_FW_RECORD;
	if (cursor > length || o82_hdr_u32(data + 72) != cursor ||
	    o82_hdr_u32(data + 20) != o82_hdr_crc32(data + 24, length - 24))
		return 0;
	for (i = 0; i < count; i++) {
		unsigned int at;

		record = o82_color_fw_record(data, i);
		if (!o82_color_fw_name(record) || o82_hdr_u32(record + 64) > 1 ||
		    o82_hdr_u32(record + 68) > 1 ||
		    (version == O82_COLOR_FW_VERSION && !o82_color_fw_zero(record + 152, 8)) ||
		    o82_color_fw_zero(record + 96, 32))
			return 0;
		if (previous) {
			for (at = 0; at < 64 && previous[at] == record[at]; at++)
				;
			if (at == 64 || previous[at] >= record[at])
				return 0;
		}
		previous = record;
		flags = o82_hdr_u32(record + 72);
		blocked = o82_hdr_u32(record + 76);
		if ((flags & ~255U) || (blocked & ~14U) ||
		    (flags & (O82_COLOR_OP_IGC | O82_COLOR_OP_GC)) !=
		    (O82_COLOR_OP_IGC | O82_COLOR_OP_GC) ||
		    (version == O82_COLOR_FW_VERSION &&
		     (!!(flags & O82_COLOR_OP_MEMORY) != !!(blocked & O82_COLOR_BLOCK_MEMORY))) ||
		    (version == O82_COLOR_FW_MEMORY_VERSION && (blocked & O82_COLOR_BLOCK_MEMORY)) ||
		    (!!(flags & O82_COLOR_OP_HDR) != !!(blocked & O82_COLOR_BLOCK_HDR)) ||
		    ((blocked & O82_COLOR_BLOCK_SIXZONE) && !(flags & O82_COLOR_OP_SIXZONE)) ||
		    (o82_hdr_u32(record + 68) && !(flags & O82_COLOR_OP_HDR)) ||
		    o82_hdr_u32(record + 128) > 1 || o82_hdr_u32(record + 132) > 15 ||
		    (!!(flags & O82_COLOR_OP_DITHER) != !!o82_hdr_u32(record + 128)) ||
		    (!o82_hdr_u32(record + 128) && o82_hdr_u32(record + 132)))
			return 0;
		offset = o82_hdr_u32(record + 80);
		size = o82_hdr_u32(record + 84);
		if (blocked) {
			if (offset || size)
				return 0;
		} else {
			if (offset != cursor || size != O82_COLOR_FW_DATA_BYTES || size > length - cursor ||
			    !o82_color_fw_tables(data + cursor))
				return 0;
			cursor += size;
		}
		offset = o82_hdr_u32(record + 136);
		size = o82_hdr_u32(record + 140);
		if (!blocked && (flags & O82_COLOR_OP_SIXZONE)) {
			if (offset != cursor || size > length - cursor ||
			    !o82_sixzone_valid(data + cursor, size))
				return 0;
			cursor += size;
		} else if (offset || size) {
			return 0;
		}
		offset = o82_hdr_u32(record + 144);
		size = o82_hdr_u32(record + 148);
		if (!blocked) {
			if (offset != cursor || size > length - cursor ||
			    !o82_hsic_valid(data + cursor, size) ||
			    (!!(flags & O82_COLOR_OP_HSIC) != !!o82_hdr_u32(data + cursor)))
				return 0;
			cursor += size;
		} else if (offset || size) {
			return 0;
		}
		/* v5 owns all memory/protection state, including an explicit neutral.
		 * Keep v4 inputs absent so their existing PA ownership stays exact.
		 */
		if (version == O82_COLOR_FW_MEMORY_VERSION) {
			offset = o82_hdr_u32(record + 152);
			size = o82_hdr_u32(record + 156);
			if (!blocked) {
				if (offset != cursor || size > length - cursor ||
				    !o82_memory_valid(data + cursor, size) ||
				    (!!(flags & O82_COLOR_OP_MEMORY) !=
				     !!(o82_hdr_u32(data + cursor) | o82_hdr_u32(data + cursor + 4))))
					return 0;
				cursor += size;
			} else if (offset || size) {
				return 0;
			}
		}
		offset = o82_hdr_u32(record + 88);
		size = o82_hdr_u32(record + 92);
		if (offset != cursor || !size || size > 2 * 1024 * 1024 || size > length - cursor)
			return 0;
		cursor += size;
	}
	return cursor == length;
}

/* Index selection is transactional and never aliases an unsupported preset. */
static inline const unsigned char *o82_color_fw_data(const unsigned char *data,
		unsigned int index, unsigned int bt2020, unsigned int pq,
		const unsigned char **igc, const unsigned char **gc)
{
	const unsigned char *record, *tables;

	/* Only call after validating and retaining the complete bundle. */
	if (!data || !igc || !gc || index >= o82_hdr_u32(data + 24) || bt2020 > 1 || pq > 1)
		return 0;
	record = o82_color_fw_record(data, index);
	if (o82_hdr_u32(record + 76))
		return 0;
	tables = data + o82_hdr_u32(record + 80);
	*igc = tables + pq * O82_COLOR_FW_CURVE_BYTES;
	*gc = tables + 2 * O82_COLOR_FW_CURVE_BYTES + 2 * O82_COLOR_FW_CUBE_BYTES;
	return tables + 2 * O82_COLOR_FW_CURVE_BYTES + bt2020 * O82_COLOR_FW_CUBE_BYTES;
}
#endif
