# Read-only WCD939x jack telemetry

4 November 2026. A running Uke kernel exposes HPHL/R Impedance and HPH Type
as writable integer controls with maximum -1. ALSA state restore records
three EPERM failures. Their cached getter callbacks have no put callback.
Linux's real control constructor defaults unspecified access to READWRITE;
the ordinary volume-info helper interprets UINT_MAX through a signed maximum.

The correction makes the three existing controls explicitly read-only. Names,
registration order, integer type, channel shifts and getter values remain.
The impedance maximum is INT_MAX, which includes WCD939x's floating sentinel
0x0FFFFFFE. Type uses its NONE/MONO/STEREO enum maximum. No gain, hardware
register, electrical limit, headset detection or calibration changes.

Source comparisons use the exact
[Uke audio tree](https://github.com/MiCode/vendor_qcom_opensource_audio-kernel/blob/8eb0eccbc4027ae4a4987e4bced03a4381039714/asoc/codecs/wcd939x/wcd939x-mbhc.c),
[OnePlus SM7675 audio tree](https://github.com/OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_sm7675/blob/1138e00fee63582a0cc6a53af3286621786827b7/vendor/qcom/opensource/audio-kernel/asoc/codecs/wcd939x/wcd939x-mbhc.c)
and pinned
[Linux WCD939x](https://github.com/gregkh/linux/blob/79a907609d53d5cd645b42c11550d295d43abf99/sound/soc/codecs/wcd939x.c).
The ranges follow the accepted
[WCD934x correction](https://github.com/gregkh/linux/commit/61163c3e7480106804269182e24db05244866493)
and equivalent WCD938x fix. The original Linux source remains GPL-2.0-only.
These shared-code references do not transfer another board's electrical data.

The remote fixture extracts the actual Linux control constructor, mixer-info
functions, getter callbacks and declarations. Independent old-source access
and range assertions must fail; corrected metadata and 441 cached getter
observations must pass normally and with sanitizers. Allocation and cached
MBHC providers are synthetic and no ALSA device is opened. This does not prove
physical jack detection, audio playback or the absence of errors after boot.
Native qualification completed in
[COPR build 11252415](https://copr.fedorainfracloud.org/coprs/build/11252415),
kernel release `7.3.1-2700`, compiled source
`c0de80bf9f7f5ac18b4fb5ceb623342f285382ee`. The two actual-old assertions
fail at the required checks; old getter values pass. Corrected controls and
441 cached observations pass with GCC and Clang, normally and under ASan/UBSan.
The complete kernel, actual codec object/module linkage and inherited package
checks pass. All six original signed runtime RPMs pass independent signature,
payload, dependency, ordered-script, config and provenance review.

DNF transaction 39 installs this cohort on 4 November 2026. The inactive A
slot is written, synced and read back; the accepted 1500 kernel remains in B.
The device still runs 1500 and has not rebooted into 2700. Matching-kernel ALSA
restore, jack behavior and physical recurrence checks remain pending. A later
documentation commit does not replace the immutable compiled source above.
