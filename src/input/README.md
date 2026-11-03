# Uke native touchscreen candidate

26 October 2026. Linux 7.3.0-18 processes the CSOT NT36532 THP matrix in kernel
input. It loads the existing shared model firmware, collects 32 startup frames
for a volatile baseline and reports up to ten tracked contacts. It does not
execute a userspace contact processor or read private touch reference files.
Keep the surface clear during initial calibration. This is a source candidate;
physical contact, multitouch and VRR acceptance remain open.

The 7.3.0-17 tablet trial registered an input device but did not report touch.
A coordinated contact capture produced changing valid matrices and no standard
coordinate contacts in either checked coordinate-reporting mode. Command ACKs
and an idle checksum therefore did not establish a usable coordinate protocol.
Release 18 keeps THP reporting and uses an independently implemented integer
baseline, local ascent, weighted centroid and the kernel's MT slot assignment.
The separately licensed legacy contact core is not copied into the module.

DT supplies `POCO Pad X1 Touchscreen`, active dimensions, physical size, inverted
Y and the separable electrode map from the already distributed shared CSOT
configuration (SHA256 `c02d1956da3714bbd9a19f14ca814731cffd4e2442677a83d5e071ea547a0616`).
The SPI leaf retains the existing panel, GPIO26 input, GPIO54 rising IRQ and
19.2 MHz bus. No other board's firmware, pins or calibration are used.

IRQ reads are primary; a fenced delayed worker reads after a missed IRQ.
Quiesce drains IRQ and work before power/reset. Tracking and the baseline remain
live through a panel refresh transition that does not reset the panel generation;
a real panel reset releases contacts and recalibrates. Bad frames retain the last
contact for at most 100 ms. Suspend/gesture safety checks remain in force.

Host tests cover matrix processing, ten contacts, independent lifts, scan-mode
continuity, malformed packets, noise, palms, slot output and panel/work lifetime.
Private packet replay is diagnostic evidence, not input acceptance. The native
RPM build runs the same input and lifecycle fixtures. Keep the verified legacy
kernel, signed packages and private data until physical tests pass.
