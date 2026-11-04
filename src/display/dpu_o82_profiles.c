// SPDX-License-Identifier: GPL-2.0-only
/* Private root-resident OEM color data; never publish its tables in the kernel. */
#include <linux/errno.h>
#include <linux/firmware.h>
#include <linux/string.h>

#include "dpu_o82_profiles.h"
#include "o82-color-firmware.h"

int dpu_o82_profiles_select(struct dpu_o82_profiles *profiles, const char *name)
{
	const unsigned char *record;
	unsigned int index;

	if (!profiles || !name || !*name)
		return -EINVAL;
	if (!profiles->fw)
		return -ENODEV;
	for (index = 0; index < o82_hdr_u32(profiles->fw->data + 24); index++) {
		record = o82_color_fw_record(profiles->fw->data, index);
		if (strcmp(name, (const char *)record))
			continue;
		if (o82_hdr_u32(record + 76))
			return -EOPNOTSUPP;
		profiles->selected = index;
		return 0;
	}
	return -ENOENT;
}

int dpu_o82_profiles_load(struct dpu_o82_profiles *profiles, struct device *dev,
			 unsigned int panel)
{
	struct dpu_o82_profiles candidate = { 0 };
	const char *name;
	unsigned int version = O82_COLOR_FW_MEMORY_VERSION;
	int ret;

	if (!profiles || !dev || (panel != 0x36 && panel != 0x42))
		return -EINVAL;
	if (profiles->fw)
		return -EBUSY;
	name = panel == 0x42 ? "qcom/sm7675/uke/o82-42-color-v5.bin" :
			      "qcom/sm7675/uke/o82-36-color-v5.bin";
	ret = request_firmware_direct(&candidate.fw, name, dev);
	if (ret == -ENOENT) {
		version = O82_COLOR_FW_VERSION;
		name = panel == 0x42 ? "qcom/sm7675/uke/o82-42-color-v4.bin" :
				      "qcom/sm7675/uke/o82-36-color-v4.bin";
		ret = request_firmware_direct(&candidate.fw, name, dev);
	}
	if (ret)
		return ret;
	if (!o82_color_fw_valid(candidate.fw->data, candidate.fw->size, panel) ||
	    o82_hdr_u32(candidate.fw->data + 8) != version) {
		ret = -EBADMSG;
		goto release;
	}
	ret = dpu_o82_profiles_select(&candidate, "standard_P3");
	if (ret)
		goto release;
	*profiles = candidate;
	return 0;
release:
	release_firmware(candidate.fw);
	return ret;
}

void dpu_o82_profiles_unload(struct dpu_o82_profiles *profiles)
{
	if (!profiles)
		return;
	if (profiles->fw)
		release_firmware(profiles->fw);
	profiles->fw = NULL;
	profiles->selected = 0;
}

int dpu_o82_profiles_input(const struct dpu_o82_profiles *profiles,
			  unsigned int bt2020, unsigned int pq,
			  struct dpu_o82_color_input *input)
{
	struct dpu_o82_color_input candidate = { 0 };
	const unsigned char *record;

	if (!profiles || !input)
		return -EINVAL;
	if (!profiles->fw)
		return -ENODEV;
	candidate.gamut = o82_color_fw_data(profiles->fw->data, profiles->selected,
					  bt2020, pq, &candidate.igc, &candidate.gc);
	if (!candidate.gamut)
		return -EINVAL;
	record = o82_color_fw_record(profiles->fw->data, profiles->selected);
	candidate.primaries = o82_hdr_u32(record + 64);
	candidate.dither_enabled = o82_hdr_u32(record + 128);
	candidate.dither_strength = o82_hdr_u32(record + 132);
	candidate.pa_managed = true;
	candidate.sixzone_bytes = o82_hdr_u32(record + 140);
	if (candidate.sixzone_bytes)
		candidate.sixzone = profiles->fw->data + o82_hdr_u32(record + 136);
	candidate.hsic = profiles->fw->data + o82_hdr_u32(record + 144);
	candidate.hsic_bytes = o82_hdr_u32(record + 148);
	if (o82_hdr_u32(profiles->fw->data + 8) == O82_COLOR_FW_MEMORY_VERSION) {
		candidate.memory = profiles->fw->data + o82_hdr_u32(record + 152);
		candidate.memory_bytes = o82_hdr_u32(record + 156);
	}
	*input = candidate;
	return 0;
}
