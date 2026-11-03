# Uke CPU scheduling and hotplug

Historical Linux 7.2.12 candidate record. The active main branch now uses the Linux 7.3 build rules; merging this record does not enable these candidate configuration changes.

24 October 2026. Target: POCO Pad X1 / SM7675, Fedora Rawhide 46.
The running `7.2.12-31` kernel and the source candidate below are different
test environments. No CPU was taken offline and no new kernel was installed.

## Running tablet

All eight CPUs are online: three Cortex-A520, four Cortex-A720 and one
Cortex-X4. Their scheduler capacities are 385, 874 and 1024 respectively.
All three policies use `qcom-cpufreq-hw` with `schedutil`. Energy-aware
scheduling reports enabled; AMU is detected on all eight CPUs. PSCI domain
idle is registered and idle counters advance. These observations do not
qualify energy consumption or suspend/resume.

`CONFIG_HOTPLUG_CPU=y` and the standard `cpuN/online` controls already exist.
The candidate preserves them. An automatic core-parking service is not part
of this change. Normal scheduler idle management remains available on online
CPUs; hotplug is a separate maintenance or measurement operation.

## Source candidate

| Support | Candidate behavior | Tablet acceptance |
|---|---|---|
| CPU hotplug | Retained and checked after Kconfig resolution | Interface observed; offline/online cycles pending |
| EAS, AMU, schedutil | Existing upstream support retained | Providers and enabled state observed; efficiency unqualified |
| Task and cgroup uclamp | Enabled for explicit userspace performance hints | Pending candidate boot and API checks |
| Menu and TEO idle governors | Both built; upstream menu rating 20 remains above TEO rating 19 | Menu observed; TEO comparison pending |
| Scheduler statistics | Built; upstream runtime static key starts disabled | Pending candidate boot and explicit measurement |

The changes apply to the native profile and the Uke configuration fragment.
The existing build contract now rejects a resolved native configuration that
loses these controls. Existing `PREEMPT`, thermal controls, clock limits,
boost setting, topology and power-profile defaults are retained.

Uclamp follows upstream semantics, including the existing upstream RT-task
defaults. No application or cgroup hint is assigned by this project. A
uclamp limit is a scheduling hint, not a hard frequency or CPU-time guarantee.
See [upstream uclamp documentation](https://docs.kernel.org/scheduler/sched-util-clamp.html).

`sched_ext` is not included in this candidate. The current size-reduced profile
uses `DEBUG_INFO_NONE`; SCX requires BTF and a separately selected userspace
scheduler. Adding it needs its own build, size and scheduler validation.
See [upstream sched_ext requirements](https://docs.kernel.org/scheduler/sched-ext.html).

## Verification and later use

The candidate passed Linux 7.2.12 `olddefconfig` and AArch64 compilation of
`kernel/sched/{fair,core,stats}.o` and `drivers/cpuidle/governors/teo.o` with
Clang 23.1.2. The resolved configuration passed the native build contract.
Five negative configurations were rejected: missing hotplug, task uclamp,
cgroup uclamp, TEO or scheduler statistics. This is source/object evidence,
not a complete kernel package or candidate tablet result.

Read the controls before a coordinated hotplug trial:

```sh
cat /sys/devices/system/cpu/{possible,present,online,offline}
cat /sys/devices/system/cpu/cpu7/online
cat /sys/devices/system/cpu/cpuidle/{available_governors,current_governor}
cat /proc/sys/kernel/sched_energy_aware
```

Use the [upstream CPU hotplug interface](https://docs.kernel.org/core-api/cpu_hotplug.html)
for a later bounded secondary-CPU offline/online trial. Preserve CPU0, an
independent recovery path and the original online mask. Test one secondary
CPU first, then verify its return, cpufreq policies, interrupts, desktop and
kernel journal. Offline/online and suspend/resume are separate acceptance
tests. Do not infer a battery benefit from fewer online CPUs.

After the candidate is booted, compare `menu` and `teo` through
`/sys/devices/system/cpu/cpuidle/current_governor` and restore the original
value after measurement. Enable `kernel.sched_schedstats` only for a bounded
measurement and restore its initial value. Compare idle residency, wakeup
latency, frame latency, throughput, temperature and measured power under the
same workload before changing defaults.

## Current limitations

Signed Fedora stress-ng 0.22.01 and its native dependencies were extracted
into temporary RAM storage. No test package was installed. Short per-core
CPU-method runs with result verification passed on CPUs 0–6. During CPU7's
run, the maximum sampled thermal-zone value reached 74.9 °C; the 65 °C guard
terminated that workload. CPU7 and the planned eight-worker run are therefore
not accepted. No result mismatch was reported before termination. The next
read-only sample was below 38 °C and no stress-ng process remained. This was
not a controlled thermal benchmark or an endurance test.

The boot journal also contains an XNX feature-register variation and an LLCC
resource warning despite a bound LLCC driver. These remain separate source
investigations; no feature mask, cache programming or warning suppression is
included here. `CONFIG_KVM=y` does not establish virtualization: this boot
reports `HYP mode not available`.
