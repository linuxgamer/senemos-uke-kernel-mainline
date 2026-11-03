/* SPDX-License-Identifier: GPL-2.0 WITH Linux-syscall-note */
#ifndef _UAPI_LINUX_FM19511_H
#define _UAPI_LINUX_FM19511_H

#include <linux/ioctl.h>
#include <linux/types.h>

#define FM19511_ABI_VERSION 1
#define FM19511_MAX_TRANSFER 256
#define FM19511_CAP_TYPE2_TAG (1U << 0)
#define FM19511_CAP_MEMORY_READ (1U << 1)
#define FM19511_CAP_RF_EVENTS (1U << 2)
#define FM19511_CAP_WAKEUP (1U << 3)

/* No reader, arbitrary card emulation or writable-memory capability. */
struct fm19511_info {
	__u32 abi_version;
	__u32 capabilities;
	__u32 max_transfer;
	__u32 reserved[5];
};

/* Raw OEM interrupt bytes; their undocumented bits are not interpreted. */
struct fm19511_events {
	__aligned_u64 irq_sequence;
	__aligned_u64 status_sequence;
	__s32 error;
	__u8 main_irq;
	__u8 fifo_irq;
	__u8 aux_irq;
	__u8 pending;
	__u32 reserved[2];
};

/* Atomic address selection and read. No chip-memory write operation exists. */
struct fm19511_memory {
	__u16 address;
	__u16 length;
	__u32 reserved;
	__u8 data[FM19511_MAX_TRANSFER];
};

#define FM19511_IOC_INFO _IOR('F', 0x70, struct fm19511_info)
#define FM19511_IOC_EVENTS _IOR('F', 0x71, struct fm19511_events)
#define FM19511_IOC_READ_MEMORY _IOWR('F', 0x72, struct fm19511_memory)

#endif
