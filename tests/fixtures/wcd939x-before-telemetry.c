// SPDX-License-Identifier: GPL-2.0-only
/*
 * Copyright (c) 2018-2021, The Linux Foundation. All rights reserved.
 * Copyright (c) 2022-2023, Qualcomm Innovation Center, Inc. All rights reserved.
 * Copyright (c) 2023, Linaro Limited
 */

static int wcd939x_get_hph_type(struct snd_kcontrol *kcontrol,
				struct snd_ctl_elem_value *ucontrol)
{
	struct snd_soc_component *component = snd_kcontrol_chip(kcontrol);
	struct wcd939x_priv *wcd939x = snd_soc_component_get_drvdata(component);

	ucontrol->value.integer.value[0] = wcd_mbhc_get_hph_type(wcd939x->wcd_mbhc);

	return 0;
}

static int wcd939x_hph_impedance_get(struct snd_kcontrol *kcontrol,
				     struct snd_ctl_elem_value *ucontrol)
{
	struct soc_mixer_control *mc = (struct soc_mixer_control *)(kcontrol->private_value);
	struct snd_soc_component *component = snd_kcontrol_chip(kcontrol);
	struct wcd939x_priv *wcd939x = snd_soc_component_get_drvdata(component);
	bool hphr = mc->shift;
	u32 zl, zr;

	wcd_mbhc_get_impedance(wcd939x->wcd_mbhc, &zl, &zr);
	dev_dbg(component->dev, "%s: zl=%u(ohms), zr=%u(ohms)\n", __func__, zl, zr);
	ucontrol->value.integer.value[0] = hphr ? zr : zl;

	return 0;
}

static const struct snd_kcontrol_new hph_type_detect_controls[] = {
	SOC_SINGLE_EXT("HPH Type", 0, 0, UINT_MAX, 0,
		       wcd939x_get_hph_type, NULL),
};

static const struct snd_kcontrol_new impedance_detect_controls[] = {
	SOC_SINGLE_EXT("HPHL Impedance", 0, 0, UINT_MAX, 0,
		       wcd939x_hph_impedance_get, NULL),
	SOC_SINGLE_EXT("HPHR Impedance", 0, 1, UINT_MAX, 0,
		       wcd939x_hph_impedance_get, NULL),
};
