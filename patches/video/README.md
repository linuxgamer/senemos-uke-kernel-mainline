# Linux 7.3 Cliffs video candidate

Date: 25 October 2026. Base: `470d18160dac9f9adf65ee8ff6f86472573504c1`,
the physical POCO Pad X1 Linux 7.3.0-3 source identity.

Native preparation applies this series after the display providers. It remains
outside the base upstream patch list. The source now includes the Iris OF match
and video graph; firmware and tablet codec acceptance remain separate.

1. `0001`: rebase six earlier dormant VIDEOCC/Iris candidates from `67c9ee7a`
   onto Linux 7.3, including its generation-specific firmware descriptor and
   the changed VIDEOCC binding condition.
2. `0002`-`0005`: Xilin Wu / Radxa decode-order, CAPTURE maximum, encoder
   deblocking and error timestamp changes, pinned by libva-v4l2 commit
   `6d03c3f8fb19b86f84b2b6c60ff20d1402f0ac41`. Attribution is retained.
3. `0006`: native MVS0C/MVS1C GDSCs acquire the exact OEM MXC/MMCX parent
   voter before clocks; the SM7675 binding requires that supply.
4. `0007`: the exact Uke HLOS Video/SF and Venus configuration interconnect
   routes, sharing existing display/USB/DDR providers and BCMs.
5. `0008`: exact Uke firmware mmap/device regions, checked allocation and
   mapping ownership, error-returning boot setup and PAS shutdown retention.
6. `0009`: exact video SID/ACTLR admission and a shared DMA aperture starting
   at the intersection of the OEM pixel/nonpixel pools.
7. `0010`: reject a missing/deferred controller parent rather than allowing
   the generic GDSC optional-supply lookup to omit it.
8. `0011`: propagate shared Qualcomm reset transport and callback errors.
9. `0012`: exact ordered controller reset and provider-owned retention,
   retryable power teardown, checked PM references and an SM7675 oneshot IRQ.
10. `0013`: codec/direction-specific dimensions, rate budgets and firmware
    control bounds, safe encoder pipe arithmetic and Q16 frame-rate preservation.
11. `0014`: native binding for two GDSCs, two streams and four ordered
    resets, with the existing SM8650 ABI retained.
12. `0015`: native SM7675 match and a firmware-availability check before
    resources and codec registration. Missing firmware does not start power.

The offline overlay in `src/video/` resolves against the captured Linux 7.3
handoff FDT and enables the native clock/codec nodes. The overlay also disables
the four OEM regulator GDSCs that overlap native VIDEOCC.
The live baseline reports those old providers and CVP unbound; their `ok`
DT status does not demonstrate a bound driver. CVP resources are preserved.
The shared nonsecure IOMMU mapping uses the exact OEM ACTLR and common DMA range;
equivalence to OEM split ownership still needs firmware/frame tests. The OPPs
192/240/338/366 MHz match the exact Uke module's SKU1 table and the same-SoC
source; they are not measured performance results or SKU0-only frequencies.

Sixteen actual-source host fixtures cover the new sequence, partial startup,
every reset failure, retention/readback failures, teardown retries and IRQ/PM
ownership. Iris and VIDEOCC compile with `CONFIG_SM_VIDEOCC_8550=m` and
`-Werror`; this checks the real exported-helper call rather than its stub.

The exact OS3.0.304.0 Cliffs v0/v1 XML files are identical, SHA-256
`748f378bb70638e464023767ec2bb5f9c113b38bb586f46f5ecda3dc2894160f`.
Their clear-video limits and the pinned Cliffs instance tables bound the
initial controls. Frame interval enumeration checks blocks/frame and floors
the blocks/s-derived rate. Encoder admission retains fractional Q16 rates,
including through both HFI packet writers, and restores the prior setting
when a request fails. The encoder clock estimate uses the platform pipe
count because its firmware table has no PIPE entry.

Main10 encode stays gated until the native P010 buffer/HFI path is implemented.
Coded-height conflicts, aggregate scheduling, remaining extended controls and
physical high-rate acceptance remain open; source limits are not measurements.

Remaining platform work includes SKU-specific HFI capabilities and target
validation of firmware/addressing/teardown. Complete full kernel/RPM validation and a recoverable
firmware/native V4L2 trial before activating this source series. Main10 encode,
extended modes, lifecycle, sustained performance and applications remain
separate required work.

A failed domain `put_sync` consumes its reference and latches an error; the
candidate retains firmware mappings instead of guessing a safe recovery.
Administrative unbind after failed PAS or power teardown remains unqualified.
