// SPDX-License-Identifier: GPL-2.0-only
/*
 * Experimental Xiaomi Pad 7 O82 dual-DSI panel candidate for Linux 7.2.9/7.2.10.
 * Native 120 Hz output observed in development build 1.4050; other modes
 * require separate physical tests. Not activated by the normal release.
 * Lifecycle based on the archived O82 draft and upstream nt35950 pattern.
 * Based on linuxgamer/uke-fedora cf4f9317a7fef3e9bdddc36bedcb257fa51b0994.
 * OEM packet types, delays, timing groups and power sequence are retained.
 */
#include <linux/delay.h>
#include <linux/backlight.h>
#include <linux/atomic.h>
#include <linux/gpio/consumer.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/of_graph.h>
#include <linux/qcom-uke-display.h>
#include <linux/regulator/consumer.h>
#include <drm/display/drm_dsc_helper.h>
#include <drm/drm_connector.h>
#include <drm/drm_crtc.h>
#include <drm/drm_mipi_dsi.h>
#include <drm/drm_modes.h>
#include <drm/drm_panel.h>
#include <drm/drm_vblank.h>
#include <drm/drm_vblank_work.h>
#include <drm/uke-o82-mode.h>
#include <video/mipi_display.h>

struct o82_command {
	u8 type, last, channel, downstream_flags, delay_ms;
	u16 len;
	const u8 *data;
};

struct o82_profile {
	const struct o82_command *on;
	unsigned int on_count;
	const struct o82_command *switch_commands;
	unsigned int switch_count;
	const struct o82_command *off;
	unsigned int off_count;
};
struct o82_timing {
	unsigned int group;
	struct drm_display_mode mode;
};
#include "o82-data.h"

struct o82_panel {
	struct drm_panel panel;
	struct mipi_dsi_device *dsi[2];
	struct drm_dsc_config dsc;
	struct regulator *supplies[3];
	struct gpio_desc *reset;
	struct drm_connector *connector;
	struct backlight_device *backlight;
	struct drm_vblank_work first_frame_work;
	struct drm_crtc *first_frame_crtc;
	u64 first_frame_target;
	struct mutex lock;
	const struct o82_profile *profiles, *active;
	unsigned int enabled_supplies;
	unsigned int loaded_supplies;
	bool reset_output;
	bool prepared;
	bool first_frame_initialized;
	bool removing;
	bool initial_60hz_only;
	bool initial_120hz_only;
	bool oem_refresh_modes;
	bool trial_60_120_only;
	bool trial_all_rates;
	atomic64_t touch_state;
};

static void o82_touch_state(struct o82_panel *ctx, bool reset, bool ready)
{
	u64 state = (u64)atomic64_read(&ctx->touch_state) & ~1ULL;

	/* Lifecycle writers are serialized; readers receive one generation/ready pair. */
	if (reset)
		state += 2;
	atomic64_set(&ctx->touch_state, state | ready);
	sysfs_notify(&ctx->dsi[0]->dev.kobj, NULL, "touch_reset_state");
}

static int o82_send(struct o82_panel *ctx, const struct o82_command *cmd, bool lpm)
{
	struct mipi_dsi_msg msg = {
		.channel = cmd->channel,
		.type = cmd->type,
		.flags = lpm ? MIPI_DSI_MSG_USE_LPM : 0,
		.tx_len = cmd->len,
		.tx_buf = cmd->data,
	};
	int i;
	ssize_t ret = 0;

	/* OEM flag 0x40 batches commands, not ACK. Serialize instead. In MSM
	 * sync mode DSI0 writes are acknowledged without transmission; DSI1
	 * triggers both links. Sending to both also supports non-sync hosts.
	 */
	for (i = 0; i < ARRAY_SIZE(ctx->dsi); i++) {
		struct mipi_dsi_host *host = ctx->dsi[i]->host;

		ret = host->ops->transfer(host, &msg);
		/* MSM returns padded DMA packet bytes; other hosts return payload bytes. */
		if (ret < cmd->len) {
			dev_err(&ctx->dsi[i]->dev,
				"O82 transfer failed: link=%d type=%#x opcode=%#x len=%u lpm=%d result=%zd\n",
				i, cmd->type, cmd->data[0], cmd->len, lpm, ret);
			if (ret >= 0)
				ret = -EIO;
			break;
		}
	}
	/* A failed transfer may have reached the panel: preserve settle delays. */
	if (cmd->delay_ms)
		msleep(cmd->delay_ms);
	return ret < 0 ? ret : 0;
}

static int o82_off(struct o82_panel *ctx)
{
	int i, ret, first_error = 0;

	for (i = 0; i < ctx->active->off_count; i++) {
		ret = o82_send(ctx, &ctx->active->off[i], true);
		if (ret && !first_error)
			first_error = ret;
	}
	return first_error;
}

