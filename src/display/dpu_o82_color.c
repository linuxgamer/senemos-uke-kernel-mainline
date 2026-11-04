// SPDX-License-Identifier: GPL-2.0-only
/* Paired Uke postblend ownership through the actual native CRTC path. */
#include <linux/errno.h>
#include <linux/firmware.h>
#include <linux/hdmi.h>
#include <linux/moduleparam.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/slab.h>
#include <linux/string.h>
#include <drm/drm_atomic.h>
#include <drm/drm_atomic_helper.h>
#include <drm/drm_color_mgmt.h>
#include <drm/drm_connector.h>
#include <drm/drm_edid.h>
#include <drm/drm_print.h>
#include <drm/drm_property.h>

#include "msm_drv.h"
#include "dpu_crtc.h"
#include "dpu_encoder.h"
#include "dpu_hw_ctl.h"
#include "dpu_hw_dspp.h"
#include "dpu_kms.h"
#include "dpu_o82_color.h"
#include "dpu_o82_power.h"
#include "dpu_o82_profiles.h"
#include "dpu_o82_regdma.h"
#include "uke-o82-hdr-format.h"

/* Empty by default until private-data delivery and physical qualification. */
static char *o82_color_profile;
module_param(o82_color_profile, charp, 0444);
MODULE_PARM_DESC(o82_color_profile,
	"Experimental O82 initial preset; requires matching private firmware; default disabled");

struct dpu_o82_color {
	struct dpu_o82_profiles profiles;
	/* CPU firmware readers precede the power/transport locks; close drains first. */
	struct mutex lock;
	bool failed;
};

static struct dpu_kms *o82_kms(struct drm_device *drm)
{
	struct msm_drm_private *priv = drm->dev_private;

	return to_dpu_kms(priv->kms);
}

bool dpu_o82_color_requested(const struct drm_crtc_state *state)
{
	struct drm_encoder *encoder;

	if (!o82_kms(state->crtc->dev)->o82_color)
		return false;
	drm_for_each_encoder_mask(encoder, state->crtc->dev, state->encoder_mask)
		if (encoder->encoder_type == DRM_MODE_ENCODER_DSI)
			return true;
	return false;
}

bool dpu_o82_color_blocked(struct drm_encoder *encoder)
{
	struct dpu_kms *kms = o82_kms(encoder->dev);
	struct dpu_o82_color *color = kms->o82_color;

	return encoder->encoder_type == DRM_MODE_ENCODER_DSI && color &&
		(READ_ONCE(color->failed) || !kms->o82_regdma ||
		 READ_ONCE(kms->o82_regdma->closing));
}

void dpu_o82_color_mode_changed(struct drm_crtc_state *state)
{
	struct drm_connector_state *old, *new;
	struct drm_connector *connector;
	int i;

	if (!dpu_o82_color_requested(state))
		return;
	for_each_oldnew_connector_in_state(state->state, connector, old, new, i) {
		if (!connector || new->crtc != state->crtc)
			continue;
		if (old->colorspace != new->colorspace ||
		    !drm_connector_atomic_hdr_metadata_equal(old, new))
			state->mode_changed = true;
	}
}

static int o82_wire_state(struct dpu_crtc_state *cstate,
			 const struct drm_connector_state *conn)
{
	const struct hdr_output_metadata *hdr;

	if (conn->colorspace != DRM_MODE_COLORIMETRY_DEFAULT &&
	    conn->colorspace != DRM_MODE_COLORIMETRY_BT2020_RGB)
		return -EOPNOTSUPP;
	cstate->o82_bt2020 = conn->colorspace == DRM_MODE_COLORIMETRY_BT2020_RGB;
	cstate->o82_pq = false;
	if (!conn->hdr_output_metadata)
		return 0;
	if (conn->hdr_output_metadata->length != sizeof(*hdr))
		return -EINVAL;
	hdr = conn->hdr_output_metadata->data;
	if (hdr->metadata_type || hdr->hdmi_metadata_type1.metadata_type)
		return -EOPNOTSUPP;
	if (hdr->hdmi_metadata_type1.eotf == HDMI_EOTF_SMPTE_ST2084)
		cstate->o82_pq = true;
	else if (hdr->hdmi_metadata_type1.eotf != HDMI_EOTF_TRADITIONAL_GAMMA_SDR)
		return -EOPNOTSUPP;
	return 0;
}

