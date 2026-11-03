# USB and charging integration on the VRR base

18 October 2026. Source and host-test integration for Uke; no combined tablet
installation or physical acceptance is recorded here. The full Type-C/DP graph
remains incomplete and disabled. Original KDE packages remain unchanged.

Inputs are immutable project snapshots:

| Component | Revision |
|---|---|
| VRR/kernel parent | a774562e498317caf3e2aa5ed84db2813bef5b1a |
| Charging kernel | 301ecd7a3c9e0a4df85d66d7cb2a05e0f72f9d63 |
| USB kernel 2.2 | 406b0aad4570516bf4e48609df55512144e67a0f |
| Charging runtime | f5cd5b670d3eee42ff5fba743e8b67572be42dfa |
| USB runtime 2.2 | b1f8c20c95b5e4d7521ffb4ce459d49a3cc2a3c3 |
| Charging builder | c38c3ff51c72e2d4d16cac9cba2e7060850731f5 |
| USB builder 2.2 | e1b57bcf1fd8833dc8679b0d60dfc8d4082d8cce |

The kernel retains its CPUCP, PLL, display, touch-reset, watchdog and explicit
VRR opt-in changes. Frozen charging patches 0050/0051 become 0053/0054;
USB patches 0052–0059 become 0055–0062. File hashes are regenerated from the
ordered queues. Linux 7.2.10 has 62 patches at this integration checkpoint;
the separate 7.2.9 queue has 58 and has no new physical qualification.

Strict actual-source admission finds and corrects fixture defects: the protocol
extractor had selected a forward declaration instead of the decoder body; the
coordinator omitted its real request wrapper and did not exercise its generation
getter. The corrected storm case checks both local counters without describing
either as a remote attachment token. The QMP fixture now also checks its
RBR/HBR swing and pre-emphasis tables. Existing compiler selection is honored
by the QMP and UTMI fixtures. Warnings remain fatal. The integrated charger
patch also corrects one signed comparison and one indentation error; no wire
value or charging limit changes.

The actual request coordinator, decoder, DWC3 retry/generation, QMP table and
UTMI-resume fixtures pass on x86 GCC and AArch64 Clang. Original failures and
corrections are retained in the private lesson record. Preparing all ordered
patches and native display patches from the official 7.2.10 source succeeds;
the existing AVR, metadata, watchdog budget, shutdown and panel fixtures pass.
These are source/host results, not successful USB roles, charging protection,
SuperSpeed, DP link training or physical VRR cadence.

USB observation and automatic admission perform no power-supply GET. Modern
automatic ACM requires a real device-role provider and Type-C partner; no
SDP/CDP polling fallback or invented model-admission marker is supplied. The
fixed peripheral producer retains guarded legacy ACM. Boot and root ownership
API 2 must be reviewed as one matched deployment before installation.

The charging lifecycle retains the existing bounded USB2 SDP budget and blocks
other Uke setters. Desynchronization is not cleared by PDR/resume/reload. The
model and safety profiles remain unqualified. Diagnostics do not admit power
queries or certify limits. Remaining work includes full kernel/RPM validation,
matching root and rollback audit, the patched original UPower host fixture,
coordinated PC-USB observation, and physical display/lifecycle tests. F5 testing
requires evidence-derived limits, protection ownership and a present operator;
none is inferred from these host tests.

## Full-build follow-up

18 October 2026: COPR 11166008 compiles the combined kernel until the battery
provider uses an undeclared devm_device_add_groups call. Three getter snapshot
locals are also unused. Release 21 adds patch 0064, uses the supported managed
single-group API, retains registration failure handling and removes those
unused locals. The generation helper remains in coordinated power sampling
and SDP validation. The 7.2.10/7.2.9 queues now contain 64/59 patches. Strict
coordinator/protocol fixtures and checkpatch pass; a complete translation-unit
and package rebuild are required. This correction changes no wire value,
charging limit, attribute permission, actuator or USB ownership contract.

The complete qcom_battmgr translation unit passes AArch64 Clang 23.1.3 Kbuild
with KCFLAGS=-Werror using the recorded release-18 configuration. The two
actual-source request/protocol contracts also pass. This is a host object
compile; the complete release-21 boot/package build and tablet admission remain
open. The 7.2.9 queue update has not been separately built.
