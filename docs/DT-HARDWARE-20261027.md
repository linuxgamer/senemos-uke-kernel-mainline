# Uke DT identity and hardware descriptions

27 October 2026. Linux 7.3 source candidate; inspected against the retained
7.3.0-17 POCO Pad X1 FDT. Current tablet installation and physical NFC/IR
acceptance remain pending.

| Item | Source behavior | Limit |
|---|---|---|
| Processor | Exact `Qualcomm Snapdragon 7+ Gen 3` in DT and Uke cpuinfo product fields | Core MIDR, revisions, topology and frequency reporting remain hardware-derived |
| Board | Preserve exact scalar SKU selection of POCO Pad X1 versus Xiaomi Pad 7 | Unknown/conflicting metadata does not enable POCO-only NFC |
| RAM | `LPDDR5X` model from both official product specifications | No invented DRAM manufacturer, part number or fixed capacity |
| Pen / keyboard | Xiaomi Focus Pen/Keyboard by default; POCO Focus Pen/Keyboard for the admitted POCO SKU | Presentation profile, not attachment or protocol acceptance |
| Sensors | Nine ADSP/SSC-owned descriptions with datatype and explicit model candidates | No fabricated direct I2C/SPI nodes, addresses, IRQs, calibration or identity claim |
| Fingerprint | Disable/remove the unused Uke fingerprint template | Pro-device references are unchanged |
| NFC | POCO-only FM19511 tag transport, root-only bounded I/O and event polling | No reader/emulation claim or automatic EEPROM/NDEF programming |
| Infrared | OEM SE1 route with upstream `ir-spi-led` / LIRC and optional power supply | Optical output and receiver acceptance remain open |
| Camera / audio names | Correct functional labels and existing chip families | Unknown camera/actuator/codec silicon suffixes are not guessed |
| Cleanup | Remove unreferenced old panel catalogue entries and unused Goodix/MP-test descriptions | Unknown references/aliases keep their target; firmware/RAM/calibration and shared providers remain protected |

[POCO specifications](https://www.po.co/global/product/poco-pad-x1/specs/) and
[Xiaomi Pad 7 specifications](https://www.mi.com/ae-en/product/xiaomi-pad-7/specs/)
identify LPDDR5X and IR. The requested `POCO Focus Keyboard` label is a
presentation alias for the product sold as POCO Pad X1 Floating Keyboard.
Accessory presence remains unknown until actual discovery.

The native Control hardware snapshot consumes the firmware sensor/accessory
descriptions, exposes identity fields and inventories the FM19511 misc and
LIRC endpoints without opening them. Configuration never establishes physical
support. SSC discovery continues to identify actual sensors and SUIDs.

The retained candidate graph passes the pin/provider audit: 178 TLMM groups,
96 wake mappings, 574 provider specifications, zero invalid muxes, pin
references, provider properties or GPIO specifications. NFC actual-function
fixtures cover 44 transport faults and four readback faults; IR actual-function
fixtures exercise optional/failed supplies, 38 kHz encoding, carrier limits and
cleanup. Native SKU and cpuinfo tests preserve other-device behavior. ARM64
object compilation and schema validation are independent host results, not
tablet boot or radio/optical acceptance.

The full native host candidate contains 4,211 nodes and 951 compatible-bearing
nodes, compared with 4,319/942 in the earlier capture. Added service and sensor
descriptions and removed templates explain the different counts; these are not
physical-device counts. Packed FDT size falls from 998,298 to 627,919 bytes
(37.1%). Memory regions, boot reservations, existing firmware descriptions and
pinctrl provider properties are byte-compared across the hardware-name/cleanup
transform. Unknown phandle references, nested references and aliases retain
their targets. The native overlay passes seven refusal/nonmutation cases.

`make validate`, the native C++ hardware backend build and its focused fixtures
pass. Clang ASan/UBSan runs the actual tag/IR functions. Linux olddefconfig
retains `FM19511_UKE=m`, `IR_SPI=m`, `RC_CORE=m`, `RC_DEVICES=y` and `LIRC=y`;
LIRC is required for the IR module to survive configuration resolution.

The source profile is intended for a distinct candidate release. Preserve the
existing matched delivery and verified rollback; do not combine its Image with
modules from another kernel release. The original OEM sources and captures
remain retained as evidence.
