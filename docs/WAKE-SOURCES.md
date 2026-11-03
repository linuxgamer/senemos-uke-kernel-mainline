# Uke wake sources

22 October 2026. Kernel `7.2.12-11` is a source candidate based on the installed
`7.2.12-10` audio-service candidate. It adds only `wakeup-source` to the exact
Uke PMK8550 volume-down node before device creation. The native PMIC driver
owns IRQ wake; the key code, interrupt, reset behavior and firmware are retained.

The comparison uses Uke OEM DT `94c84aeb9e517dbde546fc732033c184094c8e57`,
`qcom/pmk8550.dtsi` and `qcom/kalama-pmk8550.dtsi`; the same PMK8550 node in
OnePlus SM7675 DT `1138e00fee63582a0cc6a53af3286621786827b7`; and upstream
`4056b3c9d3c92ea45955641dbafeb9b960e146ef`,
`drivers/input/misc/pm8941-pwrkey.c`. The existing driver admits the standard
DT wake property and uses its own suspend/resume IRQ handling. No donor GPIO,
IRQ or power value is transplanted. The Uke helper rejects a different node,
compatible, key code or interrupt contract.

`uke-control wake set volume-down on|off` can manage the resulting standard
permission after a qualified boot. Source fixtures establish property admission
and preservation; they do not establish a physical key wake. Preserve at least
one verified recovery key. USB permission is shared across attachment/removal;
independent charge events and double-tap touch wake remain unimplemented or
unqualified. Native profile, RTC and power-key observations do not qualify those
other events.
