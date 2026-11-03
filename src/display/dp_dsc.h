/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef MSM_DP_DSC_H
#define MSM_DP_DSC_H

#include <drm/display/drm_dp_helper.h>
#include <drm/display/drm_dsc.h>
#include <drm/drm_modes.h>

#define MSM_DP_DSC_RGB_PPS_BYTES 88

struct msm_dp_dsc_config {
	struct drm_dsc_config dsc;
	u32 dto_count;
	u32 compression_ctrl;
};

int msm_dp_dsc_prepare(const u8 caps[DP_DSC_RECEIVER_CAP_SIZE], u8 fec,
		       const struct drm_display_mode *mode, unsigned int bpc,
		       unsigned int rate, unsigned int lanes,
		       struct msm_dp_dsc_config *result);
bool msm_dp_dsc_link_fits(const struct msm_dp_dsc_config *config,
			 const struct drm_display_mode *mode,
			 unsigned int rate, unsigned int lanes);
u8 msm_dp_dsc_word_parity(u32 data);

#endif
