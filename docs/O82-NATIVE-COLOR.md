# O82 native color transport

1 November 2026. Source-stage Cliffs REGDMA3 transport for POCO Pad X1 / Xiaomi
Pad 7. Remote checks use deterministic MMIO and do not access a display engine.
There is no live caller, new EDID attachment or HDR capability from this source.

COPR [11240208](https://copr.fedorainfracloud.org/coprs/mcc45tr/uke-linux-unstable/build/11240208/)
passes the actual-source GCC and Clang ASan/UBSan MMIO fixtures and the existing
numerical/C11/EDID checks. The signed utility 0.2.0-9 is built; its binary does
not contain or execute this kernel transport. A full kernel-object build,
native owner integration and physical acceptance remain separate.

`src/display/dpu_o82_regdma.c` implements the exact DB queue contract: CTL IDs
1–4, 256-byte-aligned 32-bit IOVA, bounded DWORD count, local PMU clock ownership,
reset before address publication, ordered descriptor/trigger writes, queue0
completion and global error checks. A completion accompanied by an error fails.
The polling deadline is 2 ms; an error or timeout requires a checked reset.

If reset remains asserted, the transport latches the owning CTL and refuses
another submission. It retains its local clock request. The owner must retain
the buffer, its IOMMU mapping, runtime power and the MDP clock. A failed-stop
buffer must never be unmapped merely because the submission function returned
an error. `dpu_o82_regdma_can_unmap()` stays false until explicit recovery sees
reset clear. The owner excludes new submissions when checking this guard and
releasing memory. The guard is required before VM detach as well as GEM release.
This contract is not yet connected to the native KMS teardown path.

The original OEM `reset_v1()` polls twice and returns zero regardless of the
last reset value. This implementation preserves a failed result and prohibits
release/reuse. Its transport mutex serializes the entire REGDMA3 DB engine;
it does not grant ownership of another client's MDP or VBIF registers.

The caller must hold runtime power, the existing MDP REG_DMA clock request
and modeset exclusion. Both internal panel halves remain stopped until every
color block on both DSPPs is ready. The local PMU clock register is separate
from the MDP clock gate. The transport restores only locally acquired bits,
preserving previously forced bits and unrelated concurrent register bits.
Any failed transfer invalidates the complete paired color state, including
when a successful reset makes the DMA buffer releasable.

The source fixture checks actual transport code with GCC and Clang ASan/UBSan:
input refusal before MMIO, all CTL offsets, stale status/error clearing,
publication barriers, previously forced clocks, simultaneous error/completion,
wrong-queue completion, bounded timeout, stuck reset, refusal while quarantined
and explicit recovery. It does not establish real bus ordering, register
behavior, reset completion, physical color output or optical calibration.

Remaining integration includes the exact Cliffs DT resource, RT xin7 QoS,
GEM/nonsecure VM allocation and lifetime, full modeset stop proof, paired DSPP
reservation, IGC/gamut/GC/PA programming, all validated OEM presets, independent
native/BT.2020 and gamma2.2/PQ input selection, and truthful DRM/EDID admission.
The current private ICC remains selected until its complete replacement is
available. A synthetic EDID cannot embed arbitrary factory LUTs; it describes
the logical gamut and transfer actually implemented by the selected transform.

The v2 private bundle in `o82-color-firmware.h` provides distinct named records,
source identities, bounded contiguous offsets, checked monotonic curves and
12/10-bit table ranges. Its native-gamut and BT.2020 cubes are separate; either
can use gamma2.2 or PQ. Per-preset IGC dithering is retained with its bounded
four-bit strength. Records with unimplemented active processing contain no
selectable table payload. Their original picture/HDR data remains private and
the selector refuses them without changing output pointers. Zero-valued
SixZone adjustment curves are treated as an identity operation.

`dpu_o82_profiles.c` loads only a fixed PA/PB firmware name from the real root,
validates the entire bundle before publishing state and retains the firmware
until its owner releases it. Missing/corrupt data or an unsupported default
does not publish a partial state. Preset refusal preserves the selected record;
invalid input selection preserves the caller's table pointers. There is no
KMS caller or hardware activation from this loader yet. Hardware bank/channel
order and all nonzero picture operations still need verification and integration.

The remote source-stage object check uses the exact Linux 7.3.1 archive,
SHA-256 `fa595aad93734f829c963c2a90ef7c3673224fd7fdae7b49406e397cde2de231`.
It builds only the loader and transport objects against actual AArch64 kernel
headers, with a small local Kbuild for the direct targets. The source-stage
archive stays in the owner's reference cache. No Image, module or firmware is
produced, and the production adaptation queue/linkage remains a separate check.
The check needs the same upstream MSM register generator as the production
kernel. The existing host-only exception in `packaging/native/README.md` pins
`drivers/gpu/drm/msm/registers/gen_header.py` to SHA-256
`81763fc03ea0ebf254ab7427af2113dc0c7c0d80dceab61232b6e371463d1f90`.
It runs unmodified only on the COPR worker to produce `mdp_common.xml.h` from
the exact upstream XML. Reimplementing it or borrowing headers from another
kernel would weaken the ABI check. No project Python or Python payload is added
to the tablet. The first direct-object trial failed on the missing generated
header before producing an SRPM; the corrected source adds this existing step.

The register and clock evidence is the GPL-2.0-only Xiaomi
[REGDMA implementation](https://github.com/MiCode/vendor_opensource_display-drivers/blob/44275c404a677d9d9e5230fedd1af2ef02fc7b9a/msm/sde/sde_hw_reg_dma_v1.c)
at commit `44275c404a677d9d9e5230fedd1af2ef02fc7b9a`.
The native interface uses Linux 7.3.1 DPU CTL addressing. Reference source is
read as evidence and is never executed as a driver or build shortcut.
