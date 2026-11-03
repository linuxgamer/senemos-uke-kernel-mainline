# Isolated KVM and EL2 source

31 October 2026. Main integrates the KVM helper, admission, assembly, patch and
research sources without selecting an experimental entry in ordinary packages.
The retained `kvm` branch is the isolated package producer; its separate package
namespace, module ABI and no-activation policy are not replacements for main's
normal producer. Do not use main's `make srpm` as an EL2 build command.

`normal` preserves Linux entry. `el2-require` requires existing EL2 on every CPU
and parks on refusal; it cannot turn EL1 into EL2. The historically recorded EL1
handoff can therefore stop before Linux starts. `el2-exit-experimental` is refused
with status 78: there is no admitted Uke firmware-exit contract or allowlist.
The retained patch defaults both experimental Kconfig symbols off.

`packaging/kvm/binder.config` preserves the optional BinderFS configuration.
Main does not select it. Waydroid is a separate native-container integration,
not evidence of KVM support; no runtime, image or service is installed here.

`src/kvm/probe.cpp` is an explicitly invoked argument-free RAM guest probe.
It never runs during package installation. `src/kvm/status.cpp` is a read-only
inspector and never runs a guest. `tests/kvm-source-contract.sh` compiles both
and tests argument refusals; it does not run an AArch64 guest or inspect hardware.
The synthetic AArch64 ABI fixture is retained separately in
`tests/kvm-probe-abi.cpp` and requires matching AArch64 headers/toolchain.

Research attribution and qualification limits remain in
`manifests/el2-research-20261018.json`. Source compilation does not prove firmware,
all-CPU EL2 entry, guest operation, Waydroid or tablet acceptance. Installation or
activation requires separate authorization, a reviewed firmware identity and a
recovery route. Preserve stock early firmware; do not enable firmware exit.