static int o82_lp_batch(struct o82_panel *ctx,
			const struct o82_command *commands, unsigned int count)
{
	struct mipi_dsi_msg msgs[4] = { };
	unsigned int i;

	if (!(ctx->initial_120hz_only || ctx->oem_refresh_modes) ||
	    (ctx->active != &ctx->profiles[0] &&
	     !(ctx->oem_refresh_modes && (ctx->active == &ctx->profiles[1] ||
					ctx->active == &ctx->profiles[2]))) ||
	    (count != 2 && count != 4))
		return -EINVAL;
	for (i = 0; i < count; i++) {
		const struct o82_command *cmd = &commands[i];

		if (cmd->delay_ms || cmd->downstream_flags != (i == count - 1 ? 0 : BIT(6)))
			return -EINVAL;
		msgs[i] = (struct mipi_dsi_msg) {
			.channel = cmd->channel, .type = cmd->type,
			.flags = MIPI_DSI_MSG_USE_LPM, .tx_len = cmd->len,
			.tx_buf = cmd->data,
		};
	}
	return qcom_uke_dsi_lp_batch(ctx->dsi[0], msgs, count);
}

static int o82_on_batch(struct o82_panel *ctx)
{
	struct mipi_dsi_msg msgs[31] = { };
	const struct o82_profile *profile = ctx->active;
	unsigned int i, count = 0, bytes = 0, chunks = 0, total = 0;
	int ret;

	if (!(ctx->initial_120hz_only || ctx->oem_refresh_modes) ||
	    (profile != &ctx->profiles[0] &&
	     !(ctx->oem_refresh_modes && (profile == &ctx->profiles[1] ||
					profile == &ctx->profiles[2]))) ||
	    profile->on_count != 108)
		return -EINVAL;
	/* Reject changed metadata before the first ON chunk can reach the panel. */
	for (i = 0; i < profile->on_count; i++) {
		const struct o82_command *cmd = &profile->on[i];
		bool terminal = i == 6 || i == 12 || i == 74 || i >= 105;

		if (cmd->type != MIPI_DSI_DCS_LONG_WRITE || cmd->channel ||
		    !cmd->data || !cmd->len || cmd->len > 17 ||
		    cmd->downstream_flags != (terminal ? 0 : BIT(6)) ||
		    cmd->delay_ms != (i == 106 ? 120 : 0))
			return -EINVAL;
		count++;
		bytes += ALIGN(cmd->len + 4, 4);
		if (terminal || bytes > 240) {
			if (count > ARRAY_SIZE(msgs) || bytes > 248)
				return -E2BIG;
			chunks++;
			total += bytes;
			count = bytes = 0;
		}
	}
	if (count || chunks != 8 || total != 884)
		return -EINVAL;
	chunks = total = 0;
	for (i = 0; i < profile->on_count; i++) {
		const struct o82_command *cmd = &profile->on[i];

		if (count == ARRAY_SIZE(msgs))
			return -E2BIG;
		msgs[count++] = (struct mipi_dsi_msg) {
			.channel = cmd->channel, .type = cmd->type,
			.flags = MIPI_DSI_MSG_USE_LPM, .tx_len = cmd->len,
			.tx_buf = cmd->data,
		};
		bytes += ALIGN(cmd->len + 4, 4);
		/* OEM includes the nonterminal packet crossing240 in this DMA. */
		if (!(cmd->downstream_flags & BIT(6)) || bytes > 240) {
			ret = qcom_uke_dsi_on_batch(ctx->dsi[0], msgs, count);
			/* A failed DMA may still reach the panel; preserve its settle delay. */
			if (cmd->delay_ms)
				msleep(cmd->delay_ms);
			if (ret) {
				dev_err(&ctx->dsi[0]->dev,
					"O82 ON batch failed: command=%u chunk=%u bytes=%u result=%d\n",
					i, chunks, bytes, ret);
				return ret;
			}
			chunks++;
			total += bytes;
			count = bytes = 0;
		}
	}
	dev_info(&ctx->dsi[0]->dev,
		 "Uke O82 LP ON batching complete: commands=108 chunks=%u bytes=%u\n",
		 chunks, total);
	return 0;
}

static int o82_power_off(struct o82_panel *ctx)
{
	int i, ret, first_error = 0;

	o82_touch_state(ctx, false, false);
	if (ctx->reset_output)
		gpiod_set_value_cansleep(ctx->reset, 0);
	for (i = ARRAY_SIZE(ctx->supplies) - 1; i >= 0; i--) {
		if (ctx->enabled_supplies & BIT(i)) {
			ret = regulator_disable(ctx->supplies[i]);
			if (ret && !first_error)
				first_error = ret;
			if (!ret)
				ctx->enabled_supplies &= ~BIT(i);
		}
		if (!(ctx->enabled_supplies & BIT(i)) && (ctx->loaded_supplies & BIT(i))) {
			ret = regulator_set_load(ctx->supplies[i], 0);
			if (ret && !first_error)
				first_error = ret;
			if (!ret)
				ctx->loaded_supplies &= ~BIT(i);
		}
		msleep(2);
	}
	return first_error;
}

