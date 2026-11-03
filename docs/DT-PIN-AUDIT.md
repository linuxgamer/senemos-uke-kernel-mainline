# Uke DT and pin audit

On 14 October 2026, the Linux 7.2.10 stock-ABL transform was compared with
MiCode Uke DT `94c84aeb9e517dbde546fc732033c184094c8e57` and kernel
`5712080a4b0c0b1a879e6d145c601c649ddaddfd`. The OnePlus Nord 4 kernel at
`fc892483f1d61f245924681eb5abd563564d9cba` independently matches the 178 TLMM
mux rows and 96 PDC wake routes. Other boards do not establish Uke wiring.
See the component research inventory and the workspace's private
`uke-linux-docs/docs/research/UKE-DT-PIN-AUDIT-2026-10-14.md` for the full
source comparison, pin inventory and test limits.

Nine inherited, unselected mux states had invalid function names. The pinctrl
include corrects GPIO14 to `qup0_se3_l2` and eight amplifier IRQ states to
`gpio`. It preserves pin numbers, drive strengths and bias settings. Unported
QUP0 engines are disabled because their legacy DMA descriptions do not match
the translated provider. The touch and backlight buses remain admitted.

Before applying overlays, the transform now checks four critical GPIO tuples
and 16 pinctrl routes, including provider ancestry, pin lists, mux functions
and drive strength. Unsupported input fails before modifying the output.
These checks intentionally accept the reviewed firmware profiles only.

## Host checks

`src/audit/dt-pins.cpp` is a host-only C++20 audit using libfdt. Build it with a
host compiler, libfdt headers and library, or the matching kernel host libfdt
objects. It is not a tablet startup program and is not included in RPM payloads.

```sh
c++ -std=c++20 -O2 -Wall -Wextra -Werror src/audit/dt-pins.cpp -lfdt -o build/dt-pins
build/dt-pins ADMITTED.dtb OEM_PINCTRL_C LINUX_PINCTRL_C
bash tests/dt-pins.sh build/dt-pins ADMITTED.dtb OEM_PINCTRL_C LINUX_PINCTRL_C NEW_OUTPUT
bash tests/abl-dt-contract.sh ABL_CHECK INPUT.dtb UFS.dtbo USB.dtbo NEW_OUTPUT
```

The auditor compares all GPIO0–177 mux rows and the complete PDC map, resolves
pinctrl references, checks TLMM mux functions in selected and unselected states,
and checks standard GPIO and active provider specifier shapes. Special UFS
reset GPIO178 is checked separately by the transform. OEM LPASS vendor
`*-gpios` properties reference pinctrl states; they are not standard three-cell
GPIO specifiers. The auditor does not prove their vendor protocol, provider
readiness, IRQ delivery, voltage, calibration or physical ownership.

Twelve archived DT fixtures across three firmware/profile families passed the
transform and structural audit. RAM, reservations and GPIO-controller contents
were preserved except for the nine declared mux-name corrections. Fault tests
cover incorrect pins, providers, flags, pinctrl arrays and malformed blobs.
The C transform compiled as an AArch64 kernel object. The independent Uke DTB
also compiled; it remains an incomplete, compile-stage board description.

These are source and host build results. No new Image/RPM or tablet test was
performed. `dtc` compilation and this audit are not `dt-schema` validation.
