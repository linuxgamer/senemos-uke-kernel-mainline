# O82 color resolution

21 October 2026. Fedora Rawhide AArch64, original KDE 6.8.1, Uke kernel
7.2.12-1: DSI-1 exposes seven modes and debugfs reports `Maximum: 10`, but
the connector has no `max bpc` property. KScreen therefore reports unknown
color resolution. The display was blanked during this read-only capture;
no active scanout or optical precision was measured.

The 7.2.12-4 source attaches the standard property with a fixed 10–10 range
to the existing O82 connector. It preserves RGB101010, DSC parameters,
panel commands and the device tree. Host checks exercise the actual connector
initializer, state allocation failure, property errors and other-panel exclusion.
COPR compilation, installed-package checks and tablet acceptance are separate.

Original [KWin 6.8.1](https://github.com/KDE/kwin/blob/v6.8.1/src/backends/drm/drm_output.cpp)
uses that property for its color-resolution capability. Original
[KScreen 6.8.1](https://github.com/KDE/kscreen/blob/v6.8.1/kcm/ui/OutputPanel.qml)
hides the selector when the minimum and maximum are equal. This change makes
the fixed capability available to KDE; it does not provide a 10/12-bit selector.

Both exact OEM O82 variants use 30-bpp input and the shared DSC table uses
10 bits per component:

- MiCode display DT `4a3e1c391130237c5e8c2b250d1c94f3e25b9b11`,
  `display/dsi-panel-o82-{36-02-0a,42-02-0b}-dualdsi-dsc-lcd-video.dtsi`
  and `display/dsi-panel-o81-o82-dualdsi-dsc-lcd-video-qcomcommon.dtsi`.
- MiCode display `44275c404a677d9d9e5230fedd1af2ef02fc7b9a`,
  `msm/dsi/dsi_panel.c` and `msm/sde/sde_connector.c`.
- OnePlus Pad 2 `127ee601667aa3ac0125138573176f512cb70292`, active
  `linux-oneplus-pineapple/APKBUILD` panel queue: 8-bpc/RGB888 on a different
  panel. Its values do not establish an O82 mode.
- Upstream Linux comparison `4056b3c9d3c92ea45955641dbafeb9b960e146ef`,
  `drm_connector.c` and `msm/dsi/dsi_manager.c`; packaged Linux 7.2.12
  `cc9de5d4b5ab6459f5774946aa3195ad51236fa8` retains the explicit state
  requirement of the property helper.

The existing upstream Linux code is GPL-2.0; the local change implements its
standard interface without importing donor panel data. No donor code ran.
Advertised 12-bit color does not identify this panel's receiving format or
internal FRC mechanism. Enabling a 12-bpc property or changing DSC input to
12 bpc requires exact O82 receiver/TCON evidence and a recoverable physical
test. No 12-bit optical output, FRC, HDR or gamut calibration is accepted here.

On 22 October, static inspection of Global OS3.0.304.0 ODM QDCM profiles for
both exact O82 variants found two distinct `PostBlendDither` configurations.
Both have `enable=false`; the detailed configuration also has
`temporalEnable=0`. The JSON payload strings require swapping adjacent bytes
after hex decoding. These profiles do not establish a 10-to-12-bit temporal
conversion. They cannot rule out a different runtime override or processing
inside the DDIC. No panel-register description identifying such a mode was
found in the bounded OEM source/profile comparison. The official Xiaomi
[specifications](https://www.mi.com/in/product/xiaomi-pad-7/specs/) advertise
12-bit color and four speakers/microphones; they do not describe the transport
or the internal color expansion mechanism. No new 12-bpc mode is added.
