# Startup warning corrections

1 November 2026. The release115 candidate retains the complete release110
source package and the release114 warning corrections. LLCC checks whether its optional
broadcast-AND resource exists before mapping it. FS19xx uses the current
per-CPU system queue for its existing delayed unmute work. Existing mapping
errors, Cliffs7 resource guards, amplifier locking and cancellation remain.
LPASS RX/WSA sorts its combined register defaults using upstream commit
`246c785491bb265b9716a512057cee8f1a5a3280` by Srinivas Kandagatla. Both upstream
additions apply unchanged; all register/value pairs and cache types remain.

The host builder also encodes the standard root-owned 0600 `/dev/console`
character node 5:1 using the selected Linux source's native cpio generator.
One archive retains existing file data, modes, timestamps, symlinks and regular
hardlink groups. The helper requires a source tree without special files and
refuses existing console paths or names the native list format cannot encode.
It creates no real device node and is not included in the tablet payload.
Native fixtures compare complete extracted data/metadata and both hardlink
types, inspect the standard node, check deterministic output and exercise refusals.

The native LLCC fixture covers an absent and present optional window, mapping
failures, the legacy EINVAL fallback and unchanged mandatory-resource refusal.
The amplifier fixture retains fault, mute, timeout and cancellation coverage.
COPR must complete source, native build and signed-package checks before any
installation. Release114 passed signed-package and installed-slot checks but
has not booted; release115 adds source changes only at this checkpoint.
This candidate does not establish faster startup, successful
power-off, cache performance, audio calibration or a USB disconnect repair.
