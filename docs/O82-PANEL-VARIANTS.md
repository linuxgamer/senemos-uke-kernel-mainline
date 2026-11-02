# Uke O82 panel variants

2 November 2026. Source support selects `o82_36_02_0a` or `o82_42_02_0b`
from the bootloader's `msm_drm.dsi_display0` parameter before applying the
native DT overlay. One kernel embeds both overlays. Missing, unknown,
duplicated and conflicting parameters are rejected; an optional colon suffix
is accepted. RAM, reservations and the selected panel argument are preserved.

Both panels expose the OEM 30, 48, 50, 60, 90, 120 and 144 Hz modes, with
120 Hz preferred. They share the exact Uke DSC, link-clock, supply and reset
contracts. Their ON streams remain distinct: O82-36 sends 171 commands in
10 chunks / 1,448 padded bytes; O82-42 sends 108 commands in 8 chunks / 884
bytes. Per-command metadata, delays, batch limits and paired completion checks
remain enforced. The separate initial120 diagnostic stays O82-42-specific.

References: [issue 14](https://github.com/MCC45TR/uke-linux/issues/14),
[MiCode Uke display DT](https://github.com/MiCode/vendor_qcom_proprietary_display-devicetree/tree/4a3e1c391130237c5e8c2b250d1c94f3e25b9b11/display)
(`uke-sde-display.dtsi`, both O82 panel files and their common includes),
[Uke board DT](https://github.com/MiCode/kernel_devicetree/blob/94c84aeb9e517dbde546fc732033c184094c8e57/qcom/uke-sm8635.dtsi)
and kernel `5712080a4b0c0b1a879e6d145c601c649ddaddfd`.
Original Linux Foundation/Qualcomm GPL attribution is retained.

Targeted source fixtures pass for both suppliers: exact ON packets and chunk
failures, all seven modes and both links, 42 directed refresh transitions per
supplier, panel lifecycle and refusal paths, and compiled DT overlays with
the shared video, USB-C and speaker/microphone graph. The extra DSI admission
patch applies after the retained native display series on Linux v7.3 sources.
No full kernel/package build or O82-36 hardware test was performed. Issue 14
still needs a matched build and device retest; its only failure cause is not
established by a boot log.

## Other variant evidence

| Hardware or profile | Evidence | Current limit |
|---|---|---|
| NT36532 touch | Separate CSOT/Tianma normal-image hashes, CRC fields and OEM electrode maps | The O82-36 source profile selects Tianma; O82-42 selects CSOT. Firmware download/readback, gesture and contact paths share the bounded protocol. The CSOT high GPIO26 check remains; Tianma requires a valid existing input without assuming its polarity. Supplier association, resident metadata and physical input still need O82-36 testing. |
| Battery | Uke board DT has separate NVT/Sunwoda termination profiles, selected by OEM firmware pack identity | Standard Linux observation remains supplier-neutral. The observer reports bounded supplier hints from standard manufacturer/model strings; unknown/conflicting identities remain explicit. A hint never selects charging limits or establishes a gauge/charger IC. |
| PM8010 N | Optional population is checked against complete firmware PMIC and command-DB inventories | Populated inventory or a declared N-regulator resource retains probing. Only a complete absent inventory plus absent resources skips the template. A positive early record cannot hide malformed later metadata. See [population handling](PM8010-POPULATION.md). |
| Xiaomi Pad 7 / POCO Pad X1 | Existing SKU selection and device profiles | POCO-only NFC admission remains SKU-specific. A panel variant does not select a commercial SKU. |

Shared Qualcomm catalogue entries and adjacent-device touch suppliers are not
additional confirmed Uke variants. Display support alone does not establish
touch, pen, calibration, suspend or optical acceptance for another assembly.

The CSOT and Tianma generic assets match the pinned OS3.0.304.0 inventory.
Both use the same admitted four-bank RAM layout, while their ILM/DLM CRCs and
electrode maps differ. No firmware blob, manufacturing firmware or unit-specific
calibration is added to Git. A different supplier's image is rejected before
RAM writes. Config-map fixtures compare all 2,400 entries per axis with the DT.
Populated/absent PM8010 and malformed inventory fixtures pass without bus I/O.
NVT/Sunwoda observation does not add firmware setters or replace its charging
policy. These are source checks; no additional hardware operation was performed.

Focused checks on a prepared source tree:

```sh
bash tests/o82-variants-contract.sh /path/to/prepared-kernel
bash tests/o82-variants-dt-contract.sh /path/to/prepared-kernel
bash tests/o82-panel-contract.sh src/display/panel-xiaomi-o82.c src/display/o82-data.h /path/to/prepared-kernel
```

COPR source composition must carry the updated native preparers, the new
`generate-native-panels.sh`, early-entry patch/header, panel source, OEM-mode
DT overlay, `0071-o82-panel-variants.patch` and their fixtures together.
Older recipes that copy only selected overlay files need that complete set.
This change does not submit a build or allocate a package release.