static void o82_readback(struct o82_panel *ctx, bool post_frame)
{
	static const u8 registers[] = {
		0xda, MIPI_DCS_GET_POWER_MODE, MIPI_DCS_GET_PIXEL_FORMAT,
		MIPI_DCS_GET_DISPLAY_MODE, MIPI_DCS_GET_SIGNAL_MODE,
		MIPI_DCS_GET_DIAGNOSTIC_RESULT,
		MIPI_DCS_GET_CONTROL_DISPLAY,
	};
	/* Exact Uke OEM reads use command-master DSI0, not the secondary link. */
	struct mipi_dsi_device *dsi = ctx->dsi[0];
	unsigned int count = post_frame ? ARRAY_SIZE(registers) : 2;
	int i;

	/* Isolate initial120 optics from advisory bus-turnaround traffic. */
	if (ctx->initial_120hz_only ||
	    (ctx->oem_refresh_modes && !ctx->trial_60_120_only))
		return;

	for (i = 0; i < count; i++) {
		unsigned long mode_flags = dsi->mode_flags;
		u8 value = 0;
		ssize_t ret;

		/* OEM build-ID reads use HS; restore the original flags afterward. */
		dsi->mode_flags &= ~MIPI_DSI_MODE_LPM;
		ret = mipi_dsi_dcs_read(dsi, registers[i], &value, sizeof(value));
		dsi->mode_flags = mode_flags;
		if (ret == 1)
			dev_info(&dsi->dev,
				 "O82 readback: link=0 cmd=%#x hs result=%zd value=%#x phase=%s\n",
				 registers[i], ret, value, post_frame ? "post-frame" : "pre-video");
		else
			dev_warn(&dsi->dev,
				 "O82 readback: link=0 cmd=%#x hs result=%zd value=unavailable phase=%s\n",
				 registers[i], ret, post_frame ? "post-frame" : "pre-video");
		if (post_frame && ret != 1)
			return;
	}
}

static int o82_read_initial_mode(struct o82_panel *ctx, struct device_node *node)
{
	ctx->initial_60hz_only = of_property_read_bool(node, "xiaomi,initial-60hz-only");
	ctx->initial_120hz_only = of_property_read_bool(node, "xiaomi,initial-120hz-only");
	ctx->oem_refresh_modes = of_property_read_bool(node, "xiaomi,oem-refresh-modes");
	ctx->trial_60_120_only = of_property_read_bool(node, "xiaomi,o82-36-60-120-trial");
	ctx->trial_all_rates = of_property_read_bool(node, "xiaomi,o82-36-all-rates-trial");
	if ((ctx->initial_60hz_only && ctx->initial_120hz_only) ||
	    (ctx->oem_refresh_modes && (ctx->initial_60hz_only || ctx->initial_120hz_only)) ||
	    (ctx->trial_all_rates && !ctx->trial_60_120_only) ||
	    (ctx->trial_60_120_only &&
	     (!ctx->oem_refresh_modes ||
	      !of_device_is_compatible(node, "xiaomi,o82-36-02-0a"))) ||
	    ((ctx->initial_120hz_only || ctx->oem_refresh_modes) &&
	     !of_device_is_compatible(node, "xiaomi,o82-42-02-0b") &&
	     !ctx->trial_60_120_only))
		return -EINVAL;
	return 0;
}

