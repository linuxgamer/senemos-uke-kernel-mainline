// SPDX-License-Identifier: GPL-2.0-only
/* Uke playback, bounded microphone capture and closed registration profiles. */
#include <linux/module.h>
#include <linux/build_bug.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/regmap.h>
#include <linux/slab.h>
#include <linux/string.h>
#include <dt-bindings/sound/qcom,q6dsp-lpass-ports.h>
#include <sound/jack.h>
#include <sound/control.h>
#include <sound/pcm_params.h>
#include <sound/soc.h>
#include <generated/utsrelease.h>
#include "common.h"
#include "sdw.h"
#include "uke-microphone-gain.h"
#include "uke-dp-eld.h"

static int uke_hdmi_late_probe(struct snd_soc_card *card)
{
	struct snd_soc_pcm_runtime *rtd;
	unsigned int frontends = 0, backends = 0;

	for_each_card_rtds(card, rtd) {
		struct snd_soc_dai *cpu = snd_soc_rtd_to_cpu(rtd, 0);

		if (rtd->dai_link->no_pcm) {
			if (cpu->id != DISPLAY_PORT_RX_0)
				return -EINVAL;
			backends++;
		} else {
			if (!rtd->dai_link->dynamic || cpu->id != 0 ||
			    cpu->driver->capture.channels_min)
				return -EINVAL;
			frontends++;
		}
	}
	return frontends == 1 && backends == 1 ? 0 : -EINVAL;
}

static int uke_hdmi_init(struct snd_soc_pcm_runtime *rtd)
{
	return qcom_snd_dp_jack_setup(rtd, snd_soc_card_get_drvdata(rtd->card), 0);
}

static int uke_hdmi_fixup(struct snd_soc_pcm_runtime *rtd,
			  struct snd_pcm_hw_params *params)
{
	struct snd_interval *rate = hw_param_interval(params, SNDRV_PCM_HW_PARAM_RATE);
	struct snd_interval *channels = hw_param_interval(params, SNDRV_PCM_HW_PARAM_CHANNELS);
	struct snd_mask *format = hw_param_mask(params, SNDRV_PCM_HW_PARAM_FORMAT);

	rate->min = rate->max = 48000;
	channels->min = channels->max = 2;
	snd_mask_none(format);
	snd_mask_set_format(format, SNDRV_PCM_FORMAT_S16_LE);
	return 0;
}

static int uke_hdmi_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct snd_soc_dai_link *link;
	struct snd_soc_card *card;
	struct snd_soc_jack *jack;
	struct device_node *frontend;
	int ret;

	card = devm_kzalloc(dev, sizeof(*card), GFP_KERNEL);
	jack = devm_kzalloc(dev, sizeof(*jack), GFP_KERNEL);
	if (!card || !jack)
		return -ENOMEM;
	card->dev = dev;
	card->owner = THIS_MODULE;
	card->driver_name = "sm7675";
	card->late_probe = uke_hdmi_late_probe;
	snd_soc_card_set_drvdata(card, jack);
	ret = qcom_snd_parse_of(card);
	if (ret)
		return ret;
	if (card->num_links != 1 || card->num_aux_devs ||
	    strcmp(card->name, "POCO-Pad-X1-HDMI"))
		return -EINVAL;
	link = card->dai_link;
	if (!link->no_pcm || link->id != DISPLAY_PORT_RX_0 ||
	    link->num_cpus != 1 || link->num_codecs != 1 || link->num_platforms != 1 ||
	    !of_device_is_compatible(link->cpus[0].of_node, "qcom,q6apm-lpass-dais") ||
	    !of_device_is_compatible(link->platforms[0].of_node, "qcom,q6apm") ||
	    !of_device_is_compatible(link->codecs[0].of_node, "qcom,sm7675-dp") ||
	    link->cpus[0].of_node->parent != link->platforms[0].of_node)
		return -EINVAL;
	frontend = of_get_compatible_child(link->platforms[0].of_node, "qcom,q6apm-dais");
	ret = frontend && of_device_is_available(frontend) &&
		of_property_read_bool(frontend, "xiaomi,hdmi-only") &&
		!of_property_read_bool(frontend, "xiaomi,registration-only") ? 0 : -EINVAL;
	of_node_put(frontend);
	if (ret)
		return ret;
	link->init = uke_hdmi_init;
	link->be_hw_params_fixup = uke_hdmi_fixup;
	return devm_snd_soc_register_card(dev, card);
}

#define UKE_SPEAKER_AMPS	4
#define UKE_SPEAKER_SLOTS	4
#define UKE_SPEAKER_SLOT_WIDTH	32

