/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef _LINUX_UKE_RGB_H
#define _LINUX_UKE_RGB_H
#include <linux/kconfig.h>
#include <linux/errno.h>
#include <linux/types.h>
#if IS_REACHABLE(CONFIG_LEDS_UKE_RGB)
/* Trusted front-camera stream owner only; sleepable context, check the result. */
int uke_rgb_front_camera_active(bool active);
#else
static inline int uke_rgb_front_camera_active(bool active) { return -ENODEV; }
#endif
#endif