int dpu_o82_color_check(struct drm_crtc *crtc, struct drm_crtc_state *state)
{
	struct dpu_crtc_state *cstate = to_dpu_crtc_state(state);
	struct drm_connector_state *conn;
	struct drm_connector *connector;
	struct drm_encoder *encoder, *selected = NULL;
	unsigned int i, count = 0, mask = 0;
	int ret;

	cstate->o82_native_color = false;
	if (!dpu_o82_color_requested(state) || !state->enable ||
	    !drm_atomic_crtc_effectively_active(state))
		return 0;
	drm_for_each_encoder_mask(encoder, crtc->dev, state->encoder_mask) {
		selected = encoder;
		count++;
	}
	if (count != 1 || selected->encoder_type != DRM_MODE_ENCODER_DSI ||
	    cstate->num_mixers != 2 || cstate->num_ctls != 1 ||
	    !cstate->hw_ctls[0] || !cstate->hw_ctls[0]->ops.update_pending_flush_dspp)
		return -EOPNOTSUPP;
	if (dpu_o82_color_blocked(selected))
		return -EIO;
	if (state->gamma_lut &&
	    state->gamma_lut->length != 1024 * sizeof(struct drm_color_lut))
		return -EINVAL;
	for (i = 0; i < 2; i++) {
		struct dpu_crtc_mixer *mixer = &cstate->mixers[i];
		unsigned int bit;

		if (!mixer->hw_dspp || mixer->lm_ctl != cstate->hw_ctls[0] ||
		    mixer->hw_dspp->idx < DSPP_0 || mixer->hw_dspp->idx > DSPP_2)
			return -EINVAL;
		bit = BIT(mixer->hw_dspp->idx - DSPP_0);
		if (mask & bit)
			return -EINVAL;
		mask |= bit;
	}
	if (drm_atomic_crtc_needs_modeset(state)) {
		connector = drm_atomic_get_new_connector_for_encoder(state->state, selected);
		if (!connector)
			return -EINVAL;
		conn = drm_atomic_get_new_connector_state(state->state, connector);
		if (!conn || conn->crtc != crtc)
			return -EINVAL;
		ret = o82_wire_state(cstate, conn);
		if (ret)
			return ret;
	}
	cstate->o82_native_color = true;
	return 0;
}

static unsigned int o82_gc_value(const struct drm_crtc_state *state,
				const u8 *factory, unsigned int i, unsigned int channel)
{
	const struct drm_color_lut *lut;
	unsigned int value = o82_hdr_u16(factory + 6 * i + 2 * channel);

	if (!state->gamma_lut)
		return value;
	lut = state->gamma_lut->data;
	return drm_color_lut_extract(channel == 0 ? lut[value].red :
				     channel == 1 ? lut[value].green : lut[value].blue, 10);
}

int dpu_o82_color_gc(struct drm_crtc *crtc, struct dpu_hw_gc_lut *gc)
{
	static const unsigned int channels[] = { 1, 2, 0 };
	const struct dpu_crtc_state *state = to_dpu_crtc_state(crtc->state);
	struct dpu_o82_color_input input;
	struct dpu_o82_color *color = o82_kms(crtc->dev)->o82_color;
	u32 *out[] = { gc->c0, gc->c1, gc->c2 };
	unsigned int i, c;
	int ret;

	mutex_lock(&color->lock);
	if (READ_ONCE(color->failed)) {
		ret = -EIO;
		goto out;
	}
	ret = dpu_o82_profiles_input(&color->profiles,
				     state->o82_bt2020, state->o82_pq, &input);
	if (ret) {
		WRITE_ONCE(color->failed, true);
		goto out;
	}
	memset(gc, 0, sizeof(*gc));
	for (c = 0; c < 3; c++)
		for (i = 0; i < 512; i++)
			out[c][i] = o82_gc_value(crtc->state, input.gc, 2 * i, channels[c]) |
				o82_gc_value(crtc->state, input.gc, 2 * i + 1, channels[c]) << 16;
out:
	mutex_unlock(&color->lock);
	return ret;
}

