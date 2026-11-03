# Uke Linux 7.2.11 adaptation

**20 October 2026, release 12 source:** patch 0084 connects PRM basic firmware
errors to the existing request/release error path and handles token-matched APM
readiness errors. It validates APM basic payloads before parsing and preserves
the specific-response requirement after a successful ACK. Actual-source host
fixtures and AArch64 objects are separate from package, firmware and physical
acceptance. The native audio profile remains disabled.

Patch 0085 preserves unmap firmware status and the data/position buffer token.
Only a successful reply clears the selected mapping. Source fixtures cover
success, rejection, missing graph, allocation/send failure and timeout. DMA
recovery in callers and stale graph-token reuse retain separate limits.

The 20 October source continuation adds patches 0086–0092: PRM transaction
matching, graph response bounds, dynamic GPR callback draining, receive queue
ownership, a sleepable compressed-state lock, complete 128 KiB token lengths
and validated buffer submissions/completions. GCC/Clang fault fixtures and
AArch64 objects pass. Static service/PDR and full DMA/stream recovery remain
unqualified. Audio stays disabled and no physical result is promoted.

18 October 2026: carry the complete 77-patch Uke queue from 7.2.10-30 onto
signed Linux 7.2.11. The native profile also preserves an explicit charger boot
through standard bootconfig and an initramfs switch-root wrapper. Build, package,
normal tablet boot and physical offline charging are separate validation gates.

**18 October 2026, release 10 source:** patch 0050 retains the OEM shared RX
mapping for the exact Uke CPUCP resources. Release 8 failed to reserve that
aperture because qcom-cpufreq-hw already owns its second page. Modern CPUCP
keeps its reserving mapping; Uke TX remains reserved. Extracted-function tests
cover refusal and mapping failures. A matched tablet boot and firmware response
remain separate acceptance steps; vendor SCMI protocol 0x80 is not implemented.

**18 October 2026:** the 47-patch source package includes the native display
profile, standard PMIC ADC units and signed battery power. Patch 0047 preserves
SMP2P input history on ordinary notifications. A physical trace on 7.2.10-4
shows unchanged ADSP ready/handover bits replayed on sleep-state updates; the
extracted-function regression fails before the patch and passes afterward.
The restart handshake and reset on both genuine restart edges are preserved.
This source check does not establish tablet acceptance of release 5.

The following paragraph records the original adaptation baseline; subsequent
native-profile packages have separate build and tablet evidence in the README.

The 40 patches carry the reviewed 7.2.9 adaptation, including the experimental
Adreno 732 catalog and NoC graph, onto the signed upstream 7.2.10 source. Every
patch retains its source attribution and manifest hash. No generic ARM64 fallback
or foreign-device firmware is admitted.

The additional patches connect firmware-display metadata, correct unbound
Adreno removal and preserve SM7675 EPSS operating points for the single-core
Prime domain. The stock-ABL GPU overlay separately supplies nine SM7675
frequency/corner/bandwidth points. Native DPU/DSI work remains an isolated
candidate under `src/display/`; it is not enabled by this release series.

Own-device graphics results remain from the 7.2.9 RAM experiment. A clean source
application, build, signed package check and matched 7.2.10 tablet boot are separate
acceptance steps. Early GPU probing, full DVFS, thermal limits and suspend remain
open; the independent Uke DTS and stock-ABL handoff are different boot paths.

Patches 0065 and 0066 add the separately selected full Uke Type-C profile:
firmware-owned roles, one generic eUSB2 PHY, exact WCD 2.0 routing, QMP analog
supplies/GDSC and checked PHY restoration. The native source producer supplies
the associated full USB/DisplayPort graph; adding dormant driver matches alone
is not device support. No new hardware acceptance follows from these patches.

The7.2.11-3 candidate adds patches0078/0079: an offline fixed existing-band
application probe and the separately reviewed AudioReach response/readiness
changes. The native audio profile remains disabled. No battery bypass, physical
charge-stop, speaker or microphone acceptance is established by these sources.

The 7.2.11-6 candidate adds patch 0080: cumulative hardware-timestamped GPU
execution time for a separate native desktop sensor plugin. Reads do not wake
hardware or change governor sampling. This prepares monitoring for platform
Adreno hardware without modifying original KDE applications or proc security.
Device and desktop presentation acceptance are separate from source/build checks.

**19 October 2026, release 7 source:** patch 0081 adds read-only cached SCMI
implemented_protocols. Failed, truncated, excessive and incomplete discovery
remain errors; a valid empty list is distinct. Reads issue no firmware request.
Internal consumer matching is preserved. This admits no vendor algorithm or
performance policy. Native compile, package and tablet results remain separate.

Release 8 also validates the four-byte discovery header before reading the
returned count. A zero-byte response cannot qualify as an empty list. The
regression fails on release 7 source and passes after the correction; normal
consumer matching and base initialization behavior remain unchanged.

**20 October 2026, release 10 source:** patch 0082 adds fixed moisture status,
an offline enable-only detector request, fresh moisture/three-thermistor guards
and a qualified wet-input latch using the exact retained OS3.0.304.0 input-suspend
contract. Version-2 leases require independent external thermal ranges. The boot
ADC graph supplies those fixed consumers and periodic thermal updates without
changing OEM trips. Unknown or ambiguous outcomes do not release the latch.
No raw XM selector, pack defaults or new JEITA/CV/PD writer is exposed.
Host fixtures and an AArch64 driver object are separate from full package,
matched boot and physical moisture/electrical acceptance.

**20 October 2026, release 15 source candidate:** patches 0095–0097 add the
four-bank/v5 Cliffs7 LLCC policy, five-window binding and managed Adreno supplier
ordering. Native source preparation selects the admitted private-DT conversion.
The first 94 patch hashes and existing charging, thermal and recovery policies
are preserved. Host source checks do not qualify cache coherency, supplier
lifetime, recovery after partial programming, suspend or a performance gain.
