/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef DPU_O82_COLOR_H
#define DPU_O82_COLOR_H

#include <linux/types.h>

struct drm_crtc;
struct drm_crtc_state;
struct drm_encoder;
struct dpu_hw_gc_lut;
struct dpu_kms;

int dpu_o82_color_init(struct dpu_kms *kms);
int dpu_o82_color_connectors_init(struct dpu_kms *kms);
/* Call only after platform_fini has closed and drained the command owner. */
void dpu_o82_color_fini(struct dpu_kms *kms);
bool dpu_o82_color_requested(const struct drm_crtc_state *state);
void dpu_o82_color_mode_changed(struct drm_crtc_state *state);
int dpu_o82_color_check(struct drm_crtc *crtc, struct drm_crtc_state *state);
int dpu_o82_color_commit(struct drm_crtc *crtc);
bool dpu_o82_color_blocked(struct drm_encoder *encoder);
/* Factory GC followed by the client's optional 1024-entry gamma LUT. */
int dpu_o82_color_gc(struct drm_crtc *crtc, struct dpu_hw_gc_lut *gc);
/* Implemented next to the private physical encoder state. */
int dpu_encoder_o82_stopped(struct drm_encoder *encoder);

#endif
