# Startup warning corrections

1 November 2026. The release114 candidate retains the complete release110
source package and three warning corrections. LLCC checks whether its optional
broadcast-AND resource exists before mapping it. FS19xx uses the current
per-CPU system queue for its existing delayed unmute work. Existing mapping
errors, Cliffs7 resource guards, amplifier locking and cancellation remain.
LPASS RX/WSA sorts its combined register defaults using upstream commit
`246c785491bb265b9716a512057cee8f1a5a3280` by Srinivas Kandagatla. Both upstream
additions apply unchanged; all register/value pairs and cache types remain.

The native LLCC fixture covers an absent and present optional window, mapping
failures, the legacy EINVAL fallback and unchanged mandatory-resource refusal.
The amplifier fixture retains fault, mute, timeout and cancellation coverage.
COPR must complete source, native build and signed-package checks before any
installation. This candidate does not establish faster startup, successful
power-off, cache performance, audio calibration or a USB disconnect repair.
