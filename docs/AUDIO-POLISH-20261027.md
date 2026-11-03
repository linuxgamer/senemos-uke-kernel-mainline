# Audio test candidate, 27 October 2026

Environment: Linux 7.3.0-21 source, Fedora Rawhide AArch64 package target.
Host checks use fake amplifier registers/workqueues and regular-file ALSA
output. This integrated candidate has no physical playback, capture, suspend
or thermal acceptance. The earlier Xiaomi Pad 7 playback report applies to
the contributor's separate release-20 artifact.

## Driver corrections

Patch 0117 retains the OEM start sequence and the four-channel 48 kHz S16_LE
path inside four 32-bit TDM slots. It changes the following behavior:

- Stop and assert reset after a PLL read error/timeout, DAC write failure,
  thermal-control read/write failure or failed thermal-enable readback.
- Poll once per delayed-work invocation. Stop keeps the state lock while
  cancelling pending work, so an old stop cannot reset a newly started stream.
- Remember stream activity. Turning a speaker switch back on during an active
  stream starts that amplifier; idle switch changes do not power it up.
- Preserve cached volume after failed writes so an identical retry reaches
  hardware. Reject levels above 0xdf and remove `max_volume`/`force_unmute`.
- Keep DAC mute asserted during preset table writes and clamp preset volume
  writes as well, including read-modify-write operations.
- Stop on DAI shutdown, component suspend, I2C removal and system shutdown.
  Resume leaves the amplifier off until a new DAI unmute event.
- Refuse unstable register reads, timed-out/unknown preset operations,
  overflowing register fields and invalid preset position/coefficient data,
  including coefficients that cannot fit after the required register shift.
- Require the active-low reset GPIO. Refuse the unqualified FS1958 identity,
  whose OEM gain and sample-rate encodings differ from the tested 0x29 family.
- Reject invalid TDM slot/media configuration and propagate topology-loader
  errors through the top-level widget callback.

Remove old modprobe options named `force_unmute` or `max_volume` before using
this candidate. Neither option is accepted. The 0xdf ceiling does not qualify
speaker calibration or protection effectiveness.

## Desktop and firmware delivery

`uke-displayport-audio` 0.1.0-6 adds the `POCO-Pad-X1` UCM profile alongside the
existing `POCO-Pad-X1-HDMI` profile. It enables only the selected device's four
speaker switches. Its ALSA plug/route PCM converts desktop input to 48 kHz
S16_LE stereo and duplicates left/right to slots 0/1/2/3 as L/R/L/R.
The raw hardware PCM remains four-channel for separately coordinated mapping
checks. HDMI keeps frontend PCM 0, its existing mixer and `DP0 Jack`.

The kernel recommends this policy version. The separately provisioned OEM
`qcom/uke/audio/fs19xx.fsm` is still required. No preset, calibration, OEM
library or private device data is included. Missing/rejected preset data
leaves the amplifier unavailable. Installing firmware after initial probe
requires a separately coordinated driver reload or reboot.

## Microphone assessment

This candidate does not expose a microphone PCM. The legacy TDM source module
is the amplifier VI-feedback path, not a substitute for the WCD microphone
capture path. The native WCD939x and SoundWire drivers are already enabled in
the configuration; module selection alone cannot create capture.

Exact Uke evidence identifies WCD SoundWire IDs, LPASS GPIO12 reset, selected
TX pins, CODEC DMA interface 1/4 and route-specific AMIC/ADC assignments. The
retained Linux 7.3 source already contains the physical channel-map mask and
packing behavior previously researched as an upstream prerequisite. No
duplicate backport or fabricated capture topology is added.

The WCD939x PX supply remains an electrical compatibility gate: Uke OEM
metadata resolves it to a 1.8 V rail, while the native binding describes a
1.2 V PX supply and native probe enables its supply set together. A different
board's correction does not establish Uke wiring. The SoundWire/codec graph,
supplier sequencing and capture channel mapping must be qualified before
enabling microphone bias and offering capture to applications.

## Validation and physical test order

`make validate` exercises the actual patched amplifier lifecycle without
downloading a kernel. The RPM check phase additionally runs the preset,
lifecycle, TDM encoder and topology-error fixtures against prepared source.
Desktop policy checks parse the ALSA files and verify actual route-plugin
output samples against regular files; they do not open an audio device.

For physical testing, first verify the exact installed kernel/modules and
policy versions, preset provenance and retained rollback. Then coordinate
the four individual channels, desktop stereo, repeated start/stop and switch
changes, followed by HDMI, suspend/resume and bounded thermal observations.
Record each result separately. Microphone capture needs its independent
electrical and transport stage before a recording test.
