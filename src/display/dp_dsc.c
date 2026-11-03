// SPDX-License-Identifier: GPL-2.0-only
/*
 * Copyright (c) 2026 Senemos Maintainers.
 * DTO/PPS contracts: Uke OEM display 44275c404a677d9d9e5230fedd1af2ef02fc7b9a,
 * Copyright (c) 2012-2023 The Linux Foundation and Qualcomm Innovation Center.
 */
#include <linux/bitfield.h>
#include <linux/limits.h>
#include <drm/display/drm_dsc_helper.h>

#include "dp_dsc.h"
#include "dp_utils.h"

bool msm_dp_dsc_link_fits(const struct msm_dp_dsc_config *config,
			 const struct drm_display_mode *mode,
			 unsigned int rate, unsigned int lanes)
{
	const struct drm_dsc_config *dsc = &config->dsc;
	int overhead;

	if (mode->clock <= 0 || !dsc->bits_per_pixel || !dsc->pic_width ||
	    !dsc->slice_count || !rate || (lanes != 1 && lanes != 2 && lanes != 4))
		return false;
	overhead = drm_dp_bw_overhead(lanes, dsc->pic_width, dsc->slice_count,
			dsc->bits_per_pixel, DRM_DP_BW_OVERHEAD_DSC | DRM_DP_BW_OVERHEAD_FEC);
	return overhead > 0 && (u64)mode->clock * dsc->bits_per_pixel * overhead <=
		(u64)rate * lanes * 8 * 16 * 1000000;
}

int msm_dp_dsc_prepare(const u8 caps[DP_DSC_RECEIVER_CAP_SIZE], u8 fec,
		       const struct drm_display_mode *mode, unsigned int bpc,
		       unsigned int rate, unsigned int lanes,
		       struct msm_dp_dsc_config *result)
{
	struct msm_dp_dsc_config config = {};
	struct drm_dsc_config *dsc = &config.dsc;
	u32 slice_mask, max_width, bytes_per_line;
	unsigned int slices;
	int throughput, rc_size, ret;
	u8 revision = caps[DP_DSC_REV - DP_DSC_SUPPORT];
	u8 depth_bit = bpc == 10 ? DP_DSC_10_BPC : DP_DSC_8_BPC;

	memset(result, 0, sizeof(*result));
	if (!(fec & DP_FEC_CAPABLE) || !drm_dp_sink_supports_dsc(caps) ||
	    !drm_dp_dsc_sink_supports_format(caps, DP_DSC_RGB) ||
	    (bpc != 8 && bpc != 10) ||
	    !(caps[DP_DSC_DEC_COLOR_DEPTH_CAP - DP_DSC_SUPPORT] & depth_bit) ||
	    !drm_dp_dsc_sink_bpp_incr(caps))
		return -EOPNOTSUPP;
	dsc->dsc_version_major = FIELD_GET(DP_DSC_MAJOR_MASK, revision);
	dsc->dsc_version_minor = FIELD_GET(DP_DSC_MINOR_MASK, revision);
	if (dsc->dsc_version_major != 1 ||
	    (dsc->dsc_version_minor != 1 && dsc->dsc_version_minor != 2))
		return -EOPNOTSUPP;
	if (mode->clock <= 0 || mode->hdisplay <= 0 || mode->hdisplay > U16_MAX ||
	    mode->vdisplay <= 0 || mode->vdisplay > U16_MAX ||
	    (mode->hdisplay & 1) || (mode->flags & DRM_MODE_FLAG_INTERLACE))
		return -EINVAL;
	dsc->pic_width = mode->hdisplay;
	dsc->pic_height = mode->vdisplay;
	dsc->bits_per_component = bpc;
	dsc->bits_per_pixel = 8 << 4;
	dsc->line_buf_depth = drm_dp_dsc_sink_line_buf_depth(caps);
	if (dsc->line_buf_depth < bpc ||
	    (dsc->dsc_version_minor == 1 && dsc->line_buf_depth > 13))
		return -EOPNOTSUPP;
	dsc->block_pred_enable = caps[DP_DSC_BLK_PREDICTION_SUPPORT - DP_DSC_SUPPORT] &
		DP_DSC_BLK_PREDICTION_IS_SUPPORTED;
	dsc->convert_rgb = true;
	slice_mask = drm_dp_dsc_sink_slice_count_mask(caps, false);
	max_width = min(drm_dp_dsc_sink_max_slice_width(caps), 2560U);
	throughput = drm_dp_dsc_sink_max_slice_throughput(caps, mode->clock, true);
	/* Cliffs OEM advertises a 2560-pixel DSC line width; two slices cover 4K. */
	for (slices = 1; slices <= 2; slices++) {
		if (!(slice_mask & drm_dp_dsc_slice_count_to_mask(slices)) ||
		    dsc->pic_width % slices || dsc->pic_width / slices > max_width ||
		    DIV_ROUND_UP(mode->clock, slices) > throughput)
			continue;
		dsc->slice_count = slices;
		dsc->slice_width = dsc->pic_width / slices;
		break;
	}
	if (!dsc->slice_count)
		return -EOPNOTSUPP;
	if (!(dsc->pic_height % 16))
		dsc->slice_height = 16;
	else if (!(dsc->pic_height % 12))
		dsc->slice_height = 12;
	else
		return -EOPNOTSUPP;
	drm_dsc_set_const_params(dsc);
	rc_size = drm_dsc_dp_rc_buffer_size(
		caps[DP_DSC_RC_BUF_BLK_SIZE - DP_DSC_SUPPORT] & 3,
		caps[DP_DSC_RC_BUF_SIZE - DP_DSC_SUPPORT]);
	if (rc_size * 8 < dsc->rc_model_size)
		return -EOPNOTSUPP;
	drm_dsc_set_rc_buf_thresh(dsc);
	ret = drm_dsc_setup_rc_params(dsc, dsc->dsc_version_minor == 2 ?
				      DRM_DSC_1_2_444 : DRM_DSC_1_1_PRE_SCR);
	if (ret)
		return ret;
	dsc->initial_scale_value = drm_dsc_initial_scale_value(dsc);
	ret = drm_dsc_compute_rc_parameters(dsc);
	if (ret)
		return ret;
	if (!msm_dp_dsc_link_fits(&config, mode, rate, lanes))
		return -ENOSPC;
	/* shortcut: 8 bpp and even RGB width need no DTO phase padding; extend before other rates. */
	bytes_per_line = dsc->slice_chunk_size * dsc->slice_count;
	config.dto_count = DIV_ROUND_UP(bytes_per_line, 6) - 1;
	config.compression_ctrl = BIT(0) |
		((DIV_ROUND_UP(bytes_per_line, 3) * 3 - bytes_per_line) << 3) |
		((dsc->slice_count - 1) << 5) | (10 << 10) | (dsc->slice_chunk_size << 16);
	*result = config;
	return 0;
}

u8 msm_dp_dsc_word_parity(u32 data)
{
	u8 x0 = 0, x1 = 0;
	unsigned int i;

	/* PPS parity always covers four bytes, including zero-valued second bytes. */
	for (i = 0; i < 8; i++) {
		u8 ci = ((data >> (i * 4)) & 0xf) ^ x1;

		x1 = x0 ^ msm_dp_utils_get_g1_value(ci);
		x0 = msm_dp_utils_get_g0_value(ci);
	}
	return x1 | (x0 << 4);
}
