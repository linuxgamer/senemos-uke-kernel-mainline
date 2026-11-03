# Uke AudioReach source status, 22 October 2026

Environment: POCO Pad X1, Fedora Rawhide AArch64, Linux 7.2.12-9 baseline
and 7.2.12-10 service trial on 22 October. No ALSA cards or PCMs are present.
Internal speakers play on the Xiaomi Pad 7 with the `speakers` profile (see the
[internal speaker report](INTERNAL-SPEAKERS-20261026.md)). Microphone support
remains unavailable.

Patch 0079, ported from project commit `693dfd4`, fixes four reviewed startup/input problems: a request sent before
APR installed the receive callback; stale readiness after request failure;
global provider publication before successful probe; and unchecked response
header/payload lengths. Readiness tokens and state are synchronized so an old
response cannot satisfy a later query. The accessor is serialized with removal.
This does not resolve every graph/DMA/PDR callback lifetime.

The 7.2.12-10 candidate selects `services-only` in
`packaging/native/audio-profile`. This adds
native APM and PRM service ports 1/2; OEM clients 3/7 remain separate. Both DAI
children remain disabled. The required DAI IOMMU descriptions use the exact
OEM context banks and do not enable DMA. No sound card or physical audio path
is created by this profile. Keep the amplifier I2C bus and SLIM disabled.

Patch 0099 carries the reviewed publication fix from project commit
`e4b196c060de5261c6469ac913622e6b99fc0496`. It initializes device references
before naming, unwinds failed naming/DT/IDR allocation, and removes the router
entry under its callback/IDR locks if `device_add` fails. The prior source
leaves a pointer to a released service after failed registration. The fault
fixture covers both APR and GPR, optional/malformed protection-domain data,
allocation/name/IDR failures and an occupied service ID. Full transport/PDR
and remote DMA teardown remain separate work.

Protocol evidence: MiCode audio
`8eb0eccbc4027ae4a4987e4bced03a4381039714`, `dsp/spf-core.c`,
`dsp/audio_prm.c` and `include/dsp/audio_prm.h`. The same module IDs appear in
Peridot `2ed9eadbecae21ef51134e556951e7305ba65f88` `palawan.dtsi`.
No Peridot amplifier settings, channel map, GPIOs or calibration were copied.
Linux changes retain their existing GPL notices.

Host fixtures extract the actual changed functions. They cover truncated and
optional GPR headers, PRM payload bounds, readiness timeouts and stale tokens,
failed/duplicate probe, provider removal, and disabled physical paths in the
generated FDT. AArch64 translation-unit compilation is separate from device
operation. New tests run in the RPM check phase; compiler-rt is host-only.

`src/audio/fs19xx-preset-audit.cpp` is a host-only C++ file-format inspector.
It validates the outer preset size/checksum, device indexes, selected address
set, known family types, nested index bounds and speaker-info position masks.
It never outputs register/tuning data, loads a kernel component or writes
calibration. A structural pass is not electrical compatibility or permission to
unmute. Other nested payload semantics and protection remain unqualified.

The stock Global OS3.0.304.0 `libfsalgocal.so` identifies the consumer of
`fsalgo_rdc.bin`. Static AArch64 inspection of `fsm_algo_set_re25` reads four
32-bit Q12 resistance values into four zero-initialized 24-byte records and
sends 96 bytes using parameter 0x10001fa7. This differs from the versioned
packed `fsadsp_cmd_re25` in MiCode `fsm_q6afe.h`. Neither the stock missing-file
fallback nor the old packed layout is admitted for a native speaker path.
The file has no embedded channel identities or integrity header; byte count
alone cannot qualify calibration or establish amplifier order. The library
was inspected as data and was not executed or added to a target payload.

The exact stock ODM overlay includes four distinct single-microphone routes:
top AMIC3/ADC3, sidetop AMIC5/ADC2, sidebottom AMIC1/ADC1 and back AMIC4/ADC4.
Other multi-mic paths use different ADC assignments. These are route-specific
source observations, not a tested four-channel capture map.

COPR 11186253 built source `b97c0e12d6e7dbe12ccca990611d0ee2a22ceb68`.
All six signed packages passed payload checks and were installed through DNF.
After an authorized same-slot update and one normal reboot, the tablet runs
7.2.12-10 with native services 1/2 bound to `qcom-apm`/`qcom-prm` and the
`q6prm-lpass-clock` child bound. PRM probe requires a successful APM SPF state-1
response before creating that child. The first readiness query timed out at
boot monotonic 11.232342 seconds; eventual binding does not resolve that startup
failure. No repeat appears in the three-minute observation. Both DAIs and
physical buses remain disabled; no playback, capture or calibration was run.

Remaining work: first-readiness timeout and repeated-boot qualification;
WCD939x/LPASS supplier and wakeup conversion; capture graph and physical mic
mapping; native amplifier component/protection; calibration validation and
channel binding; UCM and physical acceptance. Service registration creates no
sound card and must not be advertised as working internal audio.

## Card registration candidate

The 7.2.12-14 `registration-only` profile adds an exact Uke ASoC card and two
AudioReach frontend PCMs. APM and its PCM component must both bind before card
registration. The native topology contains interface metadata only, with no
DSP graph, mixer or hardware endpoint. It is installed under a kernel-versioned
firmware directory so rollback kernels retain their own matching data.

PCM and compressed opens return `-EACCES` in the actual q6apm component entry
before allocation, DSP graph commands or DMA. A machine startup guard alone
would run too late in the ASoC open sequence. PCM creation and removal also
skip buffer allocation and DSP mapping/unmapping for this profile. Source
review found those earlier lifecycle paths in the release-12 candidate;
release 12 is not admitted for tablet installation. Both the backend DAI and physical
amplifier/SLIM paths remain disabled. This stage can establish native card
visibility; it cannot establish sound output or microphone capture.

On 22 October 2026, COPR 11187708 release 13 booted on the tablet. A manual
machine-module load registered both disabled frontends without opening a PCM.
Cold autoload failed because the original Fedora ALSA rule also loads
`snd-seq`, which that kernel omitted. The enabled frontend node also caused
IOMMU-probe warnings outside the admitted Uke boot SMMU scope. Release 14 adds
the required sequencer module and omits frontend IOMMU attachment while DMA
is prohibited. It preserves the SMMU guard and original Fedora configuration.
Cold autoload, absence of new warnings and physical audio remain to be tested.

The host-only `acdb-graph-audit` inspects stock ACDB graph/module identities and
allowlisted hardware-interface metadata. AudioReach graphservices
`76d04ffb30caa1fe609b94f9f6081210cb962fc1` provides BSD-3-Clause format evidence;
its code is not executed or shipped. Exact stock speaker and VI graphs contain
legacy TDM sink/source modules and Foursemi RX/TX modules. The newer upstream
Audio IF implementation uses different modules and is not a drop-in solution.
No tuning payload or unit calibration is exported or installed by the tool.

## Internal speakers

The 26 October 2026 [internal speaker report](INTERNAL-SPEAKERS-20261026.md)
adds the FS19xx amplifier driver, the AudioReach TDM sink, a combined HDMI and
speaker card and the `speakers` audio profile. Tested on the Xiaomi Pad 7 on
26 October 2026: all four speakers produce sound; calibration, wider sample
widths, HDMI re-test and suspend are not covered.
