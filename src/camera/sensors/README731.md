# Native sensor prerequisites on Linux 7.3.1

3 November 2026. This candidate builds the original Linux OV08D10 and OV13B10
modules through the existing COPR kernel package family. It preserves the
retained kernel's other source inputs and enables the two modules in the
manifest-verified boot configuration. No camera sensor DT node is activated.

The OV13B10 binding/OF patches are retained from project source
bd8475eda093723b540a14dc72b8c16770de30e0. Original Linux/Intel copyrights and
ACPI matching remain. The OV08D10 debug fix follows Max Bretschneider's
24 October v2 patch 1/4, linked in its patch, against the actual stable
Linux 7.3.1 preimage. The probe has not assigned the current mode when the
hardware-description debug message runs; use the parsed lane count.

The worker imports the actual before/after hardware-description function.
The before-control must reproduce the NULL access with debugging enabled;
the candidate must pass valid, absent, malformed and reordered endpoint cases
normally and with fail-fast ASan/UBSan. Complete kernel/module packaging and
actual AArch64 objects, OF/ACPI aliases, ABI and signatures are checked too.
These tests do not perform I2C, sensor power or capture operations.

Full implementation still requires the native CAMCC provider and graph,
fitted chip/address/lane and EEPROM identity, private read-only calibration,
rear actuator/focus, image processing, complete supported modes and physical
capture/recovery acceptance for both cameras. KDE and GNOME packages remain
original distribution packages. Installable device qualification is separate
from this sensor prerequisite build; no copied-binary deployment is used.
