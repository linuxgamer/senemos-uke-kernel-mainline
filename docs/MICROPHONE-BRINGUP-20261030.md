# Uke internal microphone bring-up, 31 October 2026

## Current qualification boundary

31 October 2026. POCO Pad X1, Fedora Rawhide AArch64, kernel7.3.1-102: four
independent paths feed one named four-channel input. Pre-start ADC indices8
and TX24dB give operator-accepted normal speech; the complete770048-frame
recording has no full-scale samples. Later handling transients demonstrate
that this does not establish unlimited headroom or thirty clean cycles.

Signed COPR11237692 produces candidate105 with DT-bound gains before capture
power-up and audio data owned by kernel-core. All six signed RPMs, complete
Images,822 module hashes, gain properties and legacy-data compatibility pass
package admission. The operator installs105; the guarded updater writes and
verifies A while retaining accepted102/B. Candidate boot and microphone
acceptance remain pending. Fresh106 declares automatic singleboot delivery.
These pinned candidates do not qualify the complete combined main source.

## Historical mono bring-up record

POCO Pad X1 runs Fedora Rawhide AArch64 and Linux 7.3.1-10. Its native card
exposes two playback PCMs and one mono capture PCM. Two 10-second raw mono
recordings contain nonzero samples without clipping; the second opens as an
unprivileged user after closing the first. Subsequent recordings use reported
ambient fan noise. Spectrograms show persistent low-frequency noise; no audio
audition or controlled fan on/off comparison is claimed. The remaining three
physical inputs have not been verified.
The objective remains independent operation of all four physical microphones.

## Source candidate

The isolated `microphones` native profile retains the verified mono path:

`AMIC1 -> ADC1 -> WCD939x TX -> SoundWire -> TX DEC0 -> TX_CODEC_DMA_TX_3 -> MultiMedia3 Capture`.

Release 13 adds the following board routes for one-at-a-time qualification:

| Analog input | ADC | OEM bias | Native TX input |
| --- | --- | --- | --- |
| AMIC1 | ADC1 | MIC BIAS1 | SWR_INPUT0 |
| AMIC3 | ADC3 | MIC BIAS3 | SWR_INPUT2 |
| AMIC4 | ADC4 | MIC BIAS3 | SWR_INPUT3 |
| AMIC5 | ADC2 | MIC BIAS4 | SWR_INPUT1 |

The native codec exposes all four ADC outputs. The live OEM route property
confirms the bias associations; exact Android input selections are pinned in
[the input-source record](../manifests/research-microphone-inputs-20261031.json).
Select one ADC and its corresponding SWR input into DEC0. Do not transfer the
Android sparse decimators or assume its labels prove physical body positions.
This candidate keeps mono admission; multichannel capture is a later gate.

The existing four-channel speaker and stereo DisplayPort graphs, frontend
IDs 1/0 and card name remain. The capture frontend is ID 2; the backend DAI
is 120, with DSP LPAIF type 1 and interface index 4. The topology appends a
capture fragment to the existing playback source, with distinct module,
container and subgraph IDs. Its format is 48 kHz, S16_LE, one channel.
The machine rejects other decimator masks and multi-channel capture.

This isolated candidate selects `microphones`. The accepted distribution
profile remains `speakers`. The selection is not a hardware acceptance claim.
No UCM capture entry is added before raw capture works.

The 31 October device trial of 7.3.1-5 boots and binds both SoundWire slaves.
The checked codec reports WCD939x 2.0. Card registration then fails because
the OEM aggregate `WCD_TX_OUTPUT` is absent from the native codec. No stream
is opened; the retained release 4 image is restored and read back. Candidate
6 uses native `ADC1_OUTPUT`, and its prepared-source FDT check resolves the
endpoint against the actual codec widgets and rejects the old OEM name.
Release 6 registers the card. Release 9 also corrects the component minimum
from 2 to 1 only for Uke microphone-card capture graph 2; device probes confirm
open, hw_params, SoundWire enable and both DSP starts succeed.

Four status0 DSP read completions arrive at 130 ms intervals, but each carries
56 bytes while the native V2 structure incorrectly includes an offset field
and expects 60. Release 10 removes that field and the synthetic-offset check,
matching the official AudioReach API pinned in
[the protocol source record](../manifests/research-audioreach-20261031.json).
Full reply-size, status, token, address and data-size checks remain. COPR
accepts an independent 56-byte response with a nonzero timestamp and rejects
shorter or hostile replies. The release 10 device trial produces two complete
48 kHz S16_LE mono WAVs, each with 480,000 samples. DSP completions reach ALSA,
and DAPM reports AMIC1, ADC1, MIC BIAS1 and the TX path active during capture.
The stream closes, all nine changed controls match their original values,
and the original audio services restart. This establishes raw data flow and
reopen, not acoustic response, microphone position, all four inputs or measured
electrical levels. The user subsequently identifies ambient fan noise as the
test reference. Disabling the analog input stops sample delivery; restoring
AMIC1 permits another complete nonzero recording. Additional inputs are now
prepared for individual tests with that reported ambience; all-four operation
and controlled acoustic comparison remain open.

