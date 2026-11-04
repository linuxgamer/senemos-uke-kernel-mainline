# CAMCC clock voltage callback integration

3 November 2026, Linux 7.3.1. This extends the inactive controller
[resource owner](OWNER731.md). No native provider is registered or camera DT
activated by this source candidate.

The catalog retains 44 OEM voltage policies, but its five native operation
families do not connect those policies to the ported voltage helpers.
The new callback layer connects prepare/unprepare and pre/post-rate operations,
preserving native PLL calibration and all unrelated clock metadata/callbacks.
It also gates enable/disable and rate/parent programming against controller
power and fault state. Parent/rate/enable/calibration errors latch the original
failure; subsequent operations stop and controller resources remain held.

Clock preparation votes before native calibration. Generic callbacks already
present are not invoked twice. Unprepare checks the regulator-unvote return
directly instead of discarding it through the generic void helper. The ported
CCF ignores post-rate callback errors, so the owner also retains these errors
independently. A higher voltage vote survives a failed operation; partial
multi-rail rollback is treated as uncertain rather than retried.

Only the five catalog operation families are admitted. Every entry is checked
before any init pointer is replaced. Sparse slots, names, parent metadata,
flags and unrelated callbacks are preserved. Clean metadata initialization can
repeat before publication; an active, published or corrupt state cannot rewire
registered clocks. These tables have permanent built-in storage.

The native fixture imports actual ported VDD and clock voltage functions. Its
before-control models the real Rivian operation family, which has no prepare
callback, and must fail the required voltage-vote assertion. Candidate tests
cover all five families, an already-wired generic-hook variant, single/shared
rails, increasing/decreasing/stopped rates, callback failures, voltage errors,
and resource retention through failed-probe core cleanup. The complete catalog
and callbacks must also compile as an AArch64 kernel object using the real
candidate layout.

[COPR build 11247758](https://copr.fedorainfracloud.org/coprs/build/11247758)
passes on Fedora Rawhide AArch64, 3 November 2026, with tested source
88c60fdce55784fd8fa97d07cdb55435022e875f and kernel ABI 7.3.1-1018.
The missing-vote before-control fails with expected exit 134. Candidate clock
and retained owner/GDSC fixtures pass normally and under fail-fast ASan/UBSan.
The complete kernel compiles in 1,140 seconds with four jobs; boot preparation
takes 1,216 seconds and package checks take 56 seconds. The complete catalog,
power, owner and new clock callbacks compile against the real kernel layout
as an AArch64 object; Image is unchanged and the object is not installed.
Six existing binary package names are emitted in the isolated side repository.
Full binary delivery verification, device installation and physical operation
are not claimed. ABI 1018 is reserved; changed inputs need a fresh ABI.

This is a clock-callback prerequisite. A complete provider must still own its
clock/reset/domain registration storage, wire PM/publication/removal/shutdown,
and qualify firmware/proxy handoff. Native void-disable callbacks and CCF
rate-error reporting have separate observation limits; preserving a fault is
not proof of electrical shutdown or consumer-visible rate-call failure.
The RCG registration/parking path, exact camera graph, fitted sensor identity,
concurrency, capture and physical recovery remain unqualified. No physical
camera operation is performed by these tests.
