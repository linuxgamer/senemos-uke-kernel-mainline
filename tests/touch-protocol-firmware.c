/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Host-only cryptographic admission test; firmware bytes are never emitted. */
#include <assert.h>
#include <stdio.h>
#include <openssl/sha.h>
#include "../src/input/nt36532-uke-protocol.h"
static int sha(void *context, const u8 *data, size_t size, u8 digest[32])
{
	(void)context;
	return SHA256(data, size, digest) ? 0 : -1;
}
int main(int argc, char **argv)
{
	static u8 data[NVT_UKE_IMAGE_SIZE];
	struct nvt_uke_io io = { .sha256 = sha };
	FILE *file;
	size_t offset;

	assert(argc == 2 || argc == 3);
	if (argc == 3) {
		int variant = nvt_uke_variant_from_name(argv[2]);
		assert(variant >= 0);
		io.variant = (enum nvt_uke_variant)variant;
	}
	file = fopen(argv[1], "rb");
	assert(file && fread(data, 1, sizeof(data), file) == sizeof(data));
	assert(fgetc(file) == EOF && !ferror(file));
	fclose(file);
	assert(!nvt_uke_validate_image(&io, data, sizeof(data)));
	struct nvt_uke_io other = io;
	other.variant = io.variant == NVT_UKE_CSOT ? NVT_UKE_TIANMA : NVT_UKE_CSOT;
	assert(nvt_uke_validate_image(&other, data, sizeof(data)) < 0);
	for (offset = 0; offset < sizeof(data); offset += 1024) {
		data[offset] ^= 1;
		assert(nvt_uke_validate_image(&io, data, sizeof(data)) < 0);
		data[offset] ^= 1;
	}
	puts("Real retained normal firmware SHA-256 admitted; one mutation per 1KiB rejected. Host only; no firmware bytes emitted.");
	return 0;
}