static int o82_prepare_locked(struct drm_panel *panel)
{
	struct o82_panel *ctx = container_of(panel, struct o82_panel, panel);
	struct drm_dsc_picture_parameter_set pps;
	const struct o82_command pps_cmd = {
		.type = MIPI_DSI_PICTURE_PARAMETER_SET,
		.len = sizeof(pps), .data = (const u8 *)&pps,
	};
	int i, ret;
	const struct drm_display_mode *mode;
	const struct o82_profile *profile = NULL;

	if (ctx->removing)
		return -ESHUTDOWN;
	if (!ctx->connector || !ctx->connector->state ||
	    !ctx->connector->state->crtc || !ctx->connector->state->crtc->state) {
		dev_err(&ctx->dsi[0]->dev, "O82 prepare has no active connector state\n");
		return -EINVAL;
	}
	mode = &ctx->connector->state->crtc->state->adjusted_mode;
	for (i = 0; i < ARRAY_SIZE(o82_modes); i++) {
		/* The isolated OEM 120 Hz comparison must not power another mode. */
		if (ctx->initial_120hz_only && drm_mode_vrefresh(&o82_modes[i].mode) != 120)
			continue;
		if (ctx->trial_60_120_only && !ctx->trial_all_rates &&
		    drm_mode_vrefresh(&o82_modes[i].mode) != 60 &&
		    drm_mode_vrefresh(&o82_modes[i].mode) != 120)
			continue;
		if (drm_mode_equal(mode, &o82_modes[i].mode)) {
			profile = &ctx->profiles[o82_modes[i].group];
			break;
		}
	}
	if (!profile) {
		dev_err(&ctx->dsi[0]->dev, "O82 prepare mode rejected: %dx%d clock=%d htotal=%d vtotal=%d\n",
			mode->hdisplay, mode->vdisplay, mode->clock, mode->htotal, mode->vtotal);
		return -EINVAL;
	}

	if (ctx->prepared)
		return ctx->active == profile ? 0 : -EBUSY;
	if (ctx->dsc.pic_width != 3200 || ctx->dsc.pic_height != 2136 ||
	    ctx->dsc.slice_width != 800 || ctx->dsc.slice_height != 24 ||
	    ctx->dsc.rc_model_size != 8192 || ctx->dsc.initial_dec_delay != 690 ||
	    ctx->dsc.first_line_bpg_offset != 13 ||
	    ctx->dsc.rc_range_params[0].range_max_qp != 8)
		return -EINVAL;
	/* Do not accumulate enable references after a failed power-down. */
	if (ctx->enabled_supplies || ctx->loaded_supplies)
		return -EBUSY;
	ret = backlight_disable(ctx->backlight);
	if (ret)
		return ret;
	ctx->active = profile;
	for (i = 0; i < ARRAY_SIZE(ctx->supplies); i++) {
		ret = regulator_set_load(ctx->supplies[i], 300000);
		if (ret < 0) {
			dev_err(&ctx->dsi[0]->dev, "O82 supply[%d] load failed: %d\n", i, ret);
			goto rollback_supplies;
		}
		ctx->loaded_supplies |= BIT(i);
		ret = regulator_enable(ctx->supplies[i]);
		if (ret) {
			dev_err(&ctx->dsi[0]->dev, "O82 supply[%d] enable failed: %d\n", i, ret);
			goto rollback_supplies;
		}
		ctx->enabled_supplies |= BIT(i);
		msleep(2);
	}
	/* ASIS at probe preserves splash; establish direction before first toggle. */
	/* O82 RESX is also the NT36532 reset; firmware must follow completed DSI setup. */
	o82_touch_state(ctx, true, false);
	ret = gpiod_direction_output(ctx->reset, 0);
	if (ret) {
		dev_err(&ctx->dsi[0]->dev, "O82 reset direction failed: %d\n", ret);
		goto rollback_supplies;
	}
	ctx->reset_output = true;
	msleep(10);
	gpiod_set_value_cansleep(ctx->reset, 1);
	msleep(3);
	gpiod_set_value_cansleep(ctx->reset, 0);
	msleep(3);
	gpiod_set_value_cansleep(ctx->reset, 1);
	msleep(15);
	if (ctx->initial_120hz_only ||
	    (ctx->oem_refresh_modes && !ctx->trial_60_120_only)) {
		ret = o82_on_batch(ctx);
		if (ret)
			goto failed_on;
	} else {
		for (i = 0; i < profile->on_count; i++) {
			ret = o82_send(ctx, &profile->on[i], true);
			if (ret) {
				dev_err(&ctx->dsi[0]->dev, "O82 prepare command[%d] failed: %d\n", i, ret);
				goto failed_on;
			}
		}
	}
	/* OEM panel PPS describes the full picture, independently of encoder split. */
	drm_dsc_pps_payload_pack(&pps, &ctx->dsc);
	ret = o82_send(ctx, &pps_cmd, true);
	if (ret) {
		o82_off(ctx);
		o82_power_off(ctx);
		return ret;
	}
	o82_readback(ctx, false);
	ctx->prepared = true;
	return 0;

failed_on:
	dev_err(&ctx->dsi[0]->dev, "O82 prepare ON failed: result=%d\n", ret);
	o82_off(ctx);
	o82_power_off(ctx);
	return ret;
rollback_supplies:
	o82_power_off(ctx);
	return ret;
}

static int o82_prepare(struct drm_panel *panel)
{
	struct o82_panel *ctx = container_of(panel, struct o82_panel, panel);
	int ret;

	mutex_lock(&ctx->lock);
	ret = o82_prepare_locked(panel);
	mutex_unlock(&ctx->lock);
	return ret;
}

static void o82_cancel_first_frame(struct o82_panel *ctx)
{
	if (ctx->first_frame_initialized) {
		drm_vblank_work_cancel_sync(&ctx->first_frame_work);
		ctx->first_frame_initialized = false;
		ctx->first_frame_crtc = NULL;
	}
}

