# Full Type-C FDT host fixture

18 October2026. The source-only fixture is prepared for coordinator execution;
it was not compiled or run by the USB source conversation. It adds no production
DT, boot input or hardware result. Existing peripheral fixtures are unchanged.

```sh
CC=clang CXX=clang++ bash tests/usb-typec-fdt-contract.sh \
    PREPARED_KERNEL OEM_ABL_INPUT NATIVE_GENERATED NEW_PRIVATE_OUTPUT
```

`OEM_ABL_INPUT` must be the retained, bounded regular OEM/ABL FDT, before the
project adaptation. An already adapted runtime FDT is not substituted. Inputs
are opened read-only without following their final symlink. `NATIVE_GENERATED`
must contain the actual committed producer's `ufs.dtbo`, `usb.dtbo`,
`display.dtbo` and `usb-profile=typec-v1` receipt. The kernel directory supplies
its bundled libfdt and exact DT binding identifiers. The new output directory
is private and must not already exist.

The host compiles the actual project `uke_abl_transform` and `uke_abl_native`
with that libfdt implementation. It runs the base and native transformations on
copies of the real input, then validates the resulting graph. It does not use
`fdtput` to manufacture an accepted DT or replace production helper functions.

Checks include the full controller/PHY compatibles, OTG/Gen1 mode, UCSI connector
and reciprocal HS/SS/SBU/DP endpoints, exact GIC/PDC cells and wake IRQs, one
generic eUSB2 owner and actual repeater, core/QMP GDSC and analog supplies,
correct GCC PIPE and DISPCC DP clock providers, DP controller MMIO/MDSS IRQ/PHY,
HBR2 OPP ceiling, source marker and disabled legacy GLINK/DWC3/DP/SLIM paths.

Original input bytes, memory nodes, reservation properties/map and selected
boot arguments are compared directly. The firmware framebuffer path comes from
the actual intermediate adaptation, not the OEM UART stdout path. Native entry
retains the enabled framebuffer and its stdout reference for early scanout.
Its backlight link is removed so early simpledrm does not defer for, or blank,
the native panel's backlight. Geometry, visible range, panel metadata and the
full no-map splash reservation remain unchanged. The existing MSM aperture
removal supplies the native takeover path; host checks do not establish a
seamless physical transition.

For internal DSI comparison, the fixture separately compiles the same O82-42
seven-mode overlay source without the DP option, then applies the actual native
helper to the same adapted base. Common DSI controller, PHY, panel, supply,
reset and DPU-DSI endpoint subtrees must match. Phandle references are compared
by provider path and arguments rather than overlay-dependent integer values.
This is a source-comparison baseline, not another hardware-qualified image.

Private result-copy mutations verify that the checker rejects broken PHY,
endpoint, supply and speed contracts. Separate malformed OEM board/UFS and
truncated-overlay cases execute the actual base transform's rejection path and
verify input immutability. These negative copies are not serialized or counted
as production admission tests for conditions the runtime transform does not
check.

Only a successful actual transformation that passes all checks is written as
`admitted-full.dtb`, with a source/input/overlay/output SHA-256 receipt. Output
and logs may contain private FDT data and belong in private reports. A host PASS
does not establish boot, enumeration, PD delivery, monitor output, wake or
physical charging acceptance. The coordinator must record compiler/tool pins,
source tuple and results separately before target admission.
