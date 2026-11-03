# Internal speaker path, 26 October 2026

The later [27 October test candidate](AUDIO-POLISH-20261027.md) adds runtime
fault containment and desktop policy delivery. Its integrated package is a
separate artifact; the physical result below is not transferred to it.

Tested device: Xiaomi Pad 7 (SM7675, board name "uke"; the configured sound card
name is `POCO-Pad-X1`), Fedora Rawhide AArch64, Linux 7.3.0, native boot image
release 20, `speakers` audio profile.

**Result: all four internal speakers play on the Xiaomi Pad 7.** All four
amplifiers probe, their PLLs lock, the DSP consumes a four-channel S16_LE stream
at 48 kHz, each speaker was played individually, and desktop playback works
through ALSA UCM and PipeWire. Not tested: HDMI audio on this card revision,
sample widths above 16 bit, speaker calibration, microphones, suspend, thermal
behavior at high volume.

## Evidence

- OEM device tree: four `fs19xx_smartpa` nodes at 0x34-0x37 on QUP1 SE3
  (`i2c@88c000`, SDA gpio44, SCL gpio45), reset gpios 30/149/124/123.
- OEM preset `fs19xx.fsm` (stock odm image): valid CRC, four devices, positions
  top-left 0x34, top-right 0x35, bottom-left 0x36, bottom-right 0x37.
- Stock backend configuration: `TDM-LPAIF_VA-RX-PRIMARY`, 4 channels, 32 bit,
  48 kHz, slot mask 15.
- Stock ACDB graph `a2000001` (metadata only): TDM sink module `0x0700100E`,
  LPAIF type 3, index 0, four 32-bit slots, lane mask 2, sync source 1, data
  delay 1, data out enabled. The DSP algorithm module in that graph is not used:
  the OEM FS19xx driver sets `nondsp_mode`, i.e. the amplifier protects itself.
- OEM LPASS pins: `lpi_tdm1_*` = gpio6 SCK, gpio7 WS, gpio8 SD0, gpio9 SD1,
  function 2, which is `i2s1_clk/ws/data/data` in the SM8650 LPI table.

Donors: MiCode `vendor_qcom_opensource_audio-kernel` `uke-v-oss`
(`8eb0eccb`, FourSemi GPL driver) for register sequences and preset layout;
AudioReach graphservices `76d04ffb` (BSD-3-Clause) for graph metadata formats.
No preset, tuning or calibration data is stored in this repository.

## Changes

| Area | Change |
|---|---|
| `patches/7.3.0/0115` | `fs19xx` ASoC/I2C driver. Active-low reset held while idle, OEM start sequence, DAC muted until the amplifier reports PLL lock, output switch default off, digital volume capped at the OEM uncalibrated limit (0xDF, -12 dB). Preset parsed with size, CRC and bounds checks. A missing preset leaves the card usable and the speaker disabled. |
| `patches/7.3.0/0116` | AudioReach legacy TDM sink/source (`0x0700100E/F`): interface config `0x0800101B`, lane mask `0x0800106A`, endpoint format `0x08001017`, clock attributes `0x0800113C`, plus the topology token loader. |
| `src/audio/uke-audio-card.c` | `xiaomi,uke-speaker-audio-card`: HDMI and four-amplifier TDM backends in one card, fixed 48 kHz / 4 ch / S16_LE back end inside 4 x 32-bit slots. |
| `src/audio/POCO-Pad-X1.conf` | HDMI graph unchanged plus `MultiMedia2` (4 ch) to the TDM sink behind `SECONDARY_TDM_RX_0 Audio Mixer`. |
| `src/audio/sm7675-uke-speaker-audio.dtsi` | Amplifier bus and nodes, LPASS LPI pinctrl for gpio6-9, two-link card. |
| `src/display/uke-abl-native.h` | Publishes symbols and phandles for the four unlabeled OEM amplifiers before the overlay applies. |
| `configs/uke.config` | `SND_SOC_FS19XX=m`, `PINCTRL_SM8650_LPASS_LPI=m`. |
| `packaging/native` | New `speakers` profile (now selected); `hdmi-only` remains selectable. |

## Results

Host (no device): the 117 patches apply to Linux 7.3, `prepare.sh` completes for
the `speakers` profile, and the FDT, topology, FS19xx parser (ASan and UBSan) and
TDM encoder contract tests pass. `make validate` (including
`mainline-package-contract.sh`) passes in the project's Fedora Rawhide aarch64
build container. `unstable-package-contract.sh` was not run.

Tablet:

- All four amplifiers answer with id 0x2900, revision 0x00A2; preset positions
  0x8/0x2/0x4/0x1 match the device-tree prefixes.
- With the speaker switch off the amplifiers stay in reset. With it on, the PLL
  reports lock (`STATUS` bit 1) and the output is unmuted only after that.
- The OEM `reset-gpio` and the overlay's `reset-gpios` name the same GPIO, which
  made gpiolib put the line behind a shared-GPIO proxy and held amplifier 0x35 in
  reset. The native entry now removes the OEM property, and a missing amplifier no
  longer removes the card.
- The DSP stops returning buffers when the TDM back end is wider than the front
  end. A 16-bit back end inside the 4 x 32-bit TDM frame works; 24-bit works with
  an MFC module in the chain (not wired up yet); a 32-bit back end does not.
- Channel order, measured on the tablet in landscape: slot 0 top-left, slot 1
  top-right, slot 2 bottom-left, slot 3 bottom-right.

## Remaining work

- Package the amplifier preset (`/lib/firmware/qcom/uke/audio/fs19xx.fsm`) with
  the firmware component. It is vendor data from the stock odm image and is not
  stored in this repository.
- Add the MFC chain for sample widths above 16 bit.
- Speaker calibration (no Re25 data; volume stays capped at -12 dB).
- Ship the ALSA UCM profile and PipeWire configuration; both are local files on
  the test tablet.
- Re-test HDMI audio, suspend and thermal behavior.
