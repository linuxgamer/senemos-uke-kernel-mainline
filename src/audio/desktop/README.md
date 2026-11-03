# Kernel audio policy

31 October 2026. Source preparation for the Uke four-channel microphone array;
kernel build and installed hardware acceptance are pending.

The legacy ALSA/WirePlumber data is an unchanged copy of hardware-support
commit4da244ff6fad52977980b2cb9fa9f0cdd7110882, policy0.1.0-13, under its MIT
license. Kernel ownership preserves rollback and permits removing the separate
audio package. The legacy files are frozen compatibility data; future changes
belong to the versioned array directory rather than these shared paths.

The running microphone-card driver advertises uke followed by its exact kernel
release. Standard ASoC normalization replaces dots with underscores in the
exported driver name, and the installer uses that same normalization. ALSA
selects the corresponding directory without a startup service,
environment override or mutation of another kernel's files. Array data supplies
one48kHz four-channel input, native routing and model-specific descriptions.
It does not write gain values: the machine driver applies the DT-constrained
codec/decimator defaults before capture power-up. Per-release WirePlumber
rules match the exact card components, avoiding cross-version overrides.

The ADC control indices are not independently calibrated dB. Native ADC_NORMAL
mode, supply values, bias voltage, pin/IRQ assignments and playback graphs are
unchanged. The proposed ADC8/TX24 defaults require physical acceptance on the
final kernel. A preliminary pre-start trial records four channels without
clipping; live analog gain changes caused distortion and are not the model
used by the startup driver. No blanket SNR or clipping-free claim is made.