static void o82_first_frame(struct kthread_work *work)
{
	struct drm_vblank_work *vblank_work = to_drm_vblank_work(work);
	struct o82_panel *ctx = container_of(vblank_work, struct o82_panel, first_frame_work);
	const struct o82_command normal_pixels[] = {
		{ .type = 0x15, .downstream_flags = BIT(6), .len = 2, .data = (const u8[]) { 0xff, 0x10 } },
		{ .type = 0x39, .len = 2, .data = (const u8[]) { 0x13, 0x00 } },
	};
	const struct o82_command dimming_on[] = {
		{ .type = 0x39, .downstream_flags = BIT(6), .len = 2, .data = (const u8[]) { 0xff, 0x27 } },
		{ .type = 0x39, .downstream_flags = BIT(6), .len = 2, .data = (const u8[]) { 0xd1, 0x28 } },
		{ .type = 0x15, .downstream_flags = BIT(6), .len = 2, .data = (const u8[]) { 0xff, 0x10 } },
		{ .type = 0x15, .len = 2, .data = (const u8[]) { 0x53, 0x2c } },
	};
	const char *stage = "prepared";
	int i = -1, ret, blank_ret, brightness;

	dev_info(&ctx->dsi[0]->dev,
		 "O82 first-frame boundary: target=%llu current=%llu\n",
		 (unsigned long long)ctx->first_frame_target,
		 (unsigned long long)drm_crtc_vblank_count(ctx->first_frame_crtc));
	if (!ctx->prepared) {
		ret = -EINVAL;
		goto failed;
	}
	/* OEM starts DPU timing before its four HS TP-FPS updates. */
	stage = "timing-switch";
	if (ctx->initial_120hz_only ||
	    (ctx->oem_refresh_modes && !ctx->trial_60_120_only)) {
		struct mipi_dsi_msg msgs[4] = { };

		if (ctx->active->switch_count != ARRAY_SIZE(msgs)) {
			ret = -EINVAL;
			goto failed;
		}
		for (i = 0; i < ARRAY_SIZE(msgs); i++) {
			const struct o82_command *cmd = &ctx->active->switch_commands[i];

			if (cmd->delay_ms || cmd->downstream_flags != (i == 3 ? 0 : BIT(6))) {
				ret = -EINVAL;
				goto failed;
			}
			msgs[i].channel = cmd->channel;
			msgs[i].type = cmd->type;
			msgs[i].tx_len = cmd->len;
			msgs[i].tx_buf = cmd->data;
		}
		i = -1;
		ret = qcom_uke_dsi_tp_fps_batch(ctx->dsi[0], msgs);
		if (ret)
			goto failed;
	} else {
		for (i = 0; i < ctx->active->switch_count; i++) {
			ret = o82_send(ctx, &ctx->active->switch_commands[i], false);
			if (ret)
				goto failed;
		}
	}
	i = -1;
	stage = "normal-pixels";
	if (ctx->initial_120hz_only ||
	    (ctx->oem_refresh_modes && !ctx->trial_60_120_only)) {
		i = -1;
		ret = o82_lp_batch(ctx, normal_pixels, ARRAY_SIZE(normal_pixels));
		if (ret)
			goto failed;
	} else {
		for (i = 0; i < ARRAY_SIZE(normal_pixels); i++) {
			ret = o82_send(ctx, &normal_pixels[i], true);
			if (ret)
				goto failed;
		}
	}
	dev_info(&ctx->dsi[0]->dev, "O82 first-frame normal-pixels complete\n");
	if (ctx->initial_120hz_only ||
	    (ctx->oem_refresh_modes && !ctx->trial_60_120_only)) {
		/* Installed OEM uses a separate four-packet LP dimming group. */
		stage = "dimming-on";
		i = -1;
		ret = o82_lp_batch(ctx, dimming_on, ARRAY_SIZE(dimming_on));
		if (ret)
			goto failed;
		dev_info(&ctx->dsi[0]->dev, "O82 first-frame dimming-on complete\n");
	}
	/* Keep the LCD dark until both links leave the initialization state. */
	stage = "backlight";
	ret = backlight_enable(ctx->backlight);
	if (ret)
		goto failed;
	brightness = backlight_get_brightness(ctx->backlight);
	if (brightness <= 0) {
		ret = -ERANGE;
		goto failed;
	}
	dev_info(&ctx->dsi[0]->dev,
		 "O82 first-frame checked backlight: brightness=%d result=0\n", brightness);
	o82_touch_state(ctx, false, true);
	return;

failed:
	o82_touch_state(ctx, false, false);
	blank_ret = backlight_disable(ctx->backlight);
	dev_err(&ctx->dsi[0]->dev,
		"O82 first-frame restoration failed: stage=%s command=%d result=%d blank_result=%d\n",
		stage, i, ret, blank_ret);
}

static int o82_enable_locked(struct drm_panel *panel)
{
	struct o82_panel *ctx = container_of(panel, struct o82_panel, panel);
	struct drm_crtc *crtc;
	int ret;

	if (ctx->removing)
		return -ESHUTDOWN;
	if (!ctx->prepared || !ctx->backlight || !ctx->connector ||
	    !ctx->connector->state || !ctx->connector->state->crtc)
		return -EINVAL;
	if (ctx->first_frame_initialized)
		return -EBUSY;
	crtc = ctx->connector->state->crtc;
	/* MSM kicks off after panel enable, so the first-frame gate must not block. */
	ctx->first_frame_crtc = crtc;
	ctx->first_frame_target = drm_crtc_vblank_count(crtc) + 1;
	drm_vblank_work_init(&ctx->first_frame_work, crtc, o82_first_frame);
	ctx->first_frame_initialized = true;
	dev_info(&ctx->dsi[0]->dev, "O82 first-frame arm: target=%llu\n",
		 (unsigned long long)ctx->first_frame_target);
	ret = drm_vblank_work_schedule(&ctx->first_frame_work,
				       ctx->first_frame_target, true);
	if (ret <= 0) {
		o82_cancel_first_frame(ctx);
		ret = ret < 0 ? ret : -EIO;
		dev_err(&ctx->dsi[0]->dev, "O82 first-frame schedule refused: %d\n",
			ret);
		return ret;
	}
	return 0;
}

