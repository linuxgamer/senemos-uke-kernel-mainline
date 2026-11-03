/* SPDX-License-Identifier: MIT */
#ifndef UKE_O82_HDR_FORMAT_H
#define UKE_O82_HDR_FORMAT_H

/* Private, locally generated color data; all integers are little-endian. */
#define O82_HDR_MAGIC "O82HDR10"
#define O82_HDR_VERSION 1
#define O82_HDR_HEADER_SIZE 64
#define O82_HDR_IGC_ENTRIES 257
#define O82_HDR_GAMUT_ENTRIES 4913
#define O82_HDR_GC_ENTRIES 1024
#define O82_HDR_PAYLOAD_SIZE ((2 * O82_HDR_IGC_ENTRIES + O82_HDR_GAMUT_ENTRIES + O82_HDR_GC_ENTRIES) * 3 * 2)
#define O82_HDR_FILE_SIZE (O82_HDR_HEADER_SIZE + O82_HDR_PAYLOAD_SIZE)
/* Exact O82 OEM DT nominal values, not measured luminance or an HBM request. */
#define O82_HDR_NOMINAL_PEAK_NITS 420
#define O82_HDR_NOMINAL_BLACK_10000 3230
#define O82_HDR_EDID_SIZE 384
#define O82_COLOR_SRGB 0
#define O82_COLOR_P3 1

static inline unsigned int o82_hdr_u16(const unsigned char *p)
{
	return p[0] | ((unsigned int)p[1] << 8);
}

static inline unsigned int o82_hdr_u32(const unsigned char *p)
{
	return o82_hdr_u16(p) | (o82_hdr_u16(p + 2) << 16);
}

static inline unsigned int o82_hdr_crc32(const unsigned char *data, unsigned long length)
{
	unsigned int crc = 0xffffffff, bit;
	unsigned long at;

	for (at = 0; at < length; at++) {
		crc ^= data[at];
		for (bit = 0; bit < 8; bit++)
			crc = (crc >> 1) ^ (0xedb88320U & (0U - (crc & 1)));
	}
	return ~crc;
}

static inline int o82_hdr_valid(const unsigned char *data, unsigned long length,
		unsigned int panel)
{
	static const unsigned char hashes[2][32] = {
		{0xbd,0x88,0xeb,0x94,0x13,0x4e,0x5f,0x62,0xc0,0x5e,0xeb,0xaa,0x0a,0x9e,0x4b,0x52,
		 0x67,0x96,0x83,0x63,0xf7,0x2f,0x44,0x00,0x18,0xb9,0x8a,0x15,0xd1,0xbd,0x91,0x22},
		{0x2b,0x64,0x42,0xce,0x0e,0x8f,0xef,0x6d,0x1b,0x00,0x8c,0xde,0xca,0x38,0x38,0x45,
		 0x02,0x82,0x86,0x8d,0x38,0x5f,0x6e,0x30,0x56,0xc0,0xa4,0xce,0x2b,0x89,0x49,0xd8},
	};
	unsigned int at, curve, channel, i, previous, value;
	const unsigned char *p;

	if (!data || length != O82_HDR_FILE_SIZE || (panel != 0x36 && panel != 0x42))
		return 0;
	for (at = 0; at < 8; at++)
		if (data[at] != O82_HDR_MAGIC[at])
			return 0;
	if (o82_hdr_u32(data + 8) != O82_HDR_VERSION || o82_hdr_u32(data + 12) != panel ||
	    o82_hdr_u32(data + 16) != length || o82_hdr_u32(data + 24) != O82_HDR_NOMINAL_PEAK_NITS ||
	    o82_hdr_u32(data + 28) != O82_HDR_NOMINAL_BLACK_10000)
		return 0;
	for (at = 0; at < 32; at++)
		if (data[32 + at] != hashes[panel == 0x42][at])
			return 0;
	if (o82_hdr_u32(data + 20) != o82_hdr_crc32(data + O82_HDR_HEADER_SIZE, O82_HDR_PAYLOAD_SIZE))
		return 0;
	p = data + O82_HDR_HEADER_SIZE;
	for (curve = 0; curve < 2; curve++) {
		for (channel = 0; channel < 3; channel++) {
			previous = 0;
			for (i = 0; i < O82_HDR_IGC_ENTRIES; i++) {
				value = o82_hdr_u16(p + (i * 3 + channel) * 2);
				if (value > 4095 || value < previous || (!i && value))
					return 0;
				previous = value;
			}
			if (previous != 4095)
				return 0;
		}
		p += O82_HDR_IGC_ENTRIES * 3 * 2;
	}
	for (i = 0; i < O82_HDR_GAMUT_ENTRIES * 3; i++)
		if (o82_hdr_u16(p + i * 2) > 4095)
			return 0;
	p += O82_HDR_GAMUT_ENTRIES * 3 * 2;
	for (channel = 0; channel < 3; channel++) {
		previous = 0;
		for (i = 0; i < O82_HDR_GC_ENTRIES; i++) {
			value = o82_hdr_u16(p + (i * 3 + channel) * 2);
			if (value > 1023 || value < previous)
				return 0;
			previous = value;
		}
	}
	return 1;
}

