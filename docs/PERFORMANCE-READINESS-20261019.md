# Pressure accounting — 19 October 2026

Environment: POCO Pad X1, Fedora Rawhide AArch64, Linux7.2.11-4 and original
systemd262. The installed native profile disables CONFIG_PSI. Consequently
/proc/pressure is absent and the original systemd-oomd service is skipped by
its ConditionPathExists=/proc/pressure/memory check.

Release5 enables the existing upstream PSI accounting with its normal default
active state. The package build verifies both resulting configuration values.
This supplies CPU, memory and I/O pressure interfaces and their cgroup-v2
counterparts. It retains original Fedora OOM policy, swap and desktop packages;
no custom memory killer, reclaim limit or background sampler is installed.

Upstream7.2.11 init/Kconfig and Documentation/accounting/psi.rst define this
interface. No board values or donor driver code are copied. Kernel.org lists
7.2.11, released15October, as current stable at this review.

The observed kernel4 interval has no direct reclaim, allocation or compaction
stalls and no THP fault fallback. No THP, cache, governor, idle-state or swap
policy change is justified by that result. PSI adds observability; this source
change does not establish reduced scrolling latency or hardware success.

Remaining validation: native build/package checks, signed matched delivery,
post-boot pressure interfaces, original OOM service readiness and quiet resource
overhead. Physical responsiveness and sustained memory-pressure qualification
remain separate from interface availability.