static int o82_enable(struct drm_panel *panel)
{
	struct o82_panel *ctx = container_of(panel, struct o82_panel, panel);
	int ret;

	mutex_lock(&ctx->lock);
	ret = o82_enable_locked(panel);
	mutex_unlock(&ctx->lock);
	return ret;
}

static void o82_disable_locked(struct o82_panel *ctx)
{
	int ret;

	o82_cancel_first_frame(ctx);
	o82_touch_state(ctx, false, false);
	ret = backlight_disable(ctx->backlight);
	if (ret)
		dev_err(&ctx->dsi[0]->dev, "O82 backlight blank failed: %d\n", ret);
}

static int o82_disable(struct drm_panel *panel)
{
	struct o82_panel *ctx = container_of(panel, struct o82_panel, panel);

	mutex_lock(&ctx->lock);
	o82_disable_locked(ctx);
	mutex_unlock(&ctx->lock);
	return 0;
}

static int o82_unprepare(struct drm_panel *panel)
{
	struct o82_panel *ctx = container_of(panel, struct o82_panel, panel);
	int ret = 0, power_ret;

	mutex_lock(&ctx->lock);
	o82_disable_locked(ctx);
	if (!ctx->prepared && !ctx->enabled_supplies && !ctx->loaded_supplies)
		goto out;
	ret = ctx->prepared ? o82_off(ctx) : 0;
	power_ret = o82_power_off(ctx);
	ctx->prepared = false;
	ret = ret ? ret : power_ret;
out:
	mutex_unlock(&ctx->lock);
	return ret;
}

static int o82_get_modes(struct drm_panel *panel, struct drm_connector *connector)
{
	struct o82_panel *ctx = container_of(panel, struct o82_panel, panel);
	int i, count = 0;

	ctx->connector = connector;
	for (i = 0; i < ARRAY_SIZE(o82_modes); i++) {
		struct drm_display_mode *mode;
		if (ctx->initial_60hz_only && drm_mode_vrefresh(&o82_modes[i].mode) != 60)
			continue;
		if (ctx->trial_60_120_only && !ctx->trial_all_rates &&
		    drm_mode_vrefresh(&o82_modes[i].mode) != 60 &&
		    drm_mode_vrefresh(&o82_modes[i].mode) != 120)
			continue;
		if (ctx->initial_120hz_only && drm_mode_vrefresh(&o82_modes[i].mode) != 120)
			continue;
		mode = drm_mode_duplicate(connector->dev, &o82_modes[i].mode);
		if (!mode)
			return -ENOMEM;
		drm_mode_set_name(mode);
		mode->type = DRM_MODE_TYPE_DRIVER;
		if (drm_mode_vrefresh(mode) ==
		    (ctx->initial_120hz_only ||
		     (ctx->oem_refresh_modes && !ctx->trial_60_120_only) ? 120 : 60))
			mode->type |= DRM_MODE_TYPE_PREFERRED;
		drm_mode_probed_add(connector, mode);
		count++;
	}
	connector->display_info.bpc = 10;
	connector->display_info.width_mm = 237;
	connector->display_info.height_mm = 158;
	qcom_uke_dsi_update_vrr(ctx->dsi[0], connector);
	return count;
}

static bool o82_dfps_check_locked(struct o82_panel *ctx,
		const struct drm_display_mode *old, const struct drm_display_mode *new_mode)
{
	int old_group = qcom_uke_o82_mode_group(old);

	return qcom_uke_o82_live_change(old, new_mode) &&
		ctx->oem_refresh_modes &&
		((ctx->profiles == o82_42_02_0b_profiles && !ctx->trial_60_120_only) ||
		 (ctx->profiles == o82_36_02_0a_profiles && ctx->trial_60_120_only &&
		  (ctx->trial_all_rates ||
		   ((drm_mode_vrefresh(old) == 60 || drm_mode_vrefresh(old) == 120) &&
		    (drm_mode_vrefresh(new_mode) == 60 ||
		     drm_mode_vrefresh(new_mode) == 120))))) &&
		ctx->active == &ctx->profiles[old_group] && ctx->prepared &&
		!ctx->removing && (atomic64_read(&ctx->touch_state) & 1);
}

static bool o82_dfps_check(struct drm_panel *panel,
		const struct drm_display_mode *old, const struct drm_display_mode *new_mode)
{
	struct o82_panel *ctx;
	bool ready;

	if (!panel)
		return false;
	ctx = container_of(panel, struct o82_panel, panel);
	mutex_lock(&ctx->lock);
	ready = o82_dfps_check_locked(ctx, old, new_mode);
	mutex_unlock(&ctx->lock);
	return ready;
}

