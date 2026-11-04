# GDSC registration cleanup on Linux 7.3.1

3 November 2026. This prerequisite follows the retained production kernel
7.3.1-1011 from COPR build 11246385. It changes only the common GDSC registration
error paths. Camera clocks, power sequencing, DT matches and camera nodes remain
at the parent profile.

Linux 7.3.1 and current upstream revision
`6628e7d4c6b25c8d18f1345e3a20d21829aae7e4` have the same `gdsc.c`.
Its multi-parent attachment helper unwinds failed links, but a later
initialization or provider-registration failure leaves initialized genpds.
The separate 23 October camera candidate already identified this defect;
its cleanup is rebased here without importing the controller-PM extension.
The initialized-domain unwind follows Konrad Dybcio's
[required-domain RFC, patch 12/16](https://lore.kernel.org/all/20261014-topic-qc_clk_dvfs-v1-12-3041b788e9f7@oss.qualcomm.com/).

The fault fixture imports the complete pinned GDSC source and header. It uses
seven parent topologies, including independent required domains, nested
domains, parent-selection precedence and mixed explicit/required parents.
Allocation, each initialization, every applicable parent-link position,
provider-registration failure and normal removal are exercised. The same
cleanup assertions must reproduce the unpatched leak. Candidate checks also
run with ASan/UBSan; the full native kernel build compiles the actual changed
GDSC object for AArch64.

`packaging/native/copr-gdsc731.sh` retains every parent source outside the
explicit profile overlay and spec changes. Native compilation and tests run
only in COPR. The intended qualification build uses an isolated side repository
in `mcc45tr/uke-linux-unstable`, separate from the device update repository.
Native COPR [11247515](https://copr.fedorainfracloud.org/coprs/build/11247515)
succeeds at source `1d253221adcae63a7cf703f676bd0d11ac2c4e0b`, producing
7.3.1-1013. The 91-case fixture passes in ordinary and ASan/UBSan runs; the
identical assertions reproduce the original leak with status 134. The tested
source matches the production source. The full kernel compiles in 1154 seconds,
the actual GDSC object is AArch64, and retained package checks pass in 56 seconds.
All six existing binary package names are produced. No camera activation,
device installation or tablet execution of this kernel occurred.

Release 1013 is now reserved. A changed build must use a fresh release;
documentation changes alone do not authorize rebuilding it.

Removing genpd objects does not establish electrical power recovery,
failed-probe resource ownership, camera firmware handoff or physical capture.
Those remain requirements for a future native camera provider.
