# Uke standard charging-control source — 18 October 2026

Environment: isolated source work based on joint kernel
`f429992feb638e7dffc0142ecb77c6b1a86fc16e`. No patch-application check, compiler,
fixture, package, boot, firmware query or hardware operation was run here.

`patches/7.2.10/0067-uke-battmgr-qualified-control.patch` adds Uke-only standard
power-supply thresholds and optional positive constant-current control. Both
new EXPERT options default to n; no build configuration enables them. The new
patch follows 0064 in this isolated queue; the coordinator owns composition with
USB-owned 0065/0066 and any later queue. No USB, DT, PHY or display file changed.

The exact local OEM pin is MiCode uke-v-oss
`5712080a4b0c0b1a879e6d145c601c649ddaddfd`,
`drivers/power/supply/qti_battery_charger.c` (GPL-2.0-only, The Linux Foundation /
Qualcomm Innovation Center). Unlike ambiguous thermal wire10, the distinct
`BATT_CONSTANT_CURRENT` wire12 has a `CONSTANT_CHARGE_CURRENT` SET route through
`battery_psy_set_fcc()`. The wrapper returns zero regardless of its callee error;
this backend requires transport/remote success and exact GET readback. Its
positive-uA semantics still require active firmware/pack evidence. No negative
or UINT_MAX reset sentinel is exposed. EN/start/end use wire25/26/27; opcode0x48
carries target/delta. An opaque ACK never qualifies an applied target.

Compared same-SoC OnePlus `fc892483f1d61f245924681eb5abd563564d9cba` (same file),
shared-protocol Peridot `2ed9eadbecae21ef51134e556951e7305ba65f88` and local Linux
snapshot `4056b3c9d3c92ea45955641dbafeb9b960e146ef` (`qcom_battmgr.c`). Existing
upstream/shared files retain Linaro/Qualcomm attribution. No board-specific
limits, thermal tables or donor scripts were copied or executed. The workspace
SM7675 inventory and donor policy remain applicable. This is not a claim about
an unqueried current upstream HEAD.

The typed auxiliary-device admission ABI is documented inside the patch at
`Documentation/ABI/testing/sysfs-driver-qcom-battmgr-uke-control`. It binds root
permission to a referenced TGID, profile digest, exact local driver/firmware/source
epochs, reviewed time and <=30 second CLOCK_BOOTTIME lease. Suspend/PDR invalidates
older reviews. The companion native helper verifies per-boot artifact evidence;
the kernel does not authenticate a remote firmware identity or inspect a proof
file. Root is the evidence admission authority.

Threshold and current SETs use fresh health/presence/V/I/T/source guards, the
existing request mutex and mandatory firmware readback. Current has separate
profile/band/source-budget admission. It never writes voltage or negotiates
PD/QC/PPS/EPR. Firmware owns CV and autonomous charging protections. A USB budget
is not a battery FCC limit; no conversion or numerical Uke limit is invented.
Readback does not prove physical effect. Lease expiry cannot electrically cut
charging or undo the last firmware setting.

Original KDE uses standard `charge_control_start_threshold` /
`charge_control_end_threshold`. Standard getters expose only verified caches
under an admitted standard-client lease, otherwise ENODATA. The two KDE writes
are independently guarded and can partially apply; the native pair API does not
claim remote atomicity either. No KDE package is forked or rebuilt. Desktop
service activation can restore saved thresholds and needs a separate admitted
stage. The native observer's property allowlist/D-Bus remains read-only.

Deferred coordinator checks:

1. Compose exact sources; inspect patch application and compile options both
   off and on against the selected kernel. Preserve stock firmware, Android A,
   Linux boot_b, matched modules and rollback artifacts.
2. Run existing battery protocol/coordinator/readiness fixtures and new
   `bash tests/battery-control-transport.sh PREPARED_KERNEL`. The latter enables
   only synthetic host admission, exercises actual request/RX functions and
   checks denied raw/zero/reset writes, lifecycle invalidation, exact/invalid
   ACK envelopes and no replay. It does not exercise all sysfs/profile logic.
3. Run companion runtime fake-I/O/profile fixtures, original desktop integration
   and package/activation checks. Add focused fault injection for guard/GET/SET
   ordering and each failure boundary before permitting controls.
