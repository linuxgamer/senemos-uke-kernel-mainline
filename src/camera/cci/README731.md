# Native Uke CCI prerequisite

4 November 2026. Source review; native fixture execution is pending in COPR.
No CCI DT node, sensor or EEPROM is activated by this patch.

Exact Uke camera DT at57d2135 selects CCI0 master1 for the rear module.
Linux7.3.1 at79a9076 initializes completions only for available child nodes,
but controller reset and its IRQ always use master0. Initialize every supported
master before IRQ registration so a master1-only graph can reset safely.
Keep adapter enumeration, timing and master selection unchanged.

The fixture imports the actual old/new probe and unchanged reset/IRQ bodies.
Its Linux, completion and MMIO boundaries are modeled. It requires the old
master1-only path to fail at completion initialization and checks corrected
topologies, the single-master variant and retained cleanup errors. Complete
AArch64 object/kernel/package checks and physical CCI qualification are separate.

The exact stable source SHA-256 is
45b2dc46ea637f411a39f9352156e91d85a191b4fd3d2bfb44d5b7fc81d57693.
The reviewed newer upstream CCI file differs and must not stand in for it.
Its dynamic clock selection is absent from7.3.1. Stable v2 timing fields match
the exact Cliffs37500000Hz OEM tables; actual assigned clock rate, domain,
IRQ, pinctrl, fitted identity and bus ownership remain activation requirements.
