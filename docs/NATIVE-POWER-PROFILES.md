# Native Uke platform profiles

22 October 2026. Scope: source candidate, host refusal/rollback fixtures and
ARM64 object compilation. No package delivery or tablet profile qualification
is established by this record.

The candidate exposes Uke preferences through Linux's existing platform-profile
API. Original Power Profiles daemon 0.30 reads its legacy
`/sys/firmware/acpi/platform_profile[_choices]` files. The shared kernel core
currently rejects DT boots when ACPI is disabled. This candidate creates only
that compatibility namespace on a populated DT boot, without enabling ACPI,
installing tables or changing firmware identity. Original ACPI boots retain
their existing kobject with a balanced reference.

The `uke-qos` provider admits only Uke/SM7675, eight possible CPUs, three
`qcom-cpufreq-hw` policies and the native Adreno identity. Missing CPU/GPU
providers defer probing. Profile writes require `schedutil` CPU governors and
refuse a conflicting GPU minimum. CPU preferences use hardware LUT bounds;
GPU preferences retain the existing 500/950 MHz policy and require those OPPs.
The 500 MHz preference still needs energy and latency qualification. No OPP,
voltage, thermal trip or charging policy is changed.

Each preference has its own QoS request. Tighter thermal requests remain
authoritative. Failed transitions restore the previous requested values rather
than adopting a thermally clamped readback. Incomplete restoration reports
`custom`; a later complete transition can recover the profile state. External
CPU governor changes also report `custom` and block profile writes.

The built-in handoff ABI is read-only: module `version` is `1`, and
`parameters/probe_status` is `0` while pending, `1` only after successful
registration, or `-1` after a permanent probe failure. State changes emit a
platform device event. A compatible legacy backend defers while pending,
declines when ready and retains its original behavior on previous kernels
or permanent native failure. Unknown ABI versions defer rather than compete.
The boot package conditionally requires that compatible backend when one is
installed. It does not install or remove the backend itself.

Before retiring `uke-power-profile-backend`, install the compatible handoff
release, select balanced and verify all three governors. Boot the matched
candidate and test the distribution daemon against the actual native
interface, including all profiles, thermal-clamped restoration and
suspend/resume. Remove the backend through DNF only after that handoff passes.
Retain its signed RPM and matched previous boot/module cohort; reinstall it
before returning to a kernel without the native provider. Manual provider
rebinding after a permanent failure also requires a balanced handoff and daemon
restart. This source does not obsolete the working backend.

The Linux API comparison uses upstream `4056b3c9`, Uke OEM kernel `5712080a`
frequency-QoS handling and the exact original PPD 0.30 archive
`90f2c95024861d9f4062abedd514084939224e7a49edd468f001af7260ec8e6c`.
The [14 October DT discussion](https://lkml.iu.edu/2610.1/15192.html) documents
the shared-core limitation; its laptop EC policy and thermal values are not
portable to Uke and are not used here.
