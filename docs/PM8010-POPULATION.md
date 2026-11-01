# Optional PM8010 population on Uke

31 October 2026, POCO Pad X1, Fedora Rawhide AArch64. Normal DNF installation
and reboot to Linux 7.3.1-4 in slot B passed. The inherited PM8010 N probe
is skipped with an explicit firmware-population message, and its earlier
SPMI transaction warning is absent. The same six working PMIC bindings and
51 thermal zone registrations remain. Signed package identities, all 821
module digests, running Image notes/build ID and native GPT/UFS admission
pass; A/7.3.1-3 remains intact as the accepted rollback image.

On 7.3.1-3, the inherited node at SID 0x0d failed its revision read at 0x104.
The firmware PMIC inventory does not advertise model 65 (PM8010), the command DB
has no PM8010 N regulator resources, and the exact OEM camera profile uses
other suppliers. The other six declared primary-bus PMIC devices bind.
These observations identify a selected-profile population mismatch; DT names
alone do not establish the physical chip inventory.

The correction checks only the exact Uke PM8010 N node before transport
access. A bounded and complete SMEM inventory without PM8010, together with
a ready command DB without any ldon1 through ldon7 resource, returns an
unpopulated-device result. Populated variants, another board or another
node keep ordinary probing. Missing, malformed and deferred metadata are
errors, never evidence of absence. The change does not alter generic SPMI
errors, fabricate a revision, remove a thermal declaration or write a
power/reset register.

The source owner retains the original Linux Foundation/Qualcomm MFD
attribution. Uke OEM kernel `5712080a`, DT `94c84aeb` and camera DT
`57d2135e` were compared with the pinned OnePlus SM7675 and Palawan/Lamma
references and current upstream. Reference-board PM8010 regulator wiring
is not copied. The recent upstream PM8010 I2C frontend is a separate bus
implementation.

Release 7.3.1-4 retains the verified 7.3.1-3 native profile and its exact
122-patch adaptation. The actual native helper fixtures cover population,
all seven resource alternatives, foreign nodes, deferred firmware and
malformed boundaries. The kernel WARN taint bit clears; CPU_OUT_OF_SPEC
and the initial-console warning remain. A later automatic suspend attempt
still fails with Device or resource busy. This test establishes the probe
correction for the tested firmware profile, not physical chip population,
PM8010 thermal accuracy, protection behavior or forced fallback.
