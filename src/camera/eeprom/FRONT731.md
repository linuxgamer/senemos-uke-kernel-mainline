# Front GENI and read-only EEPROM admission

4 November 2026. COPR-only source candidate for POCO Pad X1, SM7675.

Exact MiCode kernel_devicetree94c84aeb and camera-devicetree57d2135 place
the front bus on GENI SE8 at 0x880000, IRQ373, GCC clock86 and GPI1 engine0.
Native GENI requires a different compatible, clock name and three-argument
DMA routes. Existing wrapper/GPI/ICC providers and GPIO0/1 electrical settings
are retained. The late admission follows the general QUP quarantine; the
sensor and overlapping SPI/I3C personalities remain disabled.

The OEM EEPROM at address0x51 requests L20B at1.8V. The native at24 profile
uses 8K/16-bit addressing, read-only root access and an explicit voltage
request. Its provider retains the shared1.62..3.544V constraints; only the
exact ldob20 RPMh resource is added. The existing initial HPM provider setting
is retained. The generic at24 compatible is a protocol/family description,
not a fitted manufacturer/model or calibration-layout identification.
Renaming the node preserves its phandle and updates its public symbol path.

Tests use the actual conversion, actual general QUP quarantine and actual
before/after regulator allowlist with synthetic graphs. Refusal cases check
that invalid wiring is rejected before mutation. Allocation failures may
modify the private output FDT; the boot caller discards that copy on failure.
The full boot transform is a stock-preimage operation, not a general
idempotent transformation of an already converted tree. The front helper's
idempotence is tested separately.

Binding can cause an initial one-byte EEPROM read. Firmware protocol/GPI
availability, actual voltage, fitted contents/checksums and electrical
operation still require private read-only tablet measurements. This source
does not activate sensors, capture, calibration processing or rear focus.
Both complete cameras remain the acceptance goal.
