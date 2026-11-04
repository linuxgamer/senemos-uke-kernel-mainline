# O82 OEM P3 mapping for original KDE

5 November 2026 preparation source: utility0.7.0 adds
`uke-o82-color-profile --prepare-kernel RELEASE` for the DNF integration path.
It admits an installed non-running `7.3.1-N-unstable` kernel carrying the
memory/v5 source contract, checks the exact Uke/SM7675 board and fitted O82
supplier, and reads only that supplier's hash-admitted JSON from stock ODM.
The original LP reader verifies mirrored metadata and uses a bounded read-only
autoclear loop. No raw JSON is saved or shipped. Private firmware is published
with0600 permissions under `/usr/lib/firmware/RELEASE/qcom/sm7675/uke/`, using
an anonymous staging inode, readback and atomic no-replace linking. Existing
different, symlinked, hard-linked or public files are refused. Initial color
selection remains empty. COPR qualification and coordinator DNF hook integration
are pending; this source change does not install or select a kernel.

5 November 2026 source update: the kernel loader supports a separate private
v5 bundle with a mandatory 112-byte memory/protection payload for each usable
preset, including explicit neutral state. It prefers the matching panel's
`o82-{36,42}-color-v5.bin` and tries v4 only when v5 is absent (`ENOENT`).
Invalid v5 data, other access errors and filename/version mismatches are terminal.
Existing v4 inputs retain absent memory and their earlier PA ownership.
Remote checks passed COPR11261036:2,048 actual loader/encoder cases per
compiler, repaired-CRC tampering and fallback/version checks. The `0.6.0-3`
utility emits v5 from OEM JSON and passed COPR11261174:1,024 complete
JSON/bundle/actual C loader cases and12,288 paired command streams per compiler.
Complete12101 source integration with qualified touch and front-camera geometry
passed COPR11261282 from4800f0b884594018885c7ebadb3238c03499199f. The reusable
layer passes four source rejection controls and exact repeated application;
inherited preflight and the actual linked AArch64 MSM object retain both supplier
DT resources and the raw configuration. This receipt produces no Image, module
or boot package. Later GMU IRQ integration remains the coordinator's separate
cumulative gate. Full kernel delivery, private profile preparation and
physical memory/protection/HDR acceptance remain incomplete. Initial color
selection remains empty. Historical candidate observations below retain their
dated scope.

The v5 generator converts all three memory-color regions and ORs their global
hue, saturation, value, contrast, SixZone and blending protection, including
protection from disabled regions. Each usable preset includes explicit active
or neutral state. Conversion preserves the O82 parser's observed skin
saturation edge behavior and refuses malformed typed fields. The qualified remote
pipeline check connects actual JSON conversion, generated bundles, the native
C loader and paired command encoding for both supplier identities. Private
profiles remain local; the package contains no factory tables. Active opaque
HDR operations remain explicitly blocked pending their implementation.

1 November 2026. OEM P3 mapping for POCO Pad X1 / Xiaomi Pad 7 O82 panels,
Fedora Rawhide AArch64 and original KWin 6.8.2. Compilation and numerical checks
run in COPR. Optical color and HDR acceptance require separate measurements.

4 November development update: the tablet now runs `7.3.1-7200-unstable`.
New kernel candidates use `senemos-uke-linux-kernel-mainline-unstable` and an
`-unstable` ABI. The active v4 candidate retains separately installed 7300, its
read-only RTC gate and camera admission boundaries. Normal-family changes require an explicit request
and physical stability/feature validation before promotion. Earlier `1500`
observations below retain their dated scope.

Earlier 4 November 2026 device check: the tablet ran 7.3.1-1500; the generator
package and both fixed native v2 firmware files were absent. The ICC reports
below describe their dated trials and do not establish the current root's
profile selection. Full private-profile application and native HDR remain open.