struct uke_speaker_data {
	struct snd_soc_jack jack;
	bool microphones;
	bool capture_prepared;
	u32 microphone_analog_gain[4];
	u32 microphone_digital_gain[4];
};

static int uke_speaker_hdmi_init(struct snd_soc_pcm_runtime *rtd)
{
	struct uke_speaker_data *data = snd_soc_card_get_drvdata(rtd->card);

	return qcom_snd_dp_jack_setup(rtd, &data->jack, 0);
}

static int uke_speaker_late_probe(struct snd_soc_card *card)
{
	struct uke_speaker_data *data = snd_soc_card_get_drvdata(card);
	struct snd_soc_pcm_runtime *rtd;
	unsigned int frontends = 0, backends = 0, seen = 0, fe_seen = 0;

	for_each_card_rtds(card, rtd) {
		struct snd_soc_dai *cpu = snd_soc_rtd_to_cpu(rtd, 0);

		if (rtd->dai_link->no_pcm) {
			if (cpu->id == DISPLAY_PORT_RX_0)
				seen |= BIT(0);
			else if (cpu->id == SECONDARY_TDM_RX_0)
				seen |= BIT(1);
			else if (data->microphones && cpu->id == TX_CODEC_DMA_TX_3) {
				if (!snd_soc_rtd_to_codec(rtd, 1)->driver->capture.channels_min)
					return -EINVAL;
				seen |= BIT(2);
			} else {
				return -EINVAL;
			}
			backends++;
		} else {
			if (!rtd->dai_link->dynamic || cpu->id < 0 ||
			    cpu->id > (data->microphones ? 2 : 1) ||
			    (fe_seen & BIT(cpu->id)))
				return -EINVAL;
			if (cpu->id == 2) {
				if (cpu->driver->playback.channels_min ||
				    cpu->driver->capture.channels_min != 1 ||
				    cpu->driver->capture.channels_max != 4)
					return -EINVAL;
			} else if (cpu->driver->capture.channels_min) {
				return -EINVAL;
			}
			fe_seen |= BIT(cpu->id);
			frontends++;
		}
	}
	if (data->microphones)
		return frontends == 3 && backends == 3 && seen == 7 &&
		       fe_seen == 7 ? 0 : -EINVAL;
	return frontends == 2 && backends == 2 && seen == 3 &&
	       fe_seen == 3 ? 0 : -EINVAL;
}

static int uke_microphone_late_probe(struct snd_soc_card *card)
{
	struct snd_soc_pcm_runtime *rtd;
	int ret = uke_speaker_late_probe(card);

	if (ret)
		return ret;
	for_each_card_rtds(card, rtd) {
		if (!rtd->dai_link->no_pcm ||
		    snd_soc_rtd_to_cpu(rtd, 0)->id != DISPLAY_PORT_RX_0)
			continue;
		if (!rtd->pcm)
			break;
		ret = uke_dp_eld_to_frontend(card->snd_card, rtd->pcm->device);
		if (ret)
			dev_warn(card->dev, "DP ELD frontend mapping unavailable: %d\n", ret);
		break;
	}
	return 0;
}

static void uke_capture_clear_stream(struct snd_pcm_substream *substream)
{
	struct snd_soc_pcm_runtime *rtd = snd_soc_substream_to_rtd(substream);
	struct snd_soc_dai *codec;
	int i;

	for_each_rtd_codec_dais(rtd, i, codec)
		snd_soc_dai_set_stream(codec, NULL, substream->stream);
}

static int uke_capture_startup(struct snd_pcm_substream *substream)
{
	struct snd_soc_pcm_runtime *rtd = snd_soc_substream_to_rtd(substream);
	struct uke_speaker_data *data = snd_soc_card_get_drvdata(rtd->card);
	int ret;

	if (substream->stream != SNDRV_PCM_STREAM_CAPTURE)
		return -EINVAL;
	/* Apply the board defaults before power-up, including after ALSA state restore. */
	ret = uke_microphone_apply_gain(rtd, data->microphone_analog_gain,
					data->microphone_digital_gain);
	if (ret)
		return ret;
	ret = qcom_snd_sdw_startup(substream);
	/* The shared helper releases its allocation on a partial startup error. */
	if (ret)
		uke_capture_clear_stream(substream);
	return ret;
}

