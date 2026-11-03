# LPASS TX multichannel lifecycle

31 October 2026. POCO Pad X1, Fedora Rawhide AArch64, Linux 7.3.1-16.
A two-channel raw capture returns different data on both channels, but disabling
DEC1 then DEC0 leaves DEC0 selected. ADCs, microphone biases and SoundWire
inputs are off after capture. Four-channel and desktop acceptance remain open.

Linux 7.3.1 (`79a907609d53d5cd645b42c11550d295d43abf99`),
`sound/soc/codecs/lpass-tx-macro.c`, tracks a single last active decimator in
addition to a per-AIF bitmask. Clearing one selector resets that scalar, so the
next disable returns early. Re-enabling an earlier selection can also increment
the count twice. The stream mute callback only handles the last decimator.
Current upstream `36aad21d50d1af3f6954bb0c988257a908202477` retains this behavior.

MiCode audio `8eb0eccbc4027ae4a4987e4bced03a4381039714`,
`asoc/codecs/lpass-cdc/lpass-cdc-tx-macro.c`, checks the individual selection
bit in `lpass_cdc_tx_macro_tx_mixer_put`. Patch 0055 follows that state model
using the native upstream bitmask. It removes the scalar and applies the native
mute operations to every selected decimator. Register addresses, electrical
configuration, DAPM updates and stream lifecycle remain native.

The COPR-only fixture extracts the actual prepared mixer get/put and mute
functions. It checks all 256 selections on all three AIFs, both transition
orders, duplicate writes, channel counts and selected register operations.
The unpatched source must fail separate mixer and mute negative controls.
These fake-I/O checks do not establish hardware capture or power behavior.

The corrected card advertises `mic:uke-4ch-v2`. Desktop array configuration
must require that exact marker, excluding release 16's earlier capability.
Physical acceptance requires 1/2/4-channel capture, repeated close/reopen,
per-channel independence, exact control cleanup and four selectable KDE inputs.
