# O82 native color transport

4 November 2026. POCO Pad X1 / Xiaomi Pad 7, SM7675, pinned Linux 7.3.1.
This report describes main source and remote checks. Normal retained kernel
candidates keep color DMA and native HDR advertisement disabled. There is no
atomic caller for the full private color-profile upload.

## Source implementation

The exact OEM display references are
[Cliffs DT 4a3e1c3](https://github.com/MiCode/vendor_qcom_proprietary_display-devicetree/tree/4a3e1c391130237c5e8c2b250d1c94f3e25b9b11)
and [GPL display driver 44275c4](https://github.com/MiCode/vendor_opensource_display-drivers/tree/44275c404a677d9d9e5230fedd1af2ef02fc7b9a).
Their selected IGC4/gamut4.3 implementation uses LUTBUS; older IGC3.1/gamut4.0
writers in the same source are different protocols. OEM submission permits
DB queue 0 when SB queue 1 is unsupported; the native transport implements DB.

The current source provides these components:

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

[COPR 11252759](https://copr.fedorainfracloud.org/coprs/mcc45tr/uke-linux-unstable/build/11252759/)
passed complete retained preparation and:

- GCC/Clang ASan/UBSan execution of the actual encoder, transport, GEM/power
  owner, shared clock/QoS/halt helpers and current MMU destructor.
- Fault cases for ignored writes, failed stop/clock/PM cleanup, wrong-half
  halt status, retained ownership across drain retries and failed rearm.
- Negative controls rejecting the actual former MMU destructor while DMA
  resources remained owned.
- Real AArch64 MSM composite linkage, required defined/internal symbols,
  both O82 supplier DT resource tuples and the binding document.

This is source/object and fake-provider qualification. It is not live DMA,
warm-rebind, permanent-failure unbind, optical output or power-saving acceptance.
Earlier failed fixtures and corrections remain in the canonical engineering
journal. No native compilation or device activation ran on the tablet.

## Required integration and inputs

The existing native CRTC already supplies GC1.8 with 1024 entries and CTM programming.
Full-profile application must coordinate with that atomic path, reserve the
paired DSPPs and prove both output halves stopped. It must also establish the
private firmware lifetime, independent
native/BT.2020 and gamma2.2/PQ selection, and all required picture/HDR operations.
An unsupported preset must not alias a different transform.

`dpu_o82_profiles.c` validates a fixed PA/PB v2 bundle before publishing state
and retains it until explicit unload. Refused selection leaves the previous
record/pointers unchanged. The current data format has 59 records: 47 compiled
transforms and 12 explicitly blocked nonzero picture/HDR operations. That
preparation does not complete the full native color objective.

The 4 November tablet inspection found neither fixed native bundle nor the
`uke-o82-color-profile` package installed. Earlier private ICC trials describe
their dated environment, not the current root. Factory inputs and generated
data remain private. See [profile preparation](O82-COLOR-PROFILE.md).

Truthful DRM/EDID admission and physical transfer/gamut/luminance measurements
remain required before advertising HDR. A synthetic EDID cannot carry arbitrary
factory LUTs or establish the transform performed by the display pipeline.
