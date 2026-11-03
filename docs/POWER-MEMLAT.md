# Uke native memory-latency sampling

3 November 2026. The complete AArch64 kernel and package checks passed in
[COPR build 11251037](https://copr.fedorainfracloud.org/coprs/mcc45tr/uke-linux-unstable/build/11251037/)
at 7.3.1-1300.fc46. The actual configuration, linked built-in probe and OF match
passed inspection. Physical qualification remains pending. This adds the
missing LLCC/L3 sampling policy to the existing CPUFreq, thermal, CPU/LLCC
BWMON and DDR BWMON implementation.

The exact Uke `cliffs.dtsi` at MiCode/kernel_devicetree commit
`94c84aeb9e517dbde546fc732033c184094c8e57` defines seven sampling monitors for
LLCC and L3. Their CPU lists, compute-monitor flags and CPU/memory ceiling maps
remain in the inherited DT. The native fixup runs after CPU BWMON admission,
reuses its validated LLCC/L3 endpoints and active-only tag, and changes only
the MEMLAT root compatible and interconnect properties. Disabled or absent
MEMLAT nodes remain disabled or absent.

`src/power/uke-memlat.c` reads pinned ARM PMU events for instructions, cycles,
L3 refill and L2 refill (`0x08`, `0x11`, `0x37`, `0x17`). The inherited OEM
algorithm selects a map ceiling for memory-bound samples with at most 400
instructions per miss, or for the compute monitor. Independent interconnect
requests aggregate with existing clients; the driver does not write clocks,
voltage, thermal ceilings or CPUCP configuration.

The 8 ms delayed work is deferrable and freezable. Unscheduled, multiplexed,
reset, idle, implausible and overlong samples do not produce synthetic votes.
The consumer is built into the matched kernel and uses its public `idle_cpu`
scheduler declaration. CPUs observed as idle are skipped before perf reads, which can otherwise send
remote IPIs. Their next active interval starts with a fresh counter baseline.
This admission is a scheduler snapshot, not a physical no-wakeup guarantee.
Hotplug releases counters without refusing CPU online operations. Suspend
stops work, releases this driver's votes and disables counters; a failed vote
release aborts suspend and resumes sampling. Resume starts fresh baselines.
The read-only `sampling` attribute reports sample rejection, vote errors and
this driver's last successfully applied requests, not measured memory clocks.

DDR's OEM per-CPU LLCC read event is a separate counter provider. Its wrap/rate
qualification remains open, so this candidate does not silently substitute a
different PMU event or enable that counter as a policy input. DDR BWMON remains
the native DDR policy. OEM DDRQOS, full OEM adaptive tuning and measured idle/
suspend efficiency parity remain open. The GET-only CPUCP observer is retained.

The algorithm attribution is MiCode Uke kernel
`5712080a4b0c0b1a879e6d145c601c649ddaddfd`,
`drivers/soc/qcom/dcvs/memlat.c`, under GPL-2.0-only. The matching OnePlus
SM7675 source at `fc892483f1d61f245924681eb5abd563564d9cba` uses the same
sampling/ceiling approach and Android-specific infrastructure. Native upstream
perf, CPU hotplug, workqueue, PM and ICC APIs replace that infrastructure;
upstream passive devfreq maps frequency directly and does not replace this
instruction/miss qualification.

Remote checks execute the actual policy and FDT code with sanitizers, including
counter resets, scheduling gaps, ratio/ceiling boundaries, malformed graphs,
disabled nodes, retained maps and repeat application. Package checks inspect
the compiled configuration, linked built-in probe and OF match. These checks do not
establish energy savings, real PMU scheduling, idle residency or suspend success.
Physical acceptance requires the new kernel, counter/vote observations under
load and idle, and a recoverable suspend/resume trial.

## Adaptive L3 capacity admission

3 November 2026. A running 1500 kernel repeatedly returns ERANGE for adaptive
L3 requests, while lower map requests succeed. The inherited OEM ceiling map
can exceed the fitted provider's admitted range. This does not establish the
cause of desktop pauses previously observed with kernel 1011.

The proposed correction handles only the adaptive L3 consumer's ERANGE.
It tries strictly descending, distinct positive entries from the validated
OEM L3 maps and caches the first admitted mapped request. Later requests above
that ceiling use it without retrying unsupported values. A different provider
lifetime starts with an unknown ceiling. This does not change the strict L3
provider or the separate paired BWMON contract. Other I/O errors and complete
refusal remain errors, and suspend still aborts if releasing votes fails.

The existing `sampling` prefix remains. Additional fields report
`l3_requested_khz`, `l3_ceiling_khz`, `l3_range_rejections` and
`l3_limited_votes`. The ceiling is an admitted OEM map request, not measured
clock telemetry or a complete firmware-LUT maximum. The original maps,
voltages, clocks, CPUCP ownership, LLCC policy and electrical limits are retained.

Actual-function fixtures require an old-source failure, multiple synthetic
capacities, duplicate/non-L3 row isolation, repeated-request call bounds,
transport and release failures, suspend/resume and complete cleanup. Native
kernel/RPM qualification and physical effectiveness remain pending.

The retained-source composition computes `native_config_sha256` from the actual
`native-profile/native.config` input and names that scope explicitly. It also
records the exact retained parent. The separately packaged effective kernel
configuration can be normalized by Kconfig and has its own artifact identity;
the input digest must not be used as an unqualified effective-config digest.

4 November2026. [Build11251976](https://copr.fedorainfracloud.org/coprs/mcc45tr/uke-linux-unstable/build/11251976/)
passed the complete retained kernel1800 build and published all six AArch64
packages. Its old-source negative case and corrected ordinary/sanitized L3
lifecycle checks passed. The qualified source is merged into main and retained
by the1900 candidate. This establishes source/package qualification; fitted
counter behavior, vote effectiveness and physical idle/suspend parity remain
separate acceptance gates.
