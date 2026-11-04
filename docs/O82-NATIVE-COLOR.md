# O82 native color transport

4 November 2026. POCO Pad X1 / Xiaomi Pad 7, SM7675, pinned Linux 7.3.1.
This report describes main source and remote checks. Normal retained kernel
candidates keep color DMA and native HDR advertisement disabled. Source now
contains an experimental paired CRTC caller qualified by remote source, fault
and object checks. The initial `o82_color_profile` parameter is empty by default.

## Source implementation

The exact OEM display references are
[Cliffs DT 4a3e1c3](https://github.com/MiCode/vendor_qcom_proprietary_display-devicetree/tree/4a3e1c391130237c5e8c2b250d1c94f3e25b9b11)
and [GPL display driver 44275c4](https://github.com/MiCode/vendor_opensource_display-drivers/tree/44275c404a677d9d9e5230fedd1af2ef02fc7b9a).
Their selected IGC4/gamut4.3 implementation uses LUTBUS; older IGC3.1/gamut4.0
writers in the same source are different protocols. OEM submission permits
DB queue 0 when SB queue 1 is unsupported; the native transport implements DB.

The current source provides these components:

- `dpu_o82_color.c` loads the matching private bundle for one enabled O82 DT
  variant and selects the explicit initial preset. Atomic checking reserves
  two distinct DSPPs and one bonded CTL. Full modesets require both physical
  video interfaces to be disabled in software and hardware before upload.
  Standard connector colorspace/HDR metadata selects the wire gamut/transfer;
  PQ advertisement remains disabled. Failure blocks physical enable and kickoff.
  Factory GC composes with the client's gamma; gamma-only changes use the
  existing shadowed GC path, while PCC/CTM retains its native atomic path.
- `dpu_o82_platform.c` admits only the bound Uke/SM7675 DPU and its separate
  MDP/VBIF/REGDMA resources. Init reserves/maps resources without programming
  color. REGDMA spans 0x0af80000..0x0af86fff.
- `dpu_o82_lutbus.c` builds a stream of 37,316 bytes for two DSPPs,
  covering IGC4/gamut4.3/GC1.8,
  including endpoint/alignment padding and the three-NOP LUTBUS workaround.
  GC packing uses G/B/R. Exact stock conversion and the shared ABI establish
  gamut c0=R, c2_c1 high=G, low=B, with R-fast bank-interleaved input. The
  [source record](../manifests/o82-gamut-source-20261104.json) records that chain.
- `dpu_o82_upload.c` owns one bounded WC MSM GEM command buffer and a reference
  to the admitted KMS's managed display VM. Encoding, reuse and submission share
  the transport mutex; foreign KMS/VM arguments are refused before allocation.
- `dpu_o82_power.c` owns runtime PM, previously-clear MDP/PMU force bits and
  exact xin7 LUTDMA priorities 4,4,4,4,5,5,5,5 in both QoS tables. Shared register
  RMW operations are serialized and requested clock/QoS fields require readback.
- `dpu_o82_regdma.c` validates CTL 1–4, 256-byte alignment, 32-bit IOVA and
  descriptor length before ordered address/trigger writes. It checks queue 0
  completion and global errors; an error plus completion still fails.

The complete paired color state is invalid after any upload error. A successful
DMA transaction alone does not reserve both DSPPs, prove both panel halves
stopped, establish table semantics or enable an output.

## Failed-stop and destruction ownership

The transport timeout of 2 ms requires a checked reset. Failed reset retains the
command buffer, mapping, clocks and runtime reference and refuses new uploads
and clock-off suspend. Ordinary recovery retries the stop before releasing
owned power. Successful runtime suspend releases cached GEM memory before its
caller disables clocks.

The KMS hardware destructor, explicit MMU destructor and probe unwind close
admission and drain before clearing hardware pointers or detaching the VM.
Managed VM close itself is a no-op; a GPUVM reference cannot prevent an explicit
MMU detach. The finalizer must therefore run in those actual paths.

If reset fails, the exact Uke VBIF fallback requests xin7 halt at offset 0x200,
bit 7, and requires acknowledgement at offset 0x204, bit 23. The generic upstream low-half
getter is insufficient for this hardware. Only confirmed isolation permits
failed-reset memory release; halt remains asserted. A later owner must reset
all four DB queues before clearing it and accepting a new descriptor.

If neither reset nor halt acknowledgement succeeds, the void KMS destructor
waits with a sleep and one diagnostic while retaining owned resources.
Permanent hardware failure can block unbind. Returning into devres destruction
with an active DMA owner would release resources still accessible to hardware.

## Qualification

The private-data compiler's input grid is separately qualified in
[COPR 11252971](https://copr.fedorainfracloud.org/coprs/mcc45tr/uke-linux-unstable/build/11252971/),
utility `0.3.0-6`. Both optimized and ASan/UBSan runs passed 29,532 asymmetric
knot/midpoint/native-output checks; the actual previous implementation failed
14,583 checks. This source-derived numeric correction requires regenerating
private ICC/native data. It does not exercise a live paired output.

[COPR 11253082](https://copr.fedorainfracloud.org/coprs/mcc45tr/uke-linux-unstable/build/11253082/)
passed complete retained preparation and:

- GCC/Clang ASan/UBSan execution of the actual encoder, transport, GEM/power
  owner, shared clock/QoS/halt helpers and current MMU destructor.
- Fault cases for ignored writes, failed stop/clock/PM cleanup, wrong-half
  halt status, retained ownership across drain retries and failed rearm.
- Negative controls rejecting the actual former MMU destructor while DMA
  resources remained owned.
- Actual paired CRTC caller, both physical-interface stop checks, all four
  supported wire combinations, factory/client gamma composition and complete
  IGC/gamut/GC flush masks. Refused kickoff precedes frame bookkeeping and
  preserves the retained scanout-retirement submission contract.
- Real AArch64 MSM composite linkage, required defined/internal symbols,
  both O82 supplier DT resource tuples and the binding document.

This is source/object and fake-provider qualification. It is not live DMA,
warm-rebind, permanent-failure unbind, optical output or power-saving acceptance.
Earlier failed fixtures and corrections remain in the canonical engineering
journal. No native compilation or device activation ran on the tablet.

[COPR 11253343](https://copr.fedorainfracloud.org/coprs/mcc45tr/uke-linux-unstable/build/11253343/)
completed the normal retained kernel build at source
`90b8c9c89f8c89475c5a371f58dc7c7c88e29911`, release `7.3.1-6503.fc46`.
All five display fixtures passed against the final prepared source before
compilation. The complete build and package checks passed, including the actual
MSM module, paired color functions, both supplier DT resource tuples, retained
configuration and touch ACK checks. The six AArch64 packages and source RPM
are present in the root unstable repository's checksum-verified primary index.
This preserves the retained camera, sensor, power and peripheral changes.
Initial color selection remains empty and native HDR advertisement disabled;
the package result does not establish physical acceptance.

The subsequent tablet RPM check still finds kernel `1500` as the highest
installed release and `uke-nfc-ir 1.0.0-1`. Local DNF version locks pin all six
kernel packages and that client. Those locks prevent an ordinary update from
selecting the new versions on this installation. They were left unchanged;
repository availability and local transaction eligibility are separate results.

## Required integration and inputs

The existing native CRTC already supplies GC1.8 with 1024 entries and CTM programming.
The experimental caller coordinates those paths and stages IGC/gamut/GC flush
bits for both DSPPs. Complete source/link/fault checks passed; normal kernel
package qualification passed in release `6503`; a recoverable physical trial
remains required.
Dynamic preset control, private data delivery,
all remaining picture/HDR operations and truthful HDR admission remain open.
An unsupported preset must not alias a different transform.

The [SixZone source comparison](../manifests/o82-sixzone-source-20261104.json)
maps the exact OEM 2.0 five-component writer and extended userspace ABI to the
retained binary's two conversion functions. This is a static protocol result.
The separate threshold input, percent-to-byte quantization, PWL packing and
legacy saturation-curve selection are traced through the retained parser.
Complete parser admission, shared PA control
ownership and native fault-tested programming remain required before admitting
the currently blocked picture operations. The older three-component writer or
an older ABI header cannot stand in for that implementation.

`o82-sixzone.h` supplies a bounded, typed integer-domain converter for the
extended UAPI words. It validates all input before replacing output, preserves
legacy saturation curves and rejects invalid ranges/overlapping bands. Its
synthetic [COPR 11253462](https://copr.fedorainfracloud.org/coprs/mcc45tr/uke-linux-unstable/build/11253462/)
passed 25,155 checks in each optimized GCC and Clang ASan/UBSan run at source
`8413155dcd18debd30333f935cae43e488cb3798`. This preparatory converter
does not change the installed utility, v2 bundle, admitted presets or kernel
writer. Complete PA register/flush integration remains required.

Delivered release `6503` validates a fixed PA/PB v2 bundle before publishing state
and retains it until explicit unload. Refused selection leaves the previous
record/pointers unchanged. The recorded v2 preparation has 59 records: 47 compiled
transforms and 12 explicitly blocked nonzero picture/HDR operations. That
preparation does not complete the full native color objective.

The v3 compiler/loader carries explicit bounded SixZone data and rejects older
input. Utility `0.4.0-1` passed
[COPR 11253576](https://copr.fedorainfracloud.org/coprs/mcc45tr/uke-linux-unstable/build/11253576/),
including 30,724 actual parser/wire/shared-state checks per optimized/sanitized
run and the actual loader. Release `6503` retains its historical v2 contract;
the separately qualified `7001` consumer below requires matching v3 input.

The paired PA source appends SixZone LUTBUS block3 (192 transfers), exact
threshold/PWL/SV writes and individual shared hold/mode modifies. The power
wrapper admits only the exact Uke catalog, reads each selected DSPP's current
state under held runtime power and verifies controls after DMA. Disable retains
another PA feature's enable state; the actual CRTC stages shared PA flush bit0
for both DSPPs. The command buffer accommodates 41,288 bytes while descriptors
cover the selected stream length.

[COPR 11253722](https://copr.fedorainfracloud.org/coprs/mcc45tr/uke-linux-unstable/build/11253722/)
passed the complete `7.3.1-7001.fc46` kernel and package checks from source
`be068c2f3cf9f561aedab27410b626eeeb1322b0`. Actual paired loader, LUTBUS,
power/transport and atomic fixtures passed optimized and sanitizer runs; all
retained display controls, full MSM linkage and both supplier DT checks passed.
Six AArch64 RPMs and the source RPM appear in checksum-verified root unstable
metadata. Initial preset selection and native HDR advertisement remain disabled.
Private data delivery, remaining picture/HDR operations and physical acceptance
remain open. The tablet still runs `1500`, with all six kernel packages pinned
to that release by DNF versionlocks; repository delivery does not remove them.

The separate [HSIC source record](../manifests/o82-hsic-source-20261104.json)
traces exact OEM scalar ranges and signed packing. Its saturation/contrast
inputs use a normalized domain, value uses a signed brightness domain and
saturation threshold shares the saturation word. SixZone percent scaling and
rounded fixed-point helpers do not implement those operations. The exact JSON
parser reads hue as an integer and the other four scalars as single precision;
any nonzero typed scalar sets its global PA flag. Outer action/disable routing
and one composed shared PA state remain required.

The typed pure HSIC converter passed41,340 synthetic checks per GCC optimized
and Clang ASan/UBSan run in
[COPR 11253747](https://copr.fedorainfracloud.org/coprs/mcc45tr/uke-linux-unstable/build/11253747/).
An independent integer IEEE754 reference checks the single-precision operations;
wide intermediates and rounded conversion differ in128 and1,540 required
negative cases. Its receipt-only RPM contains no executable or private input.
The new `0.5.0-1` compiler/loader and composed kernel writer carry private v4
HSIC data explicitly, including neutral state. The writer broadcasts all four
scalar words, then combines HSIC/SixZone enables with each DSPP's own powered
snapshot and modifies shared mode once with preserve mask `0x01efffff`.
Both active and neutral words are read back. Buffers cover41,320 bytes and
descriptors retain the actual37,388/41,320-byte managed stream length.
The actual compiler/loader passed
[COPR 11253922](https://copr.fedorainfracloud.org/coprs/mcc45tr/uke-linux-unstable/build/11253922/)
at source `d10c0e35649c96d4e6f92316e75948cd51116784`, with16,479 actual
parser/wire/composed-state checks per optimized/sanitizer run and the actual
v4 loader. Pure HSIC41,340 and SixZone30,724 checks per run remain green.
The [active full-kernel composition](../manifests/o82-hsic-unstable-source-20261104.json)
retains installed 7300, its read-only RTC gate, 43 imports and one declared
compact audio identity update. It preserves the camera boot boundary and pstore layout.
New development uses `senemos-uke-linux-kernel-mainline-unstable` with an
`-unstable` Image ABI. The earlier normal 7500 build passed software checks before
the policy change; it is historical evidence and does not authorize promotion.
The active entry point routes only to the unstable producer.
[COPR 11259981](https://copr.fedorainfracloud.org/coprs/mcc45tr/uke-linux-unstable/build/11259981/)
passed the full `7.3.1-7600-unstable` Image, MSM/MODPOST, signed module, both
supplier DT and boot/RPM checks. Actual composed loader/LUTBUS/power/atomic
fixtures and retained display controls passed. Six AArch64 packages and SRC
are published as a software reference. That 7200-based trial is held from
delivery because installed 7300 adds a read-only RTC gate. The active producer
retains 7300 exactly and used a fresh 10000 ABI after concurrent source publication.
Complete kernel qualification passed in
[COPR 11260145](https://copr.fedorainfracloud.org/coprs/mcc45tr/uke-linux-unstable/build/11260145/)
for 10000-unstable, including Image, linked/signed modules, both supplier DTs,
boot/RPM and paired color fixtures. Source SHA and all seven repository
identities are recorded in the manifest. Future revisions require at least 10001.
Delivery is held after an external 8101 installation/selection added CAMCC
stage1. Preserve that isolated boot trial and review cumulative source before
another color build. Physical acceptance remains open;
delivered `7001` retains its v3 contract and disabled default. Memory/protection,
complete HDR, private data delivery and physical acceptance remain open.

The 4 November tablet inspection found neither fixed native bundle nor the
`uke-o82-color-profile` package installed. Earlier private ICC trials describe
their dated environment, not the current root. Factory inputs and generated
data remain private. See [profile preparation](O82-COLOR-PROFILE.md).

Truthful DRM/EDID admission and physical transfer/gamut/luminance measurements
remain required before advertising HDR. A synthetic EDID cannot carry arbitrary
factory LUTs or establish the transform performed by the display pipeline.
