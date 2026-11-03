# Uke kernel light ownership

The [30 October OSS PWM/current review](../../docs/TORCH-PWM-RESEARCH-20261030.md)
clarifies that two torch steps follow the current native 20 mA total policy,
not a proven intrinsic hardware ceiling. Exact Uke OEM source admits more
current targets; RGB PWM and the unqualified torch hardware-strobe route remain
separate. This review changes no current limit or runtime driver.

The [OSS safety comparison](../../docs/TORCH-OSS-SAFETY-20261030.md) traces the
actual battery-query, thermal and duration paths. A native provider patch
preserves thermal transaction errors and refuses a budget below the physical
minimum. Current/threshold limits remain unchanged; higher-current continuous
operation still requires separate qualification.

30 October 2026. The existing RGB consumer owns notification policy. The torch
consumer adds a separate `senemos,uke-torch` DT node and `/dev/uke-torch` ABI 1.
Both use managed LED suppliers; neither accesses PMIC registers directly.

Torch admits only the existing Uke/SM7675 torch-only QCOM provider, channels 1
and 4, max brightness 2 and 20,000 microampere total ceiling. It owns sysfs stores
while bound. Percentage mapping, the remembered positive request, exclusive
writer and off on close, sleep, reboot and removal are serialized by its mutex.
The state allocation remains valid until the last open descriptor is released;
a dead consumer returns `ENODEV` without calling a removed provider. An output
failure attempts off and preserves the first error; an unsuccessful fallback
marks brightness unknown. No new deadline, current ceiling, regulator or flash
mode is introduced.

`tests/torch-lifetime.sh` and `tests/torch-supplier.sh` execute actual source
functions with simulated primitives. `tests/fixtures/torch-control-check.spec`
is an isolated COPR native-check recipe. It builds Control, runs its checks and
compiles this consumer against the recorded official Fedora kernel headers.
Its output RPM contains text receipts only, with no runtime or kernel module.
These checks do not replace a complete matched Uke kernel/DT build or attended
physical validation. The existing kernel release number is not allocated to
this candidate; any later runtime build needs a fresh release and recovery plan.

The electrical graph remains the accepted `src/boot/sm7675-uke-lights.dtsi`.

Percentage requests now use Nabu's upward scaling convention, implemented in
the kernel: `(percent * max_brightness + 99) / 100`. Every integer 1–100 is
remembered. With the admitted scale 2, requests 1–50 select 10 mA total and
51–100 select 20 mA total. The Nabu reference uses a 255 software scale and a
200 mA single-channel DT ceiling; neither is evidence for 100 physical current
steps or permission to raise Uke's current. No software PWM is added.

The existing RGB UAPI already encodes three 8-bit channels as `0xRRGGBB` and a
separate 0–100 brightness request. The updated broker also exposes a bounded
four-unsigned-integer D-Bus method for decimal clients. Camera/battery priority,
exclusive writer, syscall allowlists and the 8/511 PWM ceiling remain intact.
The reviewed Uke OEM DT source is MiCode/kernel_devicetree commit
`94c84aeb9e517dbde546fc732033c184094c8e57`, including `qcom/pmxr2230.dtsi`.
The generic OEM node alone does not prove the fitted board's channel selection;
the retained FDT checks in `tests/light-dt.sh` remain required. The implementation
uses the upstream LED consumer, synchronous brightness and device-link APIs,
retaining the original QCOM flash driver's current programming.

The first isolated native check (COPR 11230969) compiled Control and its SELinux
policy, then correctly refused the module: a local variable named `current`
collided with the kernel's task macro. The variable is now `current_ua`. A fresh
check release is required; the failed build is not a module or hardware result.
