/* SPDX-License-Identifier: GPL-2.0 WITH Linux-syscall-note */
#ifndef _UAPI_LINUX_UKE_RGB_H
#define _UAPI_LINUX_UKE_RGB_H
#include <linux/types.h>
#include <linux/ioctl.h>
#define UKE_RGB_ABI 1
#define UKE_RGB_LIMIT 8
#define UKE_RGB_TEST_MS 10000

enum uke_rgb_mode {
	UKE_RGB_OFF, UKE_RGB_MANUAL, UKE_RGB_LOW_BATTERY,
	UKE_RGB_CRITICAL_BATTERY, UKE_RGB_FRONT_CAMERA, UKE_RGB_TEST,
};
struct uke_rgb_color {
	/* rgb is 0xRRGGBB, each channel 0..255; brightness_percent is 0..100. */
	__u32 abi, rgb, brightness_percent, reserved;
};
struct uke_rgb_status {
	__u32 abi, mode, rgb, brightness, brightness_limit;
	__u32 requested_rgb, requested_percent, battery_percent, battery_valid;
	__u32 test_remaining_ms, camera_active, camera_source_seen;
	__s32 last_io_error;
	__u32 reserved;
};
#define UKE_RGB_STATUS _IOR(0xb7, 0, struct uke_rgb_status)
#define UKE_RGB_SET _IOW(0xb7, 1, struct uke_rgb_color)
#define UKE_RGB_TEST_COLORS _IO(0xb7, 2)
#define UKE_RGB_AUTOMATIC _IO(0xb7, 3)
#endif
