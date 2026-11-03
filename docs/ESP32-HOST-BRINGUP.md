# Uke ESP32 USB host prerequisites

The Core debug profile expects the tablet to host an ESP32-S3 HID/CDC device.
The stock-derived USB2 peripheral candidate cannot provide that connection.
The [host source receipt](../manifests/esp32-host-readiness.json) pins the OEM
files and records each unresolved dependency separately.

The Uke OEM DT supplies twelve PM7550BA repeater host tuning pairs, differing
from the peripheral sequence. Its driver also forces the 19.2 MHz clock through
bit 6 at offsets `0xe8` and `0xed`, then clears that workaround in device mode.
The reviewed mainline profile currently rejects host mode. Removing that gate
alone would omit role propagation, the host sequence and transition cleanup.

The OEM controller sets the legacy PHY host flag before runtime resume and
notifies the WCD USB route before starting xHCI. WCD consumes the UCSI data role
and selects role-specific equalizer parameters. The pinned public OEM driver
does not initialize its host bandwidth member from the published DT property;
this source discrepancy is not evidence about the installed Android module.
Keep explicit, checked parameter parsing in a future Uke implementation.

The stock graph routes Type-C through `PMIC_RTR_ADSP_APPS` and
`msm/adsp/charger_pd`. Linux already has PMIC GLINK and UCSI implementations,
but the Uke remote processor, matching firmware, channel and connector graph
have not been qualified. No direct VBUS GPIO or regulator has been proved.
The existing USB2/UFS source slice requests no downloadable DSP firmware;
the proposed host power/role backend may add that dependency. Stock firmware
retention alone does not prove the ADSP charger service survives a new handoff.

Before admitting host mode, establish the actual Type-C power source, implement
checked PHY/repeater/WCD ordering and rollback, and verify host-to-device cleanup.
Then test cable power direction and ESP32 HID/CDC enumeration on the matched
device. Source, package and QEMU keyboard results do not satisfy those gates.