static int uke_capture_fixup(struct snd_soc_pcm_runtime *rtd,
			     struct snd_pcm_hw_params *params)
{
	struct snd_interval *rate = hw_param_interval(params, SNDRV_PCM_HW_PARAM_RATE);
	struct snd_interval *channels = hw_param_interval(params, SNDRV_PCM_HW_PARAM_CHANNELS);
	struct snd_mask *format = hw_param_mask(params, SNDRV_PCM_HW_PARAM_FORMAT);

	/* Preserve the selected FE channel count for the matching DMA format. */
	if (channels->min != channels->max ||
	    (channels->min != 1 && channels->min != 2 && channels->min != 4))
		return -EINVAL;
	rate->min = rate->max = 48000;
	snd_mask_none(format);
	snd_mask_set_format(format, SNDRV_PCM_FORMAT_S16_LE);
	return 0;
}

static int uke_capture_hw_params(struct snd_pcm_substream *substream,
				 struct snd_pcm_hw_params *params)
{
	struct snd_soc_pcm_runtime *rtd = snd_soc_substream_to_rtd(substream);
	unsigned int tx_num = 0, tx_mask = 0, rx_num = 0, rx_mask = 0;
	unsigned int channels = params_channels(params);
	int ret;

	if (params_rate(params) != 48000 ||
	    (channels != 1 && channels != 2 && channels != 4) ||
	    params_format(params) != SNDRV_PCM_FORMAT_S16_LE)
		return -EINVAL;

	/*
	 * The TX macro returns a decimator bitmask, not a channel-slot array.
	 * AudioReach's default 1/2/4-channel mapping occupies consecutive DMA
	 * positions. Require the same DEC0..N-1 mask and exact channel count;
	 * Android's sparse decimators are not compatible with this mapping.
	 */
	ret = snd_soc_dai_get_channel_map(snd_soc_rtd_to_codec(rtd, 2),
					  &tx_num, &tx_mask, &rx_num, &rx_mask);
	if (ret)
		return ret;
	if (tx_num != channels || tx_mask != BIT(channels) - 1 || rx_num)
		return dev_err_probe(rtd->dev, -EINVAL,
				     "Capture requires matching contiguous TX_AIF1 decimators\n");
	return 0;
}

static int uke_capture_prepare(struct snd_pcm_substream *substream)
{
	struct snd_soc_pcm_runtime *rtd = snd_soc_substream_to_rtd(substream);
	struct uke_speaker_data *data = snd_soc_card_get_drvdata(rtd->card);
	struct sdw_stream_runtime *stream = qcom_snd_sdw_get_stream(substream);

	if (IS_ERR_OR_NULL(stream))
		return stream ? PTR_ERR(stream) : -ENODEV;
	return qcom_snd_sdw_prepare(substream, &data->capture_prepared);
}

static int uke_capture_hw_free(struct snd_pcm_substream *substream)
{
	struct snd_soc_pcm_runtime *rtd = snd_soc_substream_to_rtd(substream);
	struct uke_speaker_data *data = snd_soc_card_get_drvdata(rtd->card);

	return qcom_snd_sdw_hw_free(substream, &data->capture_prepared);
}

static void uke_capture_shutdown(struct snd_pcm_substream *substream)
{
	uke_capture_hw_free(substream);
	qcom_snd_sdw_shutdown(substream);
	uke_capture_clear_stream(substream);
}

static const struct snd_soc_ops uke_capture_ops = {
	.startup = uke_capture_startup,
	.hw_params = uke_capture_hw_params,
	.prepare = uke_capture_prepare,
	.hw_free = uke_capture_hw_free,
	.shutdown = uke_capture_shutdown,
};

/*
 * Four 32-bit TDM slots at 48 kHz, one slot per amplifier. Samples stay 16-bit:
 * the DSP cannot widen them in this graph and never consumes the stream if the
 * back end is wider than the frontend (hardware result, 26 October 2026).
 */
static int uke_speaker_fixup(struct snd_soc_pcm_runtime *rtd,
			     struct snd_pcm_hw_params *params)
{
	struct snd_interval *rate = hw_param_interval(params, SNDRV_PCM_HW_PARAM_RATE);
	struct snd_interval *channels = hw_param_interval(params, SNDRV_PCM_HW_PARAM_CHANNELS);
	struct snd_mask *format = hw_param_mask(params, SNDRV_PCM_HW_PARAM_FORMAT);

	rate->min = rate->max = 48000;
	channels->min = channels->max = UKE_SPEAKER_SLOTS;
	snd_mask_none(format);
	snd_mask_set_format(format, SNDRV_PCM_FORMAT_S16_LE);
	return 0;
}

