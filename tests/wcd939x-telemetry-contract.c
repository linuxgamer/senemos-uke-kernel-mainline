/* SPDX-License-Identifier: GPL-2.0-only */
/* Compiled after the actual Linux constructor, info, getter and table sources. */
static const struct snd_kcontrol_new *templates[] = {
	&impedance_detect_controls[0], &impedance_detect_controls[1],
	&hph_type_detect_controls[0],
};
static const char *const names[] = { "HPHL Impedance", "HPHR Impedance", "HPH Type" };
static void metadata(bool access, bool range)
{
	struct snd_soc_component component = {};

	assert(sizeof(unsigned long) == 8);
	for (unsigned int i = 0; i < 3; i++) {
		struct snd_kcontrol *control = snd_ctl_new1(templates[i], &component);
		struct snd_ctl_elem_info info = {};
		const struct soc_mixer_control *mixer;

		assert(control && !strcmp(control->id.name, names[i]));
		assert(control->id.iface == SNDRV_CTL_ELEM_IFACE_MIXER);
		assert(!control->id.index && !control->id.device && !control->id.subdevice);
		assert(control->get == (i == 2 ? wcd939x_get_hph_type : wcd939x_hph_impedance_get));
		assert(!control->put && control->count == 1);
		mixer = (const struct soc_mixer_control *)control->private_value;
		assert(mixer->reg == 0 && mixer->rreg == 0 && mixer->min == 0);
		assert(mixer->shift == (i == 1) && mixer->rshift == (i == 1));
		if (access)
			assert(control->access == SNDRV_CTL_ELEM_ACCESS_READ &&
			       "Cached jack telemetry must be read-only");
		assert(!control->info(control, &info));
		assert(info.type == SNDRV_CTL_ELEM_TYPE_INTEGER && info.count == 1);
		assert(info.value.integer.min == 0);
		if (range)
			assert(info.value.integer.max == (i == 2 ? WCD_MBHC_HPH_STEREO : INT_MAX) &&
			       "Cached jack telemetry must have a valid maximum");
		free(control);
	}
}
static void cached_values(void)
{
	const u32 values[] = { 0, 1, 16, 32, 100000, WCD939X_ZDET_FLOATING_IMPEDANCE, INT_MAX };
	struct wcd_mbhc mbhc = {};
	struct wcd939x_priv private = { .wcd_mbhc = &mbhc };
	struct snd_soc_component component = { .private = &private };
	struct snd_kcontrol *control[3];
	unsigned int count = 0;

	assert(WCD939X_ZDET_FLOATING_IMPEDANCE == 0x0ffffffe);
	assert(WCD939X_ZDET_FLOATING_IMPEDANCE <= INT_MAX);
	assert(WCD_MBHC_HPH_NONE == 0 && WCD_MBHC_HPH_MONO == 1 && WCD_MBHC_HPH_STEREO == 2);
	for (unsigned int i = 0; i < 3; i++) {
		control[i] = snd_ctl_new1(templates[i], &component);
		assert(control[i]);
	}
	for (unsigned int left = 0; left < 7; left++)
		for (unsigned int right = 0; right < 7; right++)
			for (int type = 0; type <= 2; type++) {
				mbhc = (struct wcd_mbhc){ .left = values[left], .right = values[right], .type = type };
				for (unsigned int i = 0; i < 3; i++) {
					struct snd_ctl_elem_value value = {};
					long expected = i == 0 ? mbhc.left : i == 1 ? mbhc.right : (u32)type;

					assert(!control[i]->get(control[i], &value));
					assert(value.value.integer.value[0] == expected);
					assert(!value.value.integer.value[1]);
					count++;
				}
			}
	assert(count == 441 && cached_reads == count);
	for (unsigned int i = 0; i < 3; i++)
		free(control[i]);
}
int main(int argc, char **argv)
{
	const char *mode = argc > 1 ? argv[1] : "all";

	assert(argc <= 2);
	if (!strcmp(mode, "access"))
		metadata(true, false);
	else if (!strcmp(mode, "range"))
		metadata(false, true);
	else if (!strcmp(mode, "values"))
		cached_values();
	else {
		assert(!strcmp(mode, "all"));
		metadata(true, true);
		cached_values();
	}
	printf("Actual WCD939x telemetry: %s PASS; real Linux control constructor/info/getters with fake cached providers\n", mode);
	return 0;
}