static int o82_dfps_apply(struct drm_panel *panel,
		const struct drm_display_mode *old, const struct drm_display_mode *new_mode,
		bool before)
{
	static const u8 pen_clear[3][2] = { { 0xff, 0x10 }, { 0xfb, 0x01 }, { 0xb2, 0x80 } };
	struct o82_panel *ctx;
	const struct o82_profile *target;
	struct mipi_dsi_msg msgs[4] = { };
	int i, ret = -EAGAIN;

	if (!panel)
		return -EINVAL;
	ctx = container_of(panel, struct o82_panel, panel);
	mutex_lock(&ctx->lock);
	if (!o82_dfps_check_locked(ctx, old, new_mode))
		goto out;
	if (before) {
		ret = 0;
		/* OEM clears the 60 Hz pen setting before entering another timing group. */
		if (drm_mode_vrefresh(old) == 60 && drm_mode_vrefresh(new_mode) != 120) {
			for (i = 0; i < ARRAY_SIZE(pen_clear); i++)
				msgs[i] = (struct mipi_dsi_msg) {
					.type = MIPI_DSI_DCS_LONG_WRITE,
					.tx_len = sizeof(pen_clear[i]), .tx_buf = pen_clear[i],
				};
			ret = qcom_uke_dsi_pen_clear_batch(ctx->dsi[0], msgs);
		}
		goto out;
	}
	target = &ctx->profiles[qcom_uke_o82_mode_group(new_mode)];
	if (target->switch_count != ARRAY_SIZE(msgs)) {
		ret = -EINVAL;
		goto out;
	}
	for (i = 0; i < ARRAY_SIZE(msgs); i++) {
		const struct o82_command *cmd = &target->switch_commands[i];

		if (cmd->delay_ms || cmd->downstream_flags != (i == 3 ? 0 : BIT(6))) {
			ret = -EINVAL;
			goto out;
		}
		msgs[i] = (struct mipi_dsi_msg) {
			.channel = cmd->channel, .type = cmd->type,
			.tx_len = cmd->len, .tx_buf = cmd->data,
		};
	}
	/* OEM sends this group after every video timing kickoff, including VFP-only changes. */
	ret = qcom_uke_dsi_tp_fps_batch(ctx->dsi[0], msgs);
	if (!ret)
		ctx->active = target;
out:
	mutex_unlock(&ctx->lock);
	return ret;
}

static const struct qcom_uke_o82_dfps_ops o82_dfps_ops = {
	.check = o82_dfps_check,
	.apply = o82_dfps_apply,
};

static const struct drm_panel_funcs o82_funcs = {
	.prepare = o82_prepare,
	.enable = o82_enable,
	.disable = o82_disable,
	.unprepare = o82_unprepare,
	.get_modes = o82_get_modes,
};

static ssize_t touch_reset_state_show(struct device *dev,
				     struct device_attribute *attr, char *buf)
{
	struct o82_panel *ctx = dev_get_drvdata(dev);
	u64 state = (u64)atomic64_read(&ctx->touch_state);

	return sysfs_emit(buf, "%llu %u\n", state >> 1, (unsigned int)(state & 1));
}
static DEVICE_ATTR_RO(touch_reset_state);
static struct attribute *o82_attrs[] = { &dev_attr_touch_reset_state.attr, NULL };
ATTRIBUTE_GROUPS(o82);

