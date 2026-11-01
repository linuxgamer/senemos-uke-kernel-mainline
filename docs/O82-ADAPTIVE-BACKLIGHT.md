# O82 content-adaptive backlight

1 November 2026. Source candidate for POCO Pad X1 / Xiaomi Pad7, Linux7.3.1.
The O82 panel implements CABC through its TCON. This path uses the panel's
existing OEM calibration and the paired KTZ8866 PWM input. It does not port AMD
register programming or enable Qualcomm AD4 without a matching DT resource.
Compilation and fault checks run in COPR; panel behavior and power savings need
separate physical acceptance. No capability is added to DisplayPort.

The original KWin enum `adaptive backlight modulation` is attached only to
the matched O82 connector. The default is `off`. Its `PreferAccuracy` policy
already chooses off; selecting a saving tier does not override that policy.

| DRM tier | O82 OEM CABC mode |
|---|---|
| off /0 | off /0 |
| min /1 | UI /1 |
| bias min /2 | UI /1 |
| bias max /3 | still /2 |
| max /4 | movie /3 |

The panel has four modes, so the two low tiers share UI. The mode names are OEM
definitions; their relative power saving is not measured. Each update forces a
full modeset with a brief blank. Panel preparation sends paired LP short-write
parameter commands `FF10` then `55<mode>` after ON/PPS and before publishing
prepared state. Either failure follows the existing OFF/power-down rollback;
first-frame backlight admission remains unchanged. Zero brightness stays zero.
The shared atomic helper marks connector changes before collecting affected
planes/bridges; a late bridge callback alone cannot guarantee that collection.

Nonzero adaptation with HDR/PQ/HLG metadata is refused until a jointly qualified
HDR/CABC pipeline exists. Malformed metadata and tiers outside0..4 are refused
before state publication or I/O. Full matched kernel/modules are required by
the added generic connector state; replacing one running module is unsupported.
Brightness limits, current, voltage, PWM configuration and speaker gains stay
unchanged. CABC deliberately trades image accuracy for saving; it does not fix
an incorrect ICC transform, provide local dimming, or implement HDR conversion.

Exact primary evidence: Xiaomi display GPL commit
`44275c404a677d9d9e5230fedd1af2ef02fc7b9a`, `mi_dsi_panel.c` CABC dispatch;
display-DT commit `4a3e1c391130237c5e8c2b250d1c94f3e25b9b11`, O82 PA/PB includes
and `dsi-panel-o81-o82-dualdsi-dsc-lcd-video-micommon.dtsi`. The four LP command
sets are shared by both panel variants. Original KWin commit
`f130ab33c8e6f3b9d728aade87836086ae9a8ed4` supplies the enum names and policy.
Generic AD4 source is insufficient: the exact Cliffs DT lacks its AD offset.

`tests/o82-abm-contract.sh` extracts the actual panel helper, bridge atomic
check, core set/get branches, property helper and selected kernel HDR structs.
It covers all modes, every tier transition, faults, allocation failure, repeated
attachment, default off, invalid values and SDR/HDR metadata. The existing panel
lifecycle fixture retains first-frame and paired-transfer failure coverage.
Run both only in the remote build environment. Native color/HDR rendering and
the remaining preset operations remain separate unfinished work.