Both SoundWire slaves and the WCD compound codec are described. The exact
OEM L7B/BOB phandles are retained: 1.8 V and 3.296 V respectively, with
all four bias outputs configured for 2.75 V. These are DT constraints,
not measured voltages. Reset must use the existing USBSS-coordinated child;
the Uke codec now refuses the legacy GPIO fallback. The native-compatible
codec identity alone does not identify fitted silicon. The checked release9
probe reports WCD939X_2_0; electrical behavior remains unmeasured.

The upstream QRD example uses SoundWire DAI 0. With the selected QCOM
driver and one output port, DAI 0 has playback capabilities only; ASoC
skips its capture `hw_params`. This candidate selects the first capture
DAI, 1, and verifies that it actually supports capture at registration.
Android SWR microphone numbers are not copied into native TX mux controls.

Patch 0049 checks the existing codec I/O and interrupt-level writes without
changing values or sequencing. A failure releases runtime PM and class-H
state before watchdog/MBHC setup. Patch 0050 checks the SoundWire interface
clock before changing the wake IRQ or accessing controller registers.

## Reproduction and validation

Run `packaging/native/copr-microphones731.sh` only in a COPR source worker.
The producer verifies the pinned release4 SRPM, retains its signed Linux
7.3.1 source and all 122 adaptation patches, and overlays the listed microphone
files. Other native-profile files remain byte-identical, including the PM8010
population guard. Kernel 7.3.0-73 is historical build evidence and must not
replace the accepted 7.3.1 baseline. All compilation and schema validation
for this candidate runs on COPR. No local build is permitted.

Use a separately prepared Linux 7.3 tree with the locked core series and
native audio patches. Run:

```sh
make test-microphones kernel_source=/path/to/prepared/linux
bash tests/microphone-audio-fdt-contract.sh /path/to/prepared/linux /path/to/private/active.dtb
```

The optional second command changes only an in-memory copy of the supplied
DT. Never publish the complete active DT or device-private evidence.

| Check | Observed result | Scope |
|---|---|---|
| Combined DT, synthetic fixture and active-DT copy | PASS | Memory only; supply aliases/bounds, reset, pins, IRQs, slaves and three links |
| Compiled/decoded topology | PASS | Playback checks retained; FE2/BE120 and capture module chain |
| Machine admission and lifecycle callbacks | 61 cases PASS | Fake ASoC/SoundWire providers; includes 30 memory-only cycles |
| Codec I/O setup and caller unwind | 68 cases PASS | Fake writes, positive change returns and first-error propagation |
| SoundWire resume clock admission | 6 cases PASS | Admission prefix only; no actual clock-stop/resume |
| Twelve audio/controller translation units | PASS | AArch64 GCC 16 and Clang 23 with -Werror; no linked kernel/modules |
| Live codec enumeration, electrical levels and raw PCM | UNTESTED | No candidate installation or activation |
| UCM, four independent mics and power/playback regressions | UNTESTED | Requires physical capture |

## Activation and acceptance gates

1. Complete production native/SRPM preparation, module linkage and signature
   checks using a verified unused NVR. Preserve the running release-54
   source identity and matched rollback images/modules.
2. Resolve SoundWire wake ownership and runtime-PM/remove behavior. Review
   the OEM revision-2 USBSS trim condition before codec activation; do not
   copy private calibration or perform speculative trim writes.
3. With a coordinated test window and the required local privileges, boot
   the matched signed candidate through the retained recovery path. Stop
   on persistent supplier, clock, codec or DSP errors. Verify both slaves,
   codec identity and expected controls before writing any mixer control.
4. Enable only the admitted AMIC1/ADC1/DEC0 path after those checks. Resolve
   the actual ALSA card/PCM from runtime inventory; record ten seconds and
   verify nonzero, intelligible signal correlated with an acoustic stimulus.
   Reopen successfully before continuing.
5. Verify each other analog input independently, then qualify genuine
   two/four-channel mappings. Only then add capture UCM and test PipeWire,
   KDE, playback/capture, 30 real reopen cycles and power transitions.

Keep installed release 54 and its module tuple for rollback. Restore that
matched image through the existing documented updater/recovery route if the
candidate fails; do not alter Android slot A, partition layout, persist or
early firmware. No rollback boot is claimed from copying or hashing images.

## Provenance

- Running source parent: `fff6defba53f4146af8d5f82a8132921b746ef5e`.
- User-supplied `UKE_LINUX_MICROPHONE_PORTING_REPORT_2026-10-30.md`,
  SHA-256 `6b125f31a6cf8ec070051473fbb2f66ac98864688f8e6c94cc559e6e7f39e414`.
- MiCode audio `8eb0eccbc4027ae4a4987e4bced03a4381039714`,
  WCD939x/supply/SoundWire sources, and read-only active Uke DT properties.
- Shared-IP/upstream `4056b3c9d3c92ea45955641dbafeb9b960e146ef`,
  SM8650 DT, QCOM SoundWire/ASoC helpers and WCD939x.
- Linaro AudioReach topology `b4c1510fe6686ab8053715a02c34bec875ca5c6c`,
  BSD-3-Clause capture ABI/module templates; donor scripts were not executed.
- [Uke Android PAL correction](https://github.com/delano-git/android_device_xiaomi_uke/commit/d54e232e91dc0fb7222e52f4fa48ab6c0583ce11)
  and its linked OEM mixer overlay confirm the analog route direction.
  Android success does not establish Linux capture.
