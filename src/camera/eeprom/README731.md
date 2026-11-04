# Read-only EEPROM voltage ownership

4 November 2026. Native execution is pending in COPR. This prerequisite does
not activate an EEPROM, identify a fitted module or consume calibration.

Exact Uke camera DT requests front EEPROM VIO at 1.8 V, while the shared L20B
provider starts at 1.62 V. Original Linux at24 enables its supply without a
voltage request. An explicit optional vcc-microvolt consumer property avoids
changing the shared provider's global constraints or inventing a fixed supply.

The option requires read-only and a real vcc-supply. It votes before enable,
serializes reads through releasing its own enable reference, then withdraws
the voltage request. Other shared-rail consumers may still keep VCC powered.
Failed withdrawal retains the request and blocks later I/O. In-flight
reads refuse forced power-off. The opted-in NVMEM provider has no write callback;
the ordinary at24 configurations keep their existing power path. The read
wrapper rejects overflow and invalid ranges before power or bus operations.

The source fixture imports actual old/new reads and PM callbacks. It requires
the old unvoted-read failure and checks ordering, bounds/configuration errors,
rail/PM/I2C failures, legacy behavior and concurrent reads with synthetic bytes.
The OS and regulator boundaries are modeled. Complete AArch64 object/kernel
checks and physical voltage, bus, privacy and calibration acceptance are separate.

The remote worker uses pinned Fedora dt-schema 2026.09-1.fc46 to validate the
binding's meta-schema. This upstream Python build tool has no equivalent Bash
validator and runs only in COPR; it is not a tablet or runtime dependency.

The producer pins Linux 7.3.1 source and preserves the complete qualified 1900
cohort, builtin CAMCC and rear CCI correction. Both cameras, calibrated processing,
rear autofocus, full modes and recovery remain required.
