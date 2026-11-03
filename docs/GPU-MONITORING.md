# GPU execution accounting — 19 October 2026

Environment: POCO Pad X1, Fedora Rawhide AArch64 and original KDE 6.8.
Kernel 7.2.11-6 prepares a read-only counter for a separate native desktop
sensor plugin. Source and compile checks do not establish tablet acceptance.

The original KSystemStats Linux GPU backend enumerates PCI devices. The Adreno
732 is a platform device; a missing GPU graph does not imply software rendering.
MSM DRM fdinfo already exports per-client hardware-timestamped execution time,
but privileged compositor process metadata is not generally readable by the
desktop user. No proc permission, executable capability or device identity is
changed to work around that boundary.

Patch 0080 accumulates the same completed-submit nanoseconds across clients in
an atomic counter. The devfreq device exports it as:

```text
/sys/class/devfreq/<Adreno device>/gpu_engine_ns
```

The file is mode 0444. Reading it does not wake the GPU, sample registers,
consume the governor's accounting interval or change frequency, power or
firmware state. There is no additional timer or worker. The counter starts at
GPU initialization, survives runtime suspension and retains work from closed
clients. The attribute is removed during GPU cleanup before private data is
cleared. Normal KWin metadata protection remains intact.

Clients compute a delta against monotonic elapsed time. The first sample and
counter reset are unavailable. These are completed-work durations, with the
same limitations as DRM engine accounting: a long in-flight job can appear
when retired, and overlapping/preempted intervals can require a 100% display
ceiling. This is distinct from instantaneous shader occupancy or power.

An earlier cached-devfreq-percentage draft was compiled but withdrawn before
publication: governors that do not poll would leave that sample stale. The
cumulative counter has no governor dependency. No board addresses, OPPs or
calibration values are copied from a donor.

The actual reader fixture checks missing-device handling, zero/full-width
values, repeated reads and absence of hardware sampling. AArch64 compilation
checks both accounting and sysfs translation units. Own-device idle/load,
all power profiles, sleep continuity and original KDE presentation remain
separate acceptance checks.
