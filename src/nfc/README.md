# Uke NFC tag and infrared integration

27 October 2026. Source: Linux 7.3 Uke native profile. Host fixtures and ARM64
object checks are separate from tablet acceptance.

FM19511 is an I2C NFC tag. It does not provide an NCI reader or card-emulation
controller. The native overlay leaves it disabled; the existing exact `ukepgl`
identity initcall enables it only for POCO Pad X1. The driver independently
checks Uke/SM7675 and the POCO model before obtaining its supply or using I2C.
The shared backlight I2C bus, OEM tag address, 3.3 V supply and GPIO170 falling
IRQ are retained from the exact Uke source.

The driver publishes root-only `/dev/fm-ntag`. Read/write transactions are
bounded to 256 bytes; one file may be open at a time. `poll()` reports RF events
and faults. Unbinding preserves open-file state until release and returns
`ENODEV` for further transfers. Probe checks/updates volatile configuration,
checks readback and attempts restoration on error. It does not automatically
write EEPROM/NDEF, reset the chip, log payloads or expose private tag data.
Explicit root writes through the transport can change tag data and are not
part of the passive acceptance check.

The IR emitter uses the OEM QUP0 SE1 engine and pinctrl data with the upstream
`ir-spi-led` encoder and LIRC interface. The supply is optional because the OEM
emitter has no driver-controlled regulator. A supplied `power-supply` is still
enabled/disabled around transmission; deferred or failed providers are not
ignored. Carrier, pulse encoding and error handling remain upstream behavior.

Attribution: [MiCode Uke kernel](https://github.com/MiCode/Xiaomi_Kernel_OpenSource/tree/5712080a4b0c0b1a879e6d145c601c649ddaddfd),
`drivers/ntag/fm19511/` and `drivers/media/rc/ir-spi.c`; [MiCode Uke DT](https://github.com/MiCode/kernel_devicetree/blob/94c84aeb9e517dbde546fc732033c184094c8e57/qcom/uke-sm8635.dtsi).
The current upstream IR source retains Samsung/Andi Shyti attribution. The
new tag implementation credits the reviewed Linux Foundation/MiCode protocol.

Host checks:

```sh
bash tests/identity-contract.sh
bash tests/fm19511-contract.sh
bash tests/hardware-dt.sh
bash tests/ir-spi-contract.sh PREPARED_KERNEL/drivers/media/rc/ir-spi.c
bash tests/nfc-syntax.sh PREPARED_KERNEL PREPARED_ARM64_OUTPUT
```

Physical acceptance requires the matched kernel/modules and rollback route,
the actual POCO SKU, a bound tag with the expected root-only device, an external
phone/tag-reader RF interaction, observed IRQ/poll events and bounded transport
results without dumping payloads. NDEF writes are a separate explicit action.
IR requires an observed optical signal and receiver response; a LIRC node or
successful host encoder test is not an optical result. Neither physical result
has been established by this source change.
