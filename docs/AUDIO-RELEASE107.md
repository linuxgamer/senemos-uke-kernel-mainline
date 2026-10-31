# Audio recovery and device names

31 October 2026. POCO Pad X1, Fedora Rawhide AArch64, Linux 7.3.1-106.
Release106 boots but initially has no ALSA card. AudioReach derives its
topology lookup from the versioned ASoC driver name; kernel-core installed
the verified topology only under the original `sm7675` directory. Adding
the matching release-scoped alias and retrying card registration restores
the two playback PCMs and one four-channel capture PCM. The operator subsequently
confirms ordinary speaker and microphone operation after this recovery. This
does not qualify a fresh candidate boot.

Candidate107 installs the topology alias with kernel-core and checks its
target against the generated topology. It preserves the topology bytes,
ADC8/TX24 startup defaults, supplies, microphone bias, amplifier protection,
four speaker channels and two DisplayPort channels. UCM and desktop policy
remain in the kernel package; no separate microphone/audio RPM is required.

The HDMI codec associates ELD with the DPCM backend's allocated PCM number.
That number is not the public playback PCM0 and must not be hard-coded in
desktop data. The Uke microphone card maps the existing read-only ELD
control to PCM0 after runtime creation. Missing or conflicting ELD mapping
retains ordinary card registration and a generic DisplayPort description.
No playback data, monitor firmware or audio gain changes in this mapping.

Versioned desktop rules name the internal output `POCO PAD X1 Speaker` or
`Xiaomi Pad 7 Speaker` from the card model. Candidate108 adds matching
`POCO PAD X1 Microphone` and `Xiaomi Pad 7 Microphone` names for the single
four-channel microphone. These labels are verified in the recovered release106
session. The separate legacy audio package is removed; kernel-core owns the
retained UCM and desktop data. DisplayPort uses the monitor identity supplied by
ELD through the distribution's existing audio stack; it is not renamed as
an internal speaker. A disconnected or unreadable monitor keeps a generic
DisplayPort label.

The relevant upstream contracts are `audioreach_tplg_init` in
`sound/soc/qcom/qdsp6/topology.c`, `hdmi_codec_pcm_new` in
`sound/soc/codecs/hdmi-codec.c` and `snd_ctl_rename_id` in
`sound/core/control.c`. Reviewed upstream source is
`e9954f3fbddd25e1a01b7e5a0b72fb8b564204e0`; the candidate retains the qualified
Linux7.3.1 source pin. The helper checks missing source, duplicate target,
rename failure and backend-number changes. All compilation and execution
of these fixtures is restricted to COPR.

Candidate109 also updates the existing Uke-only HDMI-codec notifier. The machine
driver's ELD mapping preserves the control numid but changes its PCM device ID.
The notifier resolves that stable numid under the control read lock and emits
the current registered ID. Its checks cover FE0 and backend18, absent controls,
balanced locks and unchanged data. Candidates107 and108 are cancelled before
binary publication so they do not become the automatic-update delivery.

Remaining acceptance: signed candidate artifacts, fresh boot without the
temporary release106 recovery alias, input/output operation, monitor name
and hotplug, mute, reopen and suspend/resume. Build and package checks must
not be reported as physical audio acceptance.
