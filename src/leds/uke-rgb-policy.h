/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef _UKE_RGB_POLICY_H
#define _UKE_RGB_POLICY_H
#include "uke-rgb-uapi.h"
struct uke_rgb_frame { __u32 rgb, brightness, delay_ms; };
static inline enum uke_rgb_mode uke_rgb_battery_mode(int soc, enum uke_rgb_mode previous)
{
	if (soc < 0 || soc > 100)
		return previous;
	return soc < 5 ? UKE_RGB_CRITICAL_BATTERY : soc < 15 ? UKE_RGB_LOW_BATTERY : UKE_RGB_OFF;
}
static inline enum uke_rgb_mode uke_rgb_select(int camera, int test,
					      enum uke_rgb_mode battery, int manual)
{
	if (camera)
		return UKE_RGB_FRONT_CAMERA;
	if (test)
		return UKE_RGB_TEST;
	if (battery == UKE_RGB_CRITICAL_BATTERY || battery == UKE_RGB_LOW_BATTERY)
		return battery;
	return manual ? UKE_RGB_MANUAL : UKE_RGB_OFF;
}
static inline struct uke_rgb_frame uke_rgb_frame(enum uke_rgb_mode mode, __u64 elapsed,
						__u32 manual_rgb, __u32 manual_brightness)
{
	static const unsigned char breath[16] = {0, 0, 1, 2, 4, 6, 7, 8, 8, 8, 7, 6, 4, 2, 1, 0};
	struct uke_rgb_frame f = {0, 0, 60000};
	__u32 t, step, r = 0, g = 0, b = 0, period, duration, n;

	if (mode == UKE_RGB_MANUAL) {
		f.rgb = manual_rgb;
		f.brightness = manual_brightness > UKE_RGB_LIMIT ? UKE_RGB_LIMIT : manual_brightness;
	} else if (mode == UKE_RGB_CRITICAL_BATTERY) {
		t = elapsed % 3000;
		f.rgb = 0xff0000;
		f.brightness = t < 1000 ? UKE_RGB_LIMIT : 0;
		f.delay_ms = t < 1000 ? 1000 - t : 3000 - t;
	} else if (mode == UKE_RGB_TEST && elapsed < UKE_RGB_TEST_MS) {
		n = elapsed * 48 / UKE_RGB_TEST_MS;
		step = (n % 8) * 255 / 8;
		switch (n / 8) {
		case 0: r = 255; g = step; break;
		case 1: r = 255 - step; g = 255; break;
		case 2: g = 255; b = step; break;
		case 3: g = 255 - step; b = 255; break;
		case 4: r = step; b = 255; break;
		default: r = 255; b = 255 - step; break;
		}
		f.rgb = (r << 16) | (g << 8) | b;
		f.brightness = UKE_RGB_LIMIT;
		f.delay_ms = ((n + 1) * UKE_RGB_TEST_MS + 47) / 48 - elapsed;
	} else if (mode == UKE_RGB_LOW_BATTERY || mode == UKE_RGB_FRONT_CAMERA) {
		period = mode == UKE_RGB_LOW_BATTERY ? 5000 : 2000;
		duration = mode == UKE_RGB_LOW_BATTERY ? 3000 : 2000;
		t = elapsed % period;
		f.rgb = mode == UKE_RGB_LOW_BATTERY ? 0xff0000 : 0x00ff00;
		if (t < duration) {
			step = t * 16 / duration;
			f.brightness = breath[step];
			f.delay_ms = ((step + 1) * duration + 15) / 16 - t;
		} else {
			f.delay_ms = period - t;
		}
	}
	return f;
}
#endif