int dpu_o82_color_commit(struct drm_crtc *crtc)
{
	struct dpu_kms *kms = o82_kms(crtc->dev);
	struct dpu_crtc_state *state = to_dpu_crtc_state(crtc->state);
	struct dpu_o82_color_input input;
	struct drm_encoder *encoder;
	u8 *gc;
	unsigned int i, c, mask = 0;
	int ret;

	if (!state->o82_native_color || !drm_atomic_crtc_needs_modeset(crtc->state))
		return 0;
	mutex_lock(&kms->o82_color->lock);
	if (READ_ONCE(kms->o82_color->failed)) {
		ret = -EIO;
		goto out;
	}
	drm_for_each_encoder_mask(encoder, crtc->dev, crtc->state->encoder_mask) {
		ret = dpu_encoder_o82_stopped(encoder);
		if (ret)
			goto fail;
	}
	ret = dpu_o82_profiles_input(&kms->o82_color->profiles,
				     state->o82_bt2020, state->o82_pq, &input);
	if (ret)
		goto fail;
	gc = kmalloc(1024 * 3 * 2, GFP_KERNEL);
	if (!gc) {
		ret = -ENOMEM;
		goto fail;
	}
	for (i = 0; i < 1024; i++)
		for (c = 0; c < 3; c++) {
			unsigned int value = o82_gc_value(crtc->state, input.gc, i, c);

			gc[6 * i + 2 * c] = value;
			gc[6 * i + 2 * c + 1] = value >> 8;
		}
	input.gc = gc;
	for (i = 0; i < 2; i++)
		mask |= BIT(state->mixers[i].hw_dspp->idx - DSPP_0);
	ret = dpu_o82_power_upload(kms, state->hw_ctls[0], &input, mask);
	kfree(gc); /* The synchronous encoder copied it into the retained GEM object. */
	if (ret)
		goto fail;
	for (i = 0; i < 2; i++) {
		struct dpu_hw_ctl *ctl = state->hw_ctls[0];
		unsigned int id = state->mixers[i].hw_dspp->idx;

		ctl->ops.update_pending_flush_dspp(ctl, id, DPU_DSPP_IGC);
		ctl->ops.update_pending_flush_dspp(ctl, id, DPU_DSPP_GAMUT);
		ctl->ops.update_pending_flush_dspp(ctl, id, DPU_DSPP_GC);
		if (input.pa_managed)
			ctl->ops.update_pending_flush_dspp(ctl, id, DPU_DSPP_PA);
	}
	goto out;
fail:
	WRITE_ONCE(kms->o82_color->failed, true);
	drm_err(crtc->dev, "O82 paired color upload failed: %d\n", ret);
out:
	mutex_unlock(&kms->o82_color->lock);
	return ret;
}

int dpu_o82_color_init(struct dpu_kms *kms)
{
	struct dpu_o82_color *color;
	struct device_node *node;
	unsigned int panel = 0, count = 0;
	int ret;

	if (!o82_color_profile || !*o82_color_profile)
		return 0;
	if (!kms->o82_regdma || strnlen(o82_color_profile, 64) >= 64)
		return -EINVAL;
	for_each_compatible_node(node, NULL, "xiaomi,o82-36-02-0a")
		if (of_device_is_available(node)) {
			panel = 0x36;
			count++;
		}
	for_each_compatible_node(node, NULL, "xiaomi,o82-42-02-0b")
		if (of_device_is_available(node)) {
			panel = 0x42;
			count++;
		}
	if (count != 1)
		return -ENODEV;
	color = devm_kzalloc(&kms->pdev->dev, sizeof(*color), GFP_KERNEL);
	if (!color)
		return -ENOMEM;
	mutex_init(&color->lock);
	ret = dpu_o82_profiles_load(&color->profiles, &kms->pdev->dev, panel);
	if (ret)
		return ret;
	ret = dpu_o82_profiles_select(&color->profiles, o82_color_profile);
	if (ret) {
		dpu_o82_profiles_unload(&color->profiles);
		return ret;
	}
	kms->o82_color = color;
	return 0;
}

int dpu_o82_color_connectors_init(struct dpu_kms *kms)
{
	struct drm_connector_list_iter iter;
	struct drm_connector *connector;
	struct dpu_o82_color_input input;
	const struct drm_edid *edid;
	u8 bytes[O82_HDR_EDID_SIZE];
	unsigned int count = 0;
	int ret = 0;

	if (!kms->o82_color)
		return 0;
	ret = dpu_o82_profiles_input(&kms->o82_color->profiles, 0, 0, &input);
	if (ret || !o82_color_make_edid(bytes, input.primaries, 0))
		return ret ? ret : -EINVAL;
	edid = drm_edid_alloc(bytes, sizeof(bytes));
	if (!edid)
		return -ENOMEM;
	drm_connector_list_iter_begin(kms->dev, &iter);
	drm_for_each_connector_iter(connector, &iter) {
		if (connector->connector_type != DRM_MODE_CONNECTOR_DSI)
			continue;
		count++;
		ret = drm_mode_create_hdmi_colorspace_property(connector,
					BIT(DRM_MODE_COLORIMETRY_BT2020_RGB));
		if (!ret)
			ret = drm_connector_attach_colorspace_property(connector);
		if (!ret)
			ret = drm_edid_connector_update(connector, edid);
		if (ret)
			break;
		drm_connector_attach_hdr_output_metadata_property(connector);
	}
	drm_connector_list_iter_end(&iter);
	drm_edid_free(edid);
	return ret ? ret : count == 1 ? 0 : -ENODEV;
}

void dpu_o82_color_fini(struct dpu_kms *kms)
{
	if (!kms->o82_color)
		return;
	mutex_lock(&kms->o82_color->lock);
	WRITE_ONCE(kms->o82_color->failed, true);
	dpu_o82_profiles_unload(&kms->o82_color->profiles);
	mutex_unlock(&kms->o82_color->lock);
}
