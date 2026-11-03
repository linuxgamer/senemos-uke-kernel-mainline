# Deferred framebuffer ownership

30 October 2026, Fedora Rawhide AArch64 source candidate: release 58 retains
the exact source inputs from successful COPR build 11229645. Its overlay keeps
old scanout pins until an actual flush and a following video boundary, or a
proved command/writeback completion. Cleanup storage belongs to the existing
old CRTC state. Allocation and scheduling failure cannot fall back to an
immediate unpin.

Writeback timeout retains the queued DRM job and destination pin until
WB_DONE or successful CTL teardown. Prepared geometry belongs to each job;
it cannot replace an earlier queued destination. Cloned writeback completion
does not count as a video vblank. Hardware errors quarantine ownership until
reboot; a cleared software counter is not completion evidence.

The source worker compares twelve parent files and runs the actual ownership,
timer-tail, writeback, kickoff and proof functions with failure controls.
Complete native preparation repeats the byte comparison and fixtures. Native
COPR results, signed package verification and device activation are pending.
This candidate does not qualify physical scanout, reset behavior, endurance,
hot-unplug with active userspace or the cause of historical SMMU faults.

The problem and vblank-work direction were discussed in the
[Qualcomm v5 proposal](https://patchew.org/linux/20261024-fd-kms-fix-smmu-v5-0-a5b0b284aead@oss.qualcomm.com/).
The overlay preserves existing Uke modes and introduces no board timing,
address, firmware or device-tree value. Exact source composition is included
in the generated native profile.
