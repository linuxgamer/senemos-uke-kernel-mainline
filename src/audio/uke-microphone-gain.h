/* SPDX-License-Identifier: GPL-2.0-only */
/* Uke WCD939x ADC fields and LPASS TX gain fields; no supply registers. */
#ifndef UKE_MICROPHONE_GAIN_H
#define UKE_MICROPHONE_GAIN_H

static bool uke_microphone_gain_valid(const u32 *analog, const u32 *digital)
{
	unsigned int i;

	for (i = 0; i < 4; i++)
		if (analog[i] < 1 || analog[i] > 8 || digital[i] > 24)
			return false;
	return true;
}

static int uke_microphone_apply_gain(struct snd_soc_pcm_runtime *rtd,
				     const u32 *analog, const u32 *digital)
{
	struct uke_gain_register {
		struct snd_soc_component *component;
		unsigned int reg, mask, value, previous;
	} registers[8];
	unsigned int i;
	int ret, undo;

	if (!uke_microphone_gain_valid(analog, digital))
		return -EINVAL;
	for (i = 0; i < 4; i++) {
		registers[i] = (struct uke_gain_register) {
			.component = snd_soc_rtd_to_codec(rtd, 0)->component,
			.reg = 0x300e + i, .mask = 0x1f, .value = analog[i],
		};
		registers[i + 4] = (struct uke_gain_register) {
			.component = snd_soc_rtd_to_codec(rtd, 2)->component,
			.reg = 0x040c + 0x80 * i, .mask = 0xff, .value = digital[i],
		};
	}
	/* Read everything before mutation, then restore prior fields on an I/O error. */
	for (i = 0; i < ARRAY_SIZE(registers); i++) {
		if (!registers[i].component->regmap)
			return -ENODEV;
		ret = regmap_read(registers[i].component->regmap,
				  registers[i].reg, &registers[i].previous);
		if (ret)
			return ret;
	}
	for (i = 0; i < ARRAY_SIZE(registers); i++) {
		ret = snd_soc_component_update_bits(registers[i].component,
			registers[i].reg, registers[i].mask, registers[i].value);
		if (ret < 0) {
			/* Include the failed transfer: a bus error can follow a write. */
			for (undo = i; undo >= 0; undo--)
				if (snd_soc_component_update_bits(registers[undo].component,
					registers[undo].reg, registers[undo].mask,
					registers[undo].previous) < 0)
					dev_err(rtd->dev, "Microphone gain rollback failed\n");
			return ret;
		}
	}
	return 0;
}

#endif
