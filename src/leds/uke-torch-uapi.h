/* SPDX-License-Identifier: GPL-2.0-only WITH Linux-syscall-note */
#ifndef _UAPI_UKE_TORCH_H
#define _UAPI_UKE_TORCH_H
#include <linux/ioctl.h>
#include <linux/types.h>

#define UKE_TORCH_ABI 1
#define UKE_TORCH_MAX_UA 20000
struct uke_torch_request {
	/* SET: 0 is off; every integer 1..100 is retained before provider rounding. */
	__u32 abi, value, reserved[2];
};
struct uke_torch_status {
	__u32 abi, requested_percent, brightness, brightness_valid;
	__u32 max_microamp, suspended;
	__s32 last_io_error;
	__u32 reserved;
};
#define UKE_TORCH_STATUS _IOR('T', 0x80, struct uke_torch_status)
#define UKE_TORCH_SET _IOW('T', 0x81, struct uke_torch_request)
#define UKE_TORCH_ENABLE _IOW('T', 0x82, struct uke_torch_request)
#endif