/* EDID describes the selected transform; its LUTs remain private driver data. */
static inline int o82_color_make_edid(unsigned char edid[O82_HDR_EDID_SIZE],
		unsigned int primaries, unsigned int native_hdr)
{
	static const unsigned char signature[8] = {0, 255, 255, 255, 255, 255, 255, 0};
	static const char name[] = "O82 Panel\n   ";
	/* Logical sRGB / Display-P3 inputs, both D65; never factory LUT contents. */
	static const unsigned short gamuts[2][8] = {
		{655, 338, 307, 614, 154, 61, 320, 337},
		{696, 328, 271, 707, 154, 61, 320, 337},
	};
	unsigned char *cta, *did, *timing;
	unsigned int i, sum, clock = 96743 - 1;
	/* Existing OEM 120 Hz: 3200/3490 by 2136/2310, 967428 kHz. */
	static const unsigned short dimensions[8] = {3199, 289, 225, 31, 2135, 173, 25, 1};

	if (!edid || primaries > O82_COLOR_P3 || native_hdr > 1)
		return 0;
	cta = edid + 128;
	did = edid + 256;
	timing = did + 8;
	for (i = 0; i < O82_HDR_EDID_SIZE; i++)
		edid[i] = 0;
	for (i = 0; i < 8; i++)
		edid[i] = signature[i];
	edid[8] = 0x31; edid[9] = 0xd8; /* LNX, not a fabricated OEM/unit identity. */
	edid[10] = 0x82;
	edid[17] = 36;
	/* EDID 1.2 permits no base DTD; every native clock exceeds its limit. */
	edid[18] = 1; edid[19] = 2;
	edid[20] = 0x80; /* Digital RGB; the connector separately fixes 10 bpc. */
	edid[21] = 24; edid[22] = 16; edid[23] = 120;
	for (i = 0; i < 8; i++) {
		edid[27 + i] = gamuts[primaries][i] >> 2;
		edid[25 + i / 4] |= (gamuts[primaries][i] & 3) << (6 - (i % 4) * 2);
		edid[38 + i * 2] = 1; edid[39 + i * 2] = 1;
	}
	edid[57] = 0xfc;
	for (i = 0; i < 13; i++)
		edid[59 + i] = name[i];
	edid[75] = edid[93] = edid[111] = 0x10;
	edid[126] = 2;
	cta[0] = 2; cta[1] = 3; cta[2] = native_hdr ? 15 : 4;
	if (native_hdr) {
		cta[4] = 0xe3; cta[5] = 5; cta[6] = 0x80; /* BT.2020 RGB. */
		cta[8] = 0xe6; cta[9] = 6; cta[10] = 5; cta[11] = 1;
		/* Nominal max <=420 nits, min derived from OEM black; not measured. */
		cta[12] = 98; cta[13] = 98; cta[14] = 71;
	}
	/* Include one zero padding header inside the DisplayID checksum domain. */
	did[0] = 0x70; did[1] = 0x13; did[2] = 26;
	did[5] = 3; did[6] = 1; did[7] = 20;
	timing[0] = clock; timing[1] = clock >> 8; timing[2] = clock >> 16;
	timing[3] = 0x80;
	for (i = 0; i < 8; i++) {
		timing[4 + i * 2] = dimensions[i];
		timing[5 + i * 2] = dimensions[i] >> 8;
	}
	/* DisplayID's inner checksum excludes the outer EDID extension tag. */
	for (sum = 0, i = 1; i < 31; i++)
		sum += did[i];
	did[31] = (unsigned char)-sum;
	for (unsigned int block = 0; block < 3; block++) {
		for (sum = 0, i = 0; i < 127; i++)
			sum += edid[block * 128 + i];
		edid[block * 128 + 127] = (unsigned char)-sum;
	}
	return 1;
}
#endif
