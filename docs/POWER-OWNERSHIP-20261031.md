# Uke clock ownership candidate

31 October 2026. POCO Pad X1, Fedora Rawhide AArch64, Linux 7.3.1-4 and
7.3.1-5 source comparison. Validation uses host fixtures and a private copy
of the running device tree. No new kernel is built or booted by this change.

The retained `qcom,cliffs-debugcc` node describes vendor clock measurement.
Its unbound device references six clock providers, including GCC, GPUCC and
DISPCC. These references can hold their supplier synchronization barriers.
Live sysfs confirms the six links, unsynchronized GCC/GPUCC and an active
GCC proxy vote; other unbound consumers remain possible barriers.
Native GPU runtime power uses GMU CX/GX domains; its two unused common-core
dummy regulator handles do not establish missing GPU power supplies.

The boot candidate sets the unused measurement node to `disabled` after
checking its exact compatible, clock names, provider tuples and exported
handle. It refuses incoming handle references, including unknown vendor
properties, and preserves absent, disabled and foreign trees. Device names,
thermal sensor identity and functional clock nodes remain intact.

MiCode Uke kernel `5712080a4b0c0b1a879e6d145c601c649ddaddfd` and OnePlus
SM7675 kernel `fc892483f1d61f245924681eb5abd563564d9cba` contain byte-identical
`drivers/clk/qcom/debugcc-cliffs.c`. Their GPL-2.0-only attribution is retained.
Uke DT `94c84aeb9e517dbde546fc732033c184094c8e57`, `qcom/cliffs.dtsi`, supplies
the six measurement references. Upstream Linux v7.3.1 has no equivalent to
the project's `CLK_HOLD_STATE` and `clk_sync_state()` additions; those custom
handoff paths are part of the required review.

The actual helper passes sanitizer checks for eleven invalid graphs,
foreign/absent trees, repeated application and a private running-DT copy.
The source preparation installs and checks the helper; both affected source
manifests retain matching file hashes. This is source validation only.

The full host-side ABL transform also compiles as an AArch64 object with
GCC and `-Wall -Wextra -Werror`. This is not a kernel Kbuild or RPM result.

Removing this stale consumer can allow `clk_sync_state()` to drop startup
references and GCC's proxy voltage vote even while `clk_ignore_unused` is
present. A matched kernel, preserved rollback and measured boot/runtime/sleep
trial are required before deployment. Other unbound consumers and all three
ignore-unused workarounds still need separate ownership and physical checks.

## Isolated kernel candidate

Release 7.3.1-11 retains the exact release-9 microphone source RPM and its 122
adaptation patches, including native mono PCM constraints. Explicit
overlays add this clock candidate, the cpufreq boost-error rollback correction
and a signed `uke-cpucp-observe` module. PM debug messages are enabled for the
trial; all ignore-unused settings and existing thermal/charging limits remain.

The observer has no autoload alias or polling worker. Explicit module loading
admits only Uke/SM7675 on matching Linux 7.3.1 modules. It verifies the vendor
protocol version with an actual standard VERSION transfer, then permits only
MEMLAT timestamp/raw-frequency GETs and the exact C1DCVS enable GET. Fixed-size
replies retain an overlength sentinel; malformed/error replies leave output
unknown. No firmware configuration, start/stop or raw command interface exists.

The internal SCMI descriptor disables automatic negotiation for this observer.
Qualcomm's legacy message 0x10 is SET, so an unsupported higher firmware version
must be rejected by strict read admission before the core can negotiate it.
Existing standard protocol descriptors retain their negotiation behavior.
Release-7 source build 11234274 was canceled after this call-chain finding;
its emitted source RPM consumes that NVR and was not installed or loaded.

The candidate is intended for the separate
`uke-linux-test:custom:power-20261031` COPR directory, Rawhide AArch64 only.
The ordinary package producer and repository remain separate. The earlier
release-8 power-only build passed kernel, package and signature checks. The
combined release-10 build and physical validation remain pending. Published
release identities 7, 8 and 9 are preserved.
