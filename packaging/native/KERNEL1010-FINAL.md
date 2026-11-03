# Kernel 1010 fixture correction

1 November 2026: preserve kernel ABI `7.3.1-1010` as explicitly requested.
Use fresh RPM revision `1010.1`; the earlier COPR11240670 failed in its host
fixture after compilation and emitted no binary RPM. This manual recipe refuses
any other published source identity for ABI1010 across all three projects.
Separate newer experimental kernels remain available; this is not a claim that
1010 is the repository's numerically newest update.

The complete earlier1010 production source, configuration, boot recipe and
payload are retained. Remove one duplicate enum from the host fixture; use the
selected kernel's original public definition. Native checks must reproduce the
specific original compiler error, then pass the corrected fixture and all
remaining package checks. Build and signed-artifact results do not establish
tablet display, startup, shutdown or other physical acceptance.
