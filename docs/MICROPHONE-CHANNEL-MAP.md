# Uke microphone identities

31 October 2026. POCO Pad X1, Fedora Rawhide AArch64, Linux7.3.1-102,
source dcc59b39094d9875be91114cd838d85d9faa0002. All four native48kHz/S16_LE
capture channels return independent data, reopen and close correctly. Individual
decimator attenuation affects only the matching channel. Four simultaneous
ordinary-user desktop captures and per-source native attenuation also pass.

The reference view is landscape, screen facing the user, USB-C at right.
Aperture positions were identified through the separately named KDE sources.
They are qualitative positions; metric geometry remains unmeasured.

| KDE input | Stable identity | PCM index / DEC | ADC / SWR | Physical position |
|---|---|---|---|---|
| Microphone1 | `uke-amic1` | 0 / 0 | 1 / 0 | Top edge, right |
| Microphone2 | `uke-amic3` | 1 / 1 | 3 / 2 | Left edge |
| Microphone3 | `uke-amic4` | 2 / 2 | 4 / 3 | Beside camera |
| Microphone4 | `uke-amic5` | 3 / 3 | 2 / 1 | Top edge, left |

The corrected raw card advertises `mic:uke-4ch-v3`. The owning hardware-support
package exposes four selectable mono views of one shared four-channel PCM.
Its position labels and `senemos/uke/audio/microphone-layout.json` retain this
mapping. The identities stay fixed when the display rotates; transforms belong
to later position-aware processing. Front versus rear camera association is
not established by the current aperture report.

Earlier OEM aliases sidebottom/top/back/sidetop describe routing references;
they do not replace the identified body frame. Combined Android routes can
also select different ADCs. The
[input manifest](../manifests/research-microphone-inputs-20261031.json) records
source pins, physical identities and the current observation boundaries.

The stock common microphone-characteristics file duplicates geometry and does
not explicitly bind Android builtin_mic IDs to AMIC inputs. Its coordinates,
frequency responses and sensitivity values are not installed as calibration.
The manufacturer's repair manual does not label the electrical AMIC-to-hole
association either. Neither source supplies accepted metric array geometry.

Android routes and processed capture remain separate from raw Linux capture.
Before adding noise suppression, gain control, echo cancellation or directional
processing, assess each effect's ABI, licensing and calibration requirements.
Preserve raw access. Complete suspend/resume and power-cycle regression results
remain separate from these capture and identity observations.
