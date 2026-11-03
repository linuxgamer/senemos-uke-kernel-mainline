# SM7675 UFS bring-up

The PHY addition is source work for Linux 7.2.9. It does not yet make the
independent Uke DTB discover or operate the internal UFS device.

The complete eight-patch Linux 7.2.9 build passed on October 6, producing the
ARM64 Image, independent DTB, 1,146 modules and release `1.4.fc46` RPM/SRPM set.
The extracted payload, module ABI/dependencies, independent source preparation
and isolated AArch64 install/upgrade/removal gates passed. The
[build record](../reports/FIRST-CONSOLE-KERNEL-BUILD-2026-10-06.json) keeps this
local build evidence separate from native COPR and physical storage acceptance.

## Provenance and implementation

- OEM kernel: `MiCode/Xiaomi_Kernel_OpenSource`,
  `5712080a4b0c0b1a879e6d145c601c649ddaddfd`.
- OEM files: `drivers/phy/qualcomm/phy-qcom-ufs-qmp-v4-pineapple.{c,h}`.
  The driver's actual match table includes `qcom,ufs-phy-qmp-v4-cliffs`.
- OEM DT: `MiCode/vendor_qcom_opensource_devicetree`,
  `94c84aeb9e517dbde546fc732033c184094c8e57`,
  `qcom/cliffs.dtsi` and `qcom/cliffs-mtp.dtsi`, reached through the Uke
  `uke-sm8635` include chain.
- New mainline compatible: `qcom,sm7675-qmp-ufs-phy`, using current upstream
  QMP v6 offsets and helper sequencing. OEM naming alone is not a register-layout
  version test. SM8650 has different tuning and is not substituted.

`src/boot/check-ufs-tables.sh OEM_SOURCE KERNEL_SOURCE OUTPUT_DIRECTORY`
compiles an independent C++ address/value comparison. The effective writes match
79 addresses for each of Gear 4/5 and Rate A/B. The OEM power-down write is
excluded because the upstream helper owns that operation. A modified value is
also rejected. This tests tables; it does not test power or link sequencing.

The PHY has two lanes and three reviewed supplies: `vdda-phy`, `vdda-pll` and
`vdda-qref`. Board regulator and voltage declarations must accompany this
profile; merely supplying the compatible does not close its dependencies.

## Open board dependencies

| Dependency | Source evidence and remaining implementation |
|---|---|
| UFS PHY/controller MMIO | OEM `0x01d80000` / `0x01d84000`; device registers, never GPT offsets |
| Clocks and resets | Cliffs GCC has UFS clocks and BCR; DT parent links, reference clocks and power domains still need an admitted provider graph |
| Power domains | Scoped regulator facade now uses the GCC supplier's existing regmap for the reviewed USB/UFS offsets; runtime votes still need physical checks |
| NoC | Added OEM UFS master 48 and configuration slave 546, original graph links and BCM votes; OEM has no per-master UFS QoS box |
| Supplies | OEM PHY uses L1D/L4B/L2B; controller uses L12B/L3D and additional reference/parent votes; use Uke PMIC declarations and sequencing |
| Reset GPIO | OEM Uke path describes TLMM GPIO 178, active low; TLMM and its voltage rail are still disabled in the independent tree |
| DMA/SMMU | Primary boot compatible admits translated SID `0x60`; original USB core-compatible fallback retains firmware display handoff protection |
| Host controller | Source candidate uses the generic Qualcomm host's actual version read; ICE/MCQ omitted; physical quirks and link enumeration remain open |

The extracted Global OS3 package corroborates these register and reset
declarations. It has four base DTBs and one board overlay, and lacks bootloader
RAM fixups. It is not the dated installed Global OS2 profile. None of these
source findings proves runtime enumeration, LUN geometry or write safety.

## Stock-derived source candidates

The [source catalog](../manifests/first-console-sources.json) pins OEM,
community, Palawan and static firmware evidence separately. The source profile
adds patches 0009–0013 for UFS paths, scoped DMA/power admission, RPMh rollback
array sizing, shared GCC MMIO ownership and explicit USB role/PHY error gates.
Targeted AArch64 objects and four DT graph/rejection fixtures passed. The full
release `1.5` Image/modules/package build is recorded separately.

After `--inspect-stock` creates a bounded, hashed receipt, use the same host
entry to generate development DTB/DTS files:

```sh
./senemos.sh --prepare-boot-dt RECEIPT KERNEL_SOURCE OUTPUT
./senemos.sh --prepare-boot-dt RECEIPT KERNEL_SOURCE OUTPUT --usb2-peripheral
```

Input hashes include the original vendor_boot/DTBO and each merged DTB from
the receipt inventory. Existing output and foreign/corrupted receipts are
rejected. All four base alternatives are retained. The output is an ordinary
source overlay plus DTB/DTS candidates, not an Android DTBO image; selected
index is null and launchable/boot/hardware flags are false. RAM, UFS reset and
SID are checked against the input. No framebuffer or partition offsets are
invented. The independent packaged DTB is not silently replaced.

The USB2 option adapts the stock child layout to the v7 glue fwnode and is
explicitly **peripheral-only**. It cannot qualify the Core ESP32 host profile:
host PHY/repeater/WCD sequencing, VBUS control and real cable/firmware tests
remain required. Matching stock early/security firmware is retained; no Nabu
firmware binary or memory map is admitted.

## First console and storage gates

The Core builder adds a gated initramfs VT2 shell and ESP32 CDC journal writer so
debugging can begin before an EXT4 root mount. A valid Uke firmware RAM/FDT and
framebuffer handoff is still required, and physical ESP32 input additionally
requires the enabled USB host chain. Kernel configuration includes EFI/simple
framebuffer, fbcon and visible console options without a guessed framebuffer
address. UFS is needed later for root mount and internal storage testing.

Do not enable UFS solely because the PHY comparison or compilation passes. The
next steps are provider-graph implementation, schema/config/build checks,
read-only physical enumeration and logs, then a separate storage acceptance.