The `0.5.0-1` candidate adds private v4 data with explicit active or neutral
HSIC. Every unblocked record carries24 bytes of flags and bounded register
words; the parser retains the qualified single-precision conversion order.
The candidate loader requests only `o82-{36,42}-color-v4.bin` and rejects older
bundles. The matching kernel writer composes HSIC/SixZone mode once per DSPP,
programs neutral scalar words and checks readback under held power. The actual
compiler/loader passed
[COPR 11253922](https://copr.fedorainfracloud.org/coprs/mcc45tr/uke-linux-unstable/build/11253922/):
16,479 parser/wire/composed-state checks per optimized/sanitizer run, plus the
actual v4 loader and retained numeric regressions. Complete native-kernel
qualification of `7.3.1-7600-unstable` passed
[COPR 11259981](https://copr.fedorainfracloud.org/coprs/mcc45tr/uke-linux-unstable/build/11259981/):
Image, linked/signed modules, both supplier DTs and matched boot/RPM checks.
All six AArch64 packages and SRC are present in checksum-verified repository
metadata. This 7200-based trial is held from delivery because it lacks the
later 7300 RTC gate. The 7300-based 10000 source passed full kernel/package qualification in
[COPR 11260145](https://copr.fedorainfracloud.org/coprs/mcc45tr/uke-linux-unstable/build/11260145/).
Delivery remains held because 8101 was installed/selected independently during
the build and adds a CAMCC stage absent from this color composition. Preserve
that isolated boot trial and review cumulative source before another build. Physical color/HDR acceptance remains open. Historical normal 7500
is software evidence from before the channel change and does not authorize
stable promotion. Delivered `7001`
continues to require v3; private v4 delivery and physical acceptance are open.
Memory-color and opaque HDR operations remain refused.

The `0.4.0-1` source adds a private v3 bundle with explicit SixZone 2.0 data:
32 bytes of flags/thresholds/PWL/hold state and 384 five-component tuples.
The actual JSON parser uses separate `SixZoneThresholds`, preserves legacy
middle/high curve selection and refuses fractional/invalid thresholds, partial
bands and unknown edge names. The native loader requests only the matching
`o82-36-color-v3.bin` or `o82-42-color-v3.bin`; older bundles are refused.
Compiler/loader qualification passed in
[COPR 11253576](https://copr.fedorainfracloud.org/coprs/mcc45tr/uke-linux-unstable/build/11253576/)
at source `33035dff7573775fb5f7ae7e3909e36451043899`. Actual parser/wire/shared-state
fixtures each passed 30,724 optimized/sanitized checks; actual native loader,
25,155 converter checks and retained gamut regressions also passed.
The matching PA consumer passed full kernel and package qualification in
[COPR 11253722](https://copr.fedorainfracloud.org/coprs/mcc45tr/uke-linux-unstable/build/11253722/),
`7.3.1-7001.fc46`. Its default preset is empty; private input delivery,
remaining picture/HDR operations and physical acceptance remain required.

The `0.3.0-5` source corrects factory gamut interpolation and native sampling
to the OEM 12-bit coordinates 0,256,...,3840,4095, including the shorter final
interval. Earlier generated ICC and native data require regeneration with the
corrected utility. That correction retained the accepted input hashes and file formats.
The [source record](../manifests/o82-gamut-source-20261104.json) distinguishes
this protocol evidence from optical validation. Remote regression qualification
of this correction passed in `0.3.0-6`,
[COPR 11252971](https://copr.fedorainfracloud.org/coprs/mcc45tr/uke-linux-unstable/build/11252971/).
GCC and Clang ASan/UBSan each passed 29,532 independent synthetic coordinate
and native-output checks. The actual former source failed 14,583 of those
checks as required. The first `0.3.0-5` attempt stopped in the test entry-point
compilation; its replacement retains strict compiler diagnostics.

The initial `0.1.0-2` passed numerical checks and saved ICC selection, but its
serialized stage order was rejected when original KWin rendered the output.
User photographs reported crushed shadows and excessive contrast/saturation.
COPR 11239895 built signed `0.2.0-3` with the corrected LUT16 leading-matrix
layout, serialized-stage validation, dark/gray roundtrips and ASan/UBSan checks.
That version was installed for the recorded trial and generated a replacement private PB profile.
A short active-output trial on Linux 7.3.1-115 produced no former ICC shader
error. The previous disabled-output state and brightness were restored.
Optical accuracy and comparison with Android remain unverified.

`uke-o82-color-profile` creates a private ICC profile from one exact retained
Global OS3.0.304.0 factory QDCM input. It accepts only the reviewed PA/PB SHA-256
identities and the `standard_P3` selector with SDR/P3/sRGB-transfer metadata.
It validates active IGC/gamut/GC, rejects unsupported active picture operations
and verifies gamut axis order against the same file's disabled identity table.
The input contains 257-point IGC, 17³ gamut and 1024-point output gamma data.

The ICC BToA transform converts standard XYZ D50 into encoded Display-P3 and
then applies the factory IGC → gamut → GC mapping. Gamut interpolation is
trilinear; the software mapping remains an approximation until compared with
the OEM hardware's interpolation and optical output. No nominal luminance is
presented as a measured display value. The profile description explicitly
identifies this boundary.

Original KDE already implements ICC 3D-LUT rendering and EDR for an internal
backlight-controlled display. This permits wide-color content conversion and
HDR10 content tone mapping in the compositor's existing pipeline without a
KDE fork, a false panel PQ capability or new hardware color-register writes.
This does not advertise a native HDR10/PQ DSI mode, provide Dolby Vision, change
the fixed 10-bpc link or establish optical HDR accuracy. The existing EDR
brightness estimate also remains uncalibrated for O82.

The generator writes only a new 0600 output file and refuses to replace an
existing file. It never reads persist, performs calibration, enables HBM,
changes LED current or communicates with an amplifier, DSP, panel or GPU.
Factory input and generated ICC data must remain local and private.

The additional `--native-hdr OEM_JSON NEW_COLOR_DATA` form prepares private,
bounded PQ and gamma-2.2 input curves, a linear BT.2020-to-OEM-P3 gamut mapping
and factory output gamma. It uses the OEM nominal 420-nit value as a conversion
bound, not measured luminance or a request for HBM. The versioned data includes
the exact source identity, length, bounds and CRC. No driver consumes it yet.
The separately tested HDR descriptor is not attached to the live connector.
A separate native Cliffs DB transport now implements bounded descriptor
submission, completion/error polling, checked reset and a failed-stop latch.
Its actual C source is checked against deterministic MMIO in COPR; it has no
live atomic color caller. Main now contains bound-KMS GEM/VM, runtime-power,
clock/QoS and explicit MMU-drain ownership, qualified by COPR 11252759. Paired
atomic application, all preset operations and the
four compositor input combinations still require integration. Native HDR
advertisement remains disabled. See the
[native transport contract](O82-NATIVE-COLOR.md) for the current boundary.

The `0.3.0` source adds `--native-presets OEM_JSON NEW_PRIVATE_BUNDLE`.
It inventories every retained preset separately and compiles distinct native
and BT.2020 input gamuts, each selectable with gamma2.2 or PQ. It preserves
factory picture/HDR operations in private metadata. Nonzero SixZone, scalar
HSIC, memory-color and opaque HDR-library operations remain explicitly blocked
until their complete implementation exists. A blocked preset never aliases a
different preset's transform. This bundle is not yet consumed by the driver.

The earlier audit grouped SixZone and memory-color under one counter. Separate
inspection of all eight PB picture variants shows no enabled skin/sky/foliage
block; the forty combined-active modes use SixZone. Some enabled SixZone curves
are entirely zero. The compiler preserves that identity case while refusing
nonzero curves; nominal enable counts alone do not describe their visual effect.

The first real PB bundle attempt with `0.3.0-1` refused enabled IGC dithering
before writing an output file. The `0.3.0-2` source preserves each preset's
IGC dither flag and four-bit strength explicitly. The native engine must apply
that state with its selected input tables; preparation is not hardware support.

COPR 11240486 passes utility0.3.0-4 and actual Linux7.3.1 AArch64 object checks.
The verified production generator creates both private PA/PB bundles with59
records,47 compiled transforms and12 explicitly refused nonzero picture/HDR
operations. Each preserves32 IGC-dither configurations. No firmware is installed,
no profile was applied in that data-generation trial and its corrected
temporary ICC was retained. Current profile selection is a separate check.

## Use

First identify the actual panel compatible, for example
`xiaomi,o82-42-02-0b`, and select its exact corresponding QDCM JSON from the
read-only OEM resources. Generate a new output path:

```bash
uke-o82-color-profile /path/to/exact-o82-qdcm.json /path/to/new-private-o82.icc
```

To prepare the native bundle without installing firmware or changing output:

```bash
uke-o82-color-profile --native-presets /path/to/exact-o82-qdcm.json /path/to/new-private-o82.bin
```

After retaining the current KScreen configuration, the original desktop can
select the generated file using its ICC profile setting or standard interface:

```bash
kscreen-doctor output.DSI-1.iccprofile./path/to/new-private-o82.icc output.DSI-1.colorProfileSource.ICC
```

Use the original EDR policy for correctly tagged HDR10 content. The native HDR
and WCG capability toggles remain separate; this tool does not force them or
write a fabricated EDID. Record whether the application supplies correct
color metadata, and keep the external DP output's profile independent.

Validate black/white clipping, gradients, grayscale, sRGB and tagged P3 images,
HDR highlight roll-off, direct-scanout behavior and recovery after modesets.
Compare with matched Android settings and instrument-measured luminance and
chromaticity before calling the profile calibrated or the HDR target complete.

## Sources

Exact O82 QDCM profiles are read from local OEM resources and are not included.
Their pins and scalar audit are in the central Uke audio/display report dated
1 November 2026. Input PA SHA-256 is
`bd88eb94134e5f62c05eebaa0a9e4b5267968363f72f440018b98a15d1bd9122`;
PB is `2b6442ce0e8fef6d1b008cdeca3838450282868d385f6e3056c0a4ce2b8949d8`.

The original [KWin ICC implementation](https://github.com/KDE/kwin/blob/f130ab33c8e6f3b9d728aade87836086ae9a8ed4/src/opengl/icc_shader.cpp)
and [profile parser](https://github.com/KDE/kwin/blob/f130ab33c8e6f3b9d728aade87836086ae9a8ed4/src/core/iccprofile.cpp)
provide the accepted BToA curve/matrix/CLUT contract. Xiaomi display driver
`44275c404a677d9d9e5230fedd1af2ef02fc7b9a` and display DT
`4a3e1c391130237c5e8c2b250d1c94f3e25b9b11` identify the separate native
IGC v4/gamut v4.3/LUTBUS hardware path. No donor implementation is executed.
