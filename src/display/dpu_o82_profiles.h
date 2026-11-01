/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef DPU_O82_PROFILES_H
#define DPU_O82_PROFILES_H

#include <linux/types.h>

struct device;
struct firmware;

/* The native color owner serializes loading, selection, input lookup and unload. */
struct dpu_o82_profiles {
	const struct firmware *fw;
	unsigned int selected;
};

struct dpu_o82_color_input {
	const u8 *igc;
	const u8 *gamut;
	const u8 *gc;
	unsigned int primaries;
};

int dpu_o82_profiles_load(struct dpu_o82_profiles *profiles, struct device *dev,
			 unsigned int panel);
void dpu_o82_profiles_unload(struct dpu_o82_profiles *profiles);
/* Caller has proved the complete internal output stopped before changing preset. */
int dpu_o82_profiles_select(struct dpu_o82_profiles *profiles, const char *name);
int dpu_o82_profiles_input(const struct dpu_o82_profiles *profiles,
			  unsigned int bt2020, unsigned int pq,
			  struct dpu_o82_color_input *input);

#endif
