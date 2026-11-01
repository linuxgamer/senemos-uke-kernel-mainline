# Qualcomm USB role and system-sleep serialization

Source review dated 1 November 2026. Baseline: the complete Linux 7.3.1-116
native source from COPR 11239905, SRPM SHA256
e376800a58f3d1b91e89b5f88b678da950e74157035db7944edbf306cc7f822c.
This is a source candidate without Uke physical acceptance.

The first isolated candidate 1005 completed COPR 11240238. The current
producer retains qualified 1006 from COPR 11240463, source
fcbdae4b757732f0f0e3162c610f19abae290832, SRPM SHA256
70f151855f727c9d83c3bedc35ff52dd60cb222b2d741818472dced458bcd60c.
That cohort already retains the installed 1003 display changes and the later
LMH-ready correction. Candidate 1020 adds the same USB patch and model without
dropping those inputs. Whole-setting comparison and a missing-field negative
case supplement the original file-byte retention checks. A new complete COPR
build and physical qualification remain required.

The role notifier can run outside the freezer while system sleep has stopped
the glue clocks. Runtime-PM success then does not establish that QSCRATCH is
accessible. The existing Uke adaptation has no system-sleep exclusion around
that notifier. The correction adapts
[Vladyslav Tymoshchuk's 22 October v2 proposal](https://lkml.iu.edu/hypermail/linux/kernel/2610.2/17332.html)
for the shared Qualcomm DWC3 implementation. Its reported SM8750 result is
reference-device evidence. OEM vendor MSM/extcon and the pinned OnePlus,
Palawan/Lamma and Peridot sources remain comparison inputs with different
integration contracts.

The patch holds one mutex across the role notifier and both complete system
sleep callbacks. Suspended requests retain the latest override and apply it
after glue and core resume. Resume errors propagate. Uke's next-role VBUS
rule, legacy compatible behavior, no-op requests and runtime-PM failure
handling are preserved. No board values, power limits or role defaults change.

The COPR-only contract compiles the three actual source functions against
modeled PM/MMIO facilities. The retained baseline must reproduce a clock-off
write. The candidate must defer it, preserve the final override after gadget
resume, hold the lock at all core/glue boundaries, retain role truth tables
and propagate injected errors. This does not model electrical hardware.

The isolated producer retains every original archive except its native
profile and fresh-release specification. All 122 adaptation patches,
four-channel audio, release-116 power changes, native configuration and boot
recipe bytes remain unchanged. It applies the USB correction last and repeats
the contract against the source actually prepared for the complete kernel
build. Native checks and kernel compilation run only in COPR.

The continuing-session xHCI removal at monotonic 1058.524 seconds occurs long
after the recorded suspend attempt. This candidate does not establish its
cause or fix it by inference. Passive role, UCSI and host-removal capture
remains the next causal gate. Later source candidates, signed installation,
coordinated sleep/cable trials, storage safety and sustained physical USB
acceptance require their own exact identities and results.