static int uke_speaker_init(struct snd_soc_pcm_runtime *rtd)
{
	return snd_soc_dai_set_tdm_slot(snd_soc_rtd_to_cpu(rtd, 0), 0,
					GENMASK(UKE_SPEAKER_SLOTS - 1, 0),
					UKE_SPEAKER_SLOTS, UKE_SPEAKER_SLOT_WIDTH);
}

static bool uke_backend_owned(struct snd_soc_dai_link *link)
{
	return link->no_pcm && link->num_cpus == 1 && link->num_platforms == 1 &&
	       of_device_is_compatible(link->cpus[0].of_node, "qcom,q6apm-lpass-dais") &&
	       of_device_is_compatible(link->platforms[0].of_node, "qcom,q6apm") &&
	       link->cpus[0].of_node->parent == link->platforms[0].of_node;
}

static int uke_speaker_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct snd_soc_dai_link *hdmi = NULL, *speaker = NULL, *capture = NULL, *link;
	struct snd_soc_card *card;
	struct uke_speaker_data *data;
	struct device_node *frontend;
	unsigned int i;
	int ret;

	card = devm_kzalloc(dev, sizeof(*card), GFP_KERNEL);
	data = devm_kzalloc(dev, sizeof(*data), GFP_KERNEL);
	if (!card || !data)
		return -ENOMEM;
	data->microphones = of_device_is_compatible(dev->of_node,
						    "xiaomi,uke-microphone-audio-card");
	card->dev = dev;
	card->owner = THIS_MODULE;
	card->driver_name = "sm7675";
	card->late_probe = uke_speaker_late_probe;
	snd_soc_card_set_drvdata(card, data);
	ret = qcom_snd_parse_of(card);
	if (ret)
		return ret;
	if (card->num_links != (data->microphones ? 3 : 2) || card->num_aux_devs ||
	    strcmp(card->name, "POCO-Pad-X1"))
		return -EINVAL;
	/* UCM discovers the bounded capture capability from this card instance. */
	if (data->microphones)
		card->components = "mic:uke-4ch-v3";

	for_each_card_prelinks(card, i, link) {
		if (link->id == DISPLAY_PORT_RX_0 && !hdmi)
			hdmi = link;
		else if (link->id == SECONDARY_TDM_RX_0 && !speaker)
			speaker = link;
		else if (data->microphones && link->id == TX_CODEC_DMA_TX_3 && !capture)
			capture = link;
		else
			return -EINVAL;
	}
	if (!hdmi || !speaker || !uke_backend_owned(hdmi) || !uke_backend_owned(speaker) ||
	    hdmi->num_codecs != 1 || speaker->num_codecs != UKE_SPEAKER_AMPS ||
	    !of_device_is_compatible(hdmi->codecs[0].of_node, "qcom,sm7675-dp") ||
	    speaker->cpus[0].of_node != hdmi->cpus[0].of_node)
		return -EINVAL;
	for (i = 0; i < UKE_SPEAKER_AMPS; i++)
		if (!of_device_is_compatible(speaker->codecs[i].of_node, "foursemi,fs19xx"))
			return -EINVAL;

	if (data->microphones) {
		if (!capture || !uke_backend_owned(capture) || capture->num_codecs != 3 ||
		    capture->cpus[0].of_node != hdmi->cpus[0].of_node ||
		    !of_device_is_compatible(capture->codecs[0].of_node, "qcom,wcd9390-codec") ||
		    !of_device_is_compatible(capture->codecs[1].of_node, "qcom,soundwire-v2.0.0") ||
		    !of_device_is_compatible(capture->codecs[2].of_node,
					     "qcom,sm8550-lpass-tx-macro") ||
		    !capture->codecs[0].dai_name || !capture->codecs[1].dai_name ||
		    !capture->codecs[2].dai_name ||
		    strcmp(capture->codecs[0].dai_name, "wcd939x-sdw-tx") ||
		    strcmp(capture->codecs[1].dai_name, "SDW Pin1") ||
		    strcmp(capture->codecs[2].dai_name, "tx_macro_tx1"))
			return -EINVAL;
		if (of_property_count_u32_elems(dev->of_node,
			"xiaomi,microphone-analog-gain") != 4 ||
		    of_property_count_u32_elems(dev->of_node,
			"xiaomi,microphone-digital-gain-db") != 4 ||
		    of_property_read_u32_array(dev->of_node,
			"xiaomi,microphone-analog-gain", data->microphone_analog_gain, 4) ||
		    of_property_read_u32_array(dev->of_node,
			"xiaomi,microphone-digital-gain-db", data->microphone_digital_gain, 4) ||
		    !uke_microphone_gain_valid(data->microphone_analog_gain,
					 data->microphone_digital_gain))
			return dev_err_probe(dev, -EINVAL, "Invalid board microphone gains\n");
		/* Per-release discovery lets parallel kernels retain their own UCM data. */
		BUILD_BUG_ON(sizeof("uke" UTS_RELEASE) > 16);
		card->driver_name = "uke" UTS_RELEASE;
		card->late_probe = uke_microphone_late_probe;
		card->components = "mic:uke-4ch-v4 kernel:" UTS_RELEASE;
		{
			const char *model;

			if (!of_property_read_string(of_root, "model", &model) &&
			    (!strcmp(model, "POCO Pad X1") || !strcmp(model, "Xiaomi Pad 7")))
				card->long_name = model;
		}
		capture->be_hw_params_fixup = uke_capture_fixup;
		capture->ops = &uke_capture_ops;
	}

	frontend = of_get_compatible_child(hdmi->platforms[0].of_node, "qcom,q6apm-dais");
	ret = frontend && of_device_is_available(frontend) &&
		of_property_read_bool(frontend, "xiaomi,hdmi-only") &&
		!of_property_read_bool(frontend, "xiaomi,registration-only") ? 0 : -EINVAL;
	of_node_put(frontend);
	if (ret)
		return ret;

	hdmi->init = uke_speaker_hdmi_init;
	hdmi->be_hw_params_fixup = uke_hdmi_fixup;
	speaker->init = uke_speaker_init;
	speaker->be_hw_params_fixup = uke_speaker_fixup;
	return devm_snd_soc_register_card(dev, card);
}