static int o82_probe(struct mipi_dsi_device *dsi)
{
	static const char * const supply_names[] = { "vddio", "vsp", "vsn" };
	static const int supply_voltages[] = { 1900000, 5800000, 5800000 };
	struct device *dev = &dsi->dev;
	struct device_node *node;
	struct mipi_dsi_host *host;
	struct o82_panel *ctx;
	const struct mipi_dsi_device_info info = { .type = "o82-secondary", .channel = 0 };
	int i, ret;

	ctx = devm_drm_panel_alloc(dev, struct o82_panel, panel, &o82_funcs,
				 DRM_MODE_CONNECTOR_DSI);
	if (IS_ERR(ctx))
		return PTR_ERR(ctx);
	mutex_init(&ctx->lock);
	atomic64_set(&ctx->touch_state, 0);
	ctx->dsi[0] = dsi;
	ctx->profiles = of_device_get_match_data(dev);
	if (!ctx->profiles)
		return -EINVAL;
	ctx->active = &ctx->profiles[0];
	ret = o82_read_initial_mode(ctx, dev->of_node);
	if (ret)
		return dev_err_probe(dev, ret, "Invalid initial panel mode profile\n");
	for (i = 0; i < ARRAY_SIZE(supply_names); i++) {
		ctx->supplies[i] = devm_regulator_get(dev, supply_names[i]);
		if (IS_ERR(ctx->supplies[i]))
			return dev_err_probe(dev, PTR_ERR(ctx->supplies[i]), "Missing panel supply\n");
		ret = regulator_set_voltage(ctx->supplies[i], supply_voltages[i], supply_voltages[i]);
		if (ret)
			return dev_err_probe(dev, ret, "Cannot set stock panel voltage\n");
	}
	ctx->reset = devm_gpiod_get(dev, "reset", GPIOD_ASIS);
	if (IS_ERR(ctx->reset))
		return dev_err_probe(dev, PTR_ERR(ctx->reset), "Missing reset GPIO\n");
	node = of_graph_get_remote_node(dev->of_node, 1, -1);
	if (!node)
		return -ENODEV;
	host = of_find_mipi_dsi_host_by_node(node);
	of_node_put(node);
	if (!host)
		return -EPROBE_DEFER;
	ctx->dsi[1] = mipi_dsi_device_register_full(host, &info);
	if (IS_ERR(ctx->dsi[1]))
		return PTR_ERR(ctx->dsi[1]);
	ctx->dsc.dsc_version_major = 1;
	ctx->dsc.dsc_version_minor = 1;
	ctx->dsc.slice_width = 800;
	ctx->dsc.slice_height = 24;
	ctx->dsc.slice_count = 2;
	ctx->dsc.bits_per_component = 10;
	ctx->dsc.bits_per_pixel = 8 << 4;
	ctx->dsc.block_pred_enable = true;
	ctx->backlight = devm_of_find_backlight(dev);
	if (IS_ERR(ctx->backlight)) {
		ret = PTR_ERR(ctx->backlight);
		goto unregister_secondary;
	}
	if (!ctx->backlight) {
		ret = -ENODEV;
		goto unregister_secondary;
	}
	/* DSI attachment can bind MSM and replace the lit firmware scanout. */
	ret = backlight_disable(ctx->backlight);
	if (ret)
		goto unregister_secondary;
	mipi_dsi_set_drvdata(dsi, ctx);
	ctx->panel.prepare_prev_first = true;
	drm_panel_add(&ctx->panel);
	for (i = 0; i < ARRAY_SIZE(ctx->dsi); i++) {
		ctx->dsi[i]->lanes = 4;
		/* OEM 30-bpp input retains RGB101010 on the DSC-capable wide bus. */
		ctx->dsi[i]->format = MIPI_DSI_FMT_RGB101010;
		/* O82 OEM does not force the clock lane to remain in HS. */
		ctx->dsi[i]->mode_flags = MIPI_DSI_MODE_VIDEO |
			MIPI_DSI_CLOCK_NON_CONTINUOUS | MIPI_DSI_MODE_LPM;
		ctx->dsi[i]->dsc = &ctx->dsc;
		ret = mipi_dsi_attach(ctx->dsi[i]);
		if (ret)
			goto detach_attached;
	}
	if (ctx->oem_refresh_modes) {
		ret = qcom_uke_dsi_dfps_register(dsi, &ctx->panel, &o82_dfps_ops);
		if (ret)
			goto detach_attached;
	}
	return 0;

detach_attached:
	while (--i >= 0)
		mipi_dsi_detach(ctx->dsi[i]);
	drm_panel_remove(&ctx->panel);
unregister_secondary:
	mipi_dsi_device_unregister(ctx->dsi[1]);
	return ret;
}

static void o82_remove(struct mipi_dsi_device *dsi)
{
	struct o82_panel *ctx = mipi_dsi_get_drvdata(dsi);

	if (ctx->oem_refresh_modes)
		qcom_uke_dsi_dfps_register(dsi, &ctx->panel, NULL);
	mutex_lock(&ctx->lock);
	ctx->removing = true;
	mutex_unlock(&ctx->lock);
	drm_panel_disable(&ctx->panel);
	if (o82_unprepare(&ctx->panel))
		dev_warn(&dsi->dev, "Panel power-down failed during removal\n");
	mipi_dsi_detach(ctx->dsi[1]);
	mipi_dsi_detach(ctx->dsi[0]);
	drm_panel_remove(&ctx->panel);
	mipi_dsi_device_unregister(ctx->dsi[1]);
}

static void o82_shutdown(struct mipi_dsi_device *dsi)
{
	struct o82_panel *ctx = mipi_dsi_get_drvdata(dsi);

	if (ctx->oem_refresh_modes)
		qcom_uke_dsi_dfps_register(dsi, &ctx->panel, NULL);
	mutex_lock(&ctx->lock);
	ctx->removing = true;
	mutex_unlock(&ctx->lock);
	drm_panel_disable(&ctx->panel);
	if (o82_unprepare(&ctx->panel))
		dev_warn(&dsi->dev, "Panel power-down failed during shutdown\n");
}

static const struct of_device_id o82_match[] = {
	{ .compatible = "xiaomi,o82-36-02-0a", .data = o82_36_02_0a_profiles },
	{ .compatible = "xiaomi,o82-42-02-0b", .data = o82_42_02_0b_profiles },
	{ }
};
MODULE_DEVICE_TABLE(of, o82_match);

static struct mipi_dsi_driver o82_driver = {
	.probe = o82_probe,
	.remove = o82_remove,
	.shutdown = o82_shutdown,
	.driver = { .name = "panel-xiaomi-o82", .of_match_table = o82_match,
		    .dev_groups = o82_groups },
};
module_mipi_dsi_driver(o82_driver);
MODULE_DESCRIPTION("Xiaomi O82 dual-DSI panel with OEM timing groups");
MODULE_LICENSE("GPL");