4. Use the central staged PC-USB/VRR plan; qualify exact active firmware, units,
   source budget, protections, readback and physical effects before adapters.
   No F5 high-power qualification or hardware-risk closure follows from source.

## Read-only threshold diagnosis — release 29 candidate

The installed firmware has not yet supplied a threshold readback. A new explicit
root-only `uke_charge_settings` attribute reads the existing three standard OEM
threshold fields without requesting control admission. Existing status and
admission remain metadata-only, and standard getters remain unavailable without
their original admitted-client lease. All SET/current/voltage restrictions remain.

This is a bounded diagnostic, not battery protection or bypass. It refuses an
unexpired control lease or busy driver, uses three fixed GETs, stops on error or
lifecycle change and emits no partial result. It does not renew a verified cache,
create a lease, choose pack limits, activate a service or issue FCC/XM/PD commands.
The actual helper and root sysfs wrapper pass synthetic off/on permission, lease,
rate, response and lifecycle fixtures. Complete driver compilation, signed
packaging and offline-power tablet readback remain separate validation stages.

## Preconfigured-cap candidate — release 30

On18 October, POCO Pad X1 / Fedora Rawhide AArch64 boots signed release29
(COPR11168479) normally; physical display/touch are confirmed. Original KDE
retains VRRAlways without intervention. A single deliberate query with PD input
off reports enabled=false, restart70 and stop80. It performs no SET or admission.

Release30 adds a separate root-only permission to enable that existing70/80
band while external input is absent. It does not invent pack limits or promote
the general threshold/current profile. Exact Uke OEM5712080 and same-SoC
OnePlusfc892483 charge_control_en_store use independent standard property25
boolean SET; target/delta configuration is a different command. Only property25
value1 is possible in this synchronous scope. The shared/upstream comparisons
above do not provide a Uke battery-bypass contract.

Fresh fixed GETs require the exact70/80 band, battery presence/Good health,
input off, healthy unchanged lifecycle and no active/recent admitted control.
The request mutex serializes the whole operation. Mandatory same-epoch readback
must report enabled70/80 within five seconds; an uncertain attempted write is
quarantined for the driver instance without replay or rollback. Already enabled
configuration needs no SET. No target, FCC, voltage, disable, XM or PD command
is added. General controls retain their existing independent admission.

Actual helper/wrapper and coordinator fixtures pass on the development host
with options off/on. Complete AArch64 compilation, COPR delivery, physical
current response and reboot persistence remain pending. Configuration readback
cannot establish charge stop, battery isolation, bypass or all fault protection.
No automatic service or persisted intent is introduced by this candidate.

## Existing-band application, Linux 7.2.11-3 candidate

The exact Uke OEM5712080 `battery_psy_set_charge_threshold` at lines2445–2465
sends opcode0x48 with enable/target/delta after feature permission. Same-SoC
OnePlusfc892483 uses the same split. Current upstream7.2.11 already defines
the target request; its generic Uke control path remains independently gated.
Feature25 activation and unchanged settings alone do not demonstrate target
application. On installed7.2.11-1, the band remains enabled after normal reboot,
but a subsequent powered observation reaches reported80% with positive battery
current. Physical cutoff and battery bypass remain unqualified.

Patch0078 adds a root-only, input-off, fixed one-shot request for the already
enabled70/80 band. Fresh same-epoch settings, presence/Good health, no active or
recent general control and a five-second guard precede the literal opcode0x48
`{enable1,target80,delta10}`. Arbitrary targets, disable/current/CV/XM/PD and
input-suspend operations are absent. The existing general lease stays closed.

The OEM receiver completes this opcode on an opaque reply without a documented
result payload. This probe records only a bounded, correlated request receipt;
it does not invent a qualified generic ACK length or decode success. Mandatory
same-epoch settings readback cannot resolve actuator outcome. Both fixed writers
remain quarantined after an attempt, including a receipt/readback completion.
No retry, undo, persisted intent, service or bypass capability is added.
Actual functions and transport fixtures cover fixed arguments, wrong owner/type,
malformed/late/foreign replies, lifecycle changes, all GET/request failure
positions, offline/health/ownership and repeated-writer refusal. Synthetic reply
sizes are host fixtures, never observed firmware formats. Physical current
response and autonomous termination still require a separate controlled test.
