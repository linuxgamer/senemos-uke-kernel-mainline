/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef NT36532_UKE_PROTOCOL_H
#define NT36532_UKE_PROTOCOL_H

#include <linux/types.h>

#define NVT_UKE_FRAME_SIZE 5432
#define NVT_UKE_IMAGE_SIZE 245760
#define NVT_UKE_NODES 2400
#define NVT_UKE_CHUNK 1024
#define NVT_UKE_GESTURE_SIZE 65
#define NVT_UKE_CONTACTS 10

enum nvt_uke_variant {
	NVT_UKE_CSOT,
	NVT_UKE_TIANMA,
};

struct nvt_uke_contacts {
	u16 active;
	u16 x[NVT_UKE_CONTACTS], y[NVT_UKE_CONTACTS];
	u16 peak[NVT_UKE_CONTACTS];
};

struct nvt_uke_frame {
	u16 counter;
	u8 scan_mode;
	const u8 *matrix_le;
};

struct nvt_uke_io {
	void *context;
	/* Each callback transfers payload bytes, excluding the SPI command/dummy. */
	int (*read)(void *context, u32 address, void *data, size_t size, bool fast);
	int (*write)(void *context, u32 address, const void *data, size_t size, bool fast);
	int (*check_ready)(void *context);
	void (*delay_ms)(void *context, unsigned int milliseconds);
	int (*sha256)(void *context, const u8 *data, size_t size, u8 digest[32]);
	enum nvt_uke_variant variant;
};

const char *nvt_uke_firmware(enum nvt_uke_variant variant);
int nvt_uke_variant_from_name(const char *name);
int nvt_uke_panel_id(enum nvt_uke_variant variant, int direction, int level);

int nvt_uke_decode(const u8 *data, size_t size, struct nvt_uke_frame *frame);
int nvt_uke_watchdog(const u8 *data, size_t size, unsigned int *consecutive);
int nvt_uke_validate_image(const struct nvt_uke_io *io, const u8 *data, size_t size);
int nvt_uke_boot(const struct nvt_uke_io *io, const u8 *data, size_t size, bool idle_reset);
int nvt_uke_read_frame(const struct nvt_uke_io *io, u8 data[NVT_UKE_FRAME_SIZE]);
int nvt_uke_charger(const struct nvt_uke_io *io, bool connected);
int nvt_uke_coordinate_mode(const struct nvt_uke_io *io, bool enabled);
int nvt_uke_gesture_enter(const struct nvt_uke_io *io);
int nvt_uke_double_tap(const u8 *data, size_t size);

#endif
