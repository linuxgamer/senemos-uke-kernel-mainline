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

The register and clock evidence is the GPL-2.0-only Xiaomi
[REGDMA implementation](https://github.com/MiCode/vendor_opensource_display-drivers/blob/44275c404a677d9d9e5230fedd1af2ef02fc7b9a/msm/sde/sde_hw_reg_dma_v1.c)
at commit `44275c404a677d9d9e5230fedd1af2ef02fc7b9a`.
The native interface uses Linux 7.3.1 DPU CTL addressing. Reference source is
read as evidence and is never executed as a driver or build shortcut.
