/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef UKE_DP_ELD_H
#define UKE_DP_ELD_H

/* DPCM backend numbering can change after a failed probe; users open FE PCM0. */
static int uke_dp_eld_to_frontend(struct snd_card *card, unsigned int backend)
{
	struct snd_ctl_elem_id source = { .iface = SNDRV_CTL_ELEM_IFACE_PCM,
					.device = backend };
	struct snd_ctl_elem_id target;

	strscpy(source.name, "ELD", sizeof(source.name));
	if (!backend)
		return 0;
	target = source;
	target.device = 0;
	if (!snd_ctl_find_id(card, &source))
		return -ENOENT;
	if (snd_ctl_find_id(card, &target))
		return -EEXIST;
	return snd_ctl_rename_id(card, &source, &target);
}
#endif
