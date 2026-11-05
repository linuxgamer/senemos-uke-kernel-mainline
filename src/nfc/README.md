# Uke NFC tag and infrared integration

5 November 2026. On POCO Pad X1 with Fedora Rawhide AArch64 and
`7.3.1-12101-unstable`, a regular-user `ir-ctl` raw-send request completes
successfully through `/dev/lirc0`, bound to `ir-spi-led`. The single diagnostic
frame requests a 100-microsecond pulse, space and pulse. Carrier and duty
settings are unchanged. Post-request SPI counters show one transfer and
24 transmitted bytes, with no error or timeout. This verifies the native
userspace/LIRC/SPI path; waveform, optical output and receiver response remain
unmeasured.

5 November 2026. On POCO Pad X1 with Fedora Rawhide AArch64,
`7.3.1-11003-unstable` and native client `1.1.0-2`, the regular-user INFO
query reports ABI1 and a bounded one-byte I2C read at the existing OEM probe
address succeeds through the memory-read ioctl. Response shape and length
are checked without retaining or publishing the byte. No EEPROM write or
RF exchange is performed. External RF/wake and IR optical
acceptance remain open; this transport result does not establish them.

3 November 2026. Linux 7.3.1 source candidate. Compilation runs only in COPR;
source checks, linked packages and physical acceptance are separate results.

FM19511 is an I2C NFC tag. It does not provide an NCI reader or card-emulation
controller. The native overlay leaves it disabled; the existing exact `ukepgl`
identity initcall enables it only for POCO Pad X1. The driver independently
checks Uke/SM7675 and the POCO model before obtaining its supply or using I2C.
The shared backlight I2C bus, OEM tag address, 3.3 V supply and GPIO170 falling
IRQ are retained from the exact Uke source.

The driver publishes `/dev/fm-ntag` with mode 0600 before distribution session
access rules. Reads are bounded to 256 bytes; one file may be open at a time. `poll()` reports RF events
and faults. Unbinding preserves open-file state until release and returns
`ENODEV` for further transfers. Probe checks/updates volatile configuration,
checks readback and attempts restoration on error. It does not automatically
write EEPROM/NDEF, reset the chip, log payloads or expose private tag data.
The raw write path now accepts only a two-byte address selector. Payload writes
return `EROFS`, preserving read-only EEPROM access. This deliberately removes
the older unrestricted raw writer. It does not change RF-side memory locks.

The fixed-size UAPI in `fm19511-uapi.h` adds `FM19511_IOC_INFO`,
`FM19511_IOC_EVENTS` and `FM19511_IOC_READ_MEMORY`. The latter performs one
serialized address/read operation, checks 16-bit address wrap and transfer size,
and zeros unused output. Events contain an IRQ sequence, the sequence at the
last completed status read, the last I2C error and three raw OEM IRQ bytes.
Reading events consumes the prior notification while retaining concurrent IRQs;
status completion produces a second notification. Undocumented bits are not
interpreted as decoded NFC messages. 32-bit compatibility uses identical UAPI
layouts. Wake IRQ ownership follows `wakeup-source` and standard `power/wakeup`;
system sleep blocks user I2C and cancels work while retaining tag power.

The IR emitter uses the OEM QUP0 SE1 engine and pinctrl data with the upstream
`ir-spi-led` encoder and LIRC interface. The supply is optional because the OEM
emitter has no driver-controlled regulator. A supplied `power-supply` is still
enabled/disabled around transmission; deferred or failed providers are not
ignored. `src/infrared/ir-spi-uke.c` retains upstream rc-core/LIRC and attribution.
It explicitly requests 16-bit SPI words, validates the default carrier and duty
cycle, quantizes cumulative edges without changing the input, appends an inactive
word, checks controller transfer/message limits and propagates power errors.
One complete frame is limited to one second and one SPI transfer; splitting it
could insert unbounded gaps. This is a transport bound, not an LED power rating.
Carrier is constrained by the SPI controller; electrical/optical limits remain
unmeasured. The exact OEM DT retains its 19.2 MHz SPI ceiling and SE1 routing.

The FM19511(A) [NFC Forum certificate 60249](https://nfc-forum.org/uploads/Certified-Products-Certificates/Shanghai-Fudan-Microelectronics-Group-Co.%2C-Ltd._FM19511%28A%29_Certificate_ID_60249.pdf)
identifies Type 2 Tag, not a reader.
The public Fudan catalog describes FM19510, a different part; its 408-byte
capacity must not be assigned to FM19511. No complete public FM19511 register
datasheet or exact Uke IR LED part datasheet was located. NDEF/EEPROM capacity,
UID programmability, RF boost control and power-off behavior remain unknown.
The driver therefore adds no guessed reader, HCE, P2P, SRAM mailbox or memory
writer. A typical NFC headphone exposes a passive pairing tag and needs a
reader; the tablet cannot read that tag. Bluetooth audio uses Bluetooth.
The Uke IR evidence describes an emitter, without a receiver/learning path.
The configuration enables upstream JVC, NEC, RC5, RC6, RCMM, Sanyo, Sharp and
Sony modules, which provide kernel encoders despite their `DECODER` Kconfig
names. XMP has no upstream encoder and is not advertised as a scancode sender;
applications can still supply appropriate raw pulse trains. Device-specific
remote button databases and Bluetooth pairing policy remain userspace data.

Attribution: [MiCode Uke kernel](https://github.com/MiCode/Xiaomi_Kernel_OpenSource/tree/5712080a4b0c0b1a879e6d145c601c649ddaddfd),
`drivers/ntag/fm19511/` and `drivers/media/rc/ir-spi.c`; [MiCode Uke DT](https://github.com/MiCode/kernel_devicetree/blob/94c84aeb9e517dbde546fc732033c184094c8e57/qcom/uke-sm8635.dtsi).
The upstream IR source retains Samsung/Andi Shyti attribution. The
new tag implementation credits the reviewed Linux Foundation/MiCode protocol.

COPR checks (never compile these fixtures on the tablet):

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
results without dumping payloads. EEPROM writes remain prohibited.
IR requires an observed optical signal and receiver response; a LIRC node or
successful host encoder test is not an optical result. Neither physical result
has been established by this source change.

The isolated full kernel candidate passed in [COPR build 11251492](https://copr.fedorainfracloud.org/coprs/mcc45tr/uke-linux-unstable/build/11251492/) at 7.3.1-1401. It used the reviewed source at `118ba4b` and produced the complete AArch64 kernel packages. The combined release 1600 producer retains the later SSC/Binder baseline and repeats the native tag/IR checks. Combined package results and actual RF/optical acceptance remain separate.