static int uke_audio_late_probe(struct snd_soc_card *card)
{
	struct snd_soc_pcm_runtime *rtd;
	int count = 0;

	for_each_card_rtds(card, rtd) {
		if (rtd->dai_link->no_pcm || !rtd->dai_link->dynamic)
			return -EINVAL;
		count++;
	}

	return count == 2 ? 0 : -EINVAL;
}

static int uke_audio_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct snd_soc_card *card;
	struct device_node *dais, *apm;
	int ret;

	if (!of_machine_is_compatible("xiaomi,uke"))
		return -ENODEV;
	if (of_device_is_compatible(dev->of_node, "xiaomi,uke-hdmi-audio-card"))
		return uke_hdmi_probe(pdev);
	if (of_device_is_compatible(dev->of_node, "xiaomi,uke-speaker-audio-card") ||
	    of_device_is_compatible(dev->of_node, "xiaomi,uke-microphone-audio-card"))
		return uke_speaker_probe(pdev);

	card = devm_kzalloc(dev, sizeof(*card), GFP_KERNEL);
	if (!card)
		return -ENOMEM;
	card->dev = dev;
	card->owner = THIS_MODULE;
	card->driver_name = "sm7675";
	card->long_name = "POCO Pad X1 AudioReach (streams disabled)";
	card->late_probe = uke_audio_late_probe;
	ret = snd_soc_of_parse_card_name(card, "model");
	if (ret || !card->name)
		return ret ?: -EINVAL;
	ret = snd_soc_of_parse_aux_devs(card, "aux-devs");
	if (ret)
		return ret;
	if (card->num_aux_devs != 2)
		return -EINVAL;

	/* Require both components before ASoC initializes the frontend runtimes. */
	dais = card->aux_dev[0].dlc.of_node;
	apm = card->aux_dev[1].dlc.of_node;
	if (!of_device_is_compatible(dais, "qcom,q6apm-dais") ||
	    !of_device_is_compatible(apm, "qcom,q6apm") ||
	    !of_property_read_bool(dais, "xiaomi,registration-only") ||
	    dais->parent != apm)
		return -EINVAL;

	return devm_snd_soc_register_card(dev, card);
}

static const struct of_device_id uke_audio_match[] = {
	{ .compatible = "xiaomi,uke-audio-card" },
	{ .compatible = "xiaomi,uke-hdmi-audio-card" },
	{ .compatible = "xiaomi,uke-speaker-audio-card" },
	{ .compatible = "xiaomi,uke-microphone-audio-card" },
	{}
};
MODULE_DEVICE_TABLE(of, uke_audio_match);

static struct platform_driver uke_audio_driver = {
	.probe = uke_audio_probe,
	.driver = {
		.name = "uke-audioreach-card",
		.of_match_table = uke_audio_match,
	},
};
module_platform_driver(uke_audio_driver);
MODULE_DESCRIPTION("Uke AudioReach DisplayPort, speaker and closed registration cards");
MODULE_LICENSE("GPL");
