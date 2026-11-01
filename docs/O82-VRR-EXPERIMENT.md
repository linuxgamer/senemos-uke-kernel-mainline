# O82 video AVR experiment

1 November 2026. Release 112 preserves an explicitly requested 30 Hz floor
instead of silently raising it to 90 Hz. A 144 Hz OEM base therefore admits
the requested 30-144 Hz software range. Unsupported floors are refused without
changing the previous value; zero still disables the experiment. Touch delivery,
flicker and physical refresh cadence remain unqualified below the earlier trial
floor. A deliberately black first frame now completes the panel/touch restoration
transaction; read and backlight-enable errors still fail that transaction.
Release111 stopped before compilation because patch0069 lacked trailing context.

18 October 2026. This source path is an **unqualified receiver experiment**
for Uke SM7675, the native OEM PB/42 profile, dual DSI and DSC. It defaults to
off. There is no physically qualified VRR range. Release 17 adds an explicitly
opted-in `vrr_capable` advertisement for desktop integration experiments.

The existing seven fixed modes and panel command sequences are retained.
The code handles the CRTC's standard atomic `VRR_ENABLED` state. Linux's
`drm_crtc.c` attaches it to every atomic CRTC during initialization. On
18 October, `modetest -M msm-kms -c -p` on release 8 confirmed property 25
on CRTC 79, initially zero. The earlier claim that attachment was missing
was incorrect; no additional driver attachment is needed. Select `msm-kms`
on this split GPU/KMS configuration; `msm` opens the render-only device.
Unsupported active modes and topology are rejected during atomic checking.
That stage does not write hardware. A read-only MSM module parameter,
`o82_vrr_test_min_hz`, supplies the experimental lower bound. Zero disables
the path. Release 8 restricts the experiment to 119–120 Hz. The release-9
source extends host admission to all seven exact OEM modes, with an
experimental request floor of 30 Hz. A 144 Hz base permits a requested
30–144 Hz sweep through VFP extension. This is a laboratory envelope,
not a panel rating or a qualified connector range.
Do not enable it in a production release configuration. With the existing
experiment parameter set to 30, release 17 reports the standard DRM connector
capability to the original KDE compositor. Every actual probed mode must pass
the same DPU/DSI admission used by atomic checking; the monitor ceiling comes
from those modes. The property remains false with the default parameter, a
foreign topology, a missing provider or a refused mode. This desktop opt-in
does not qualify receiver tolerance, flicker or physical cadence.

The full DRM mode clock and horizontal total give 2,329 maximum vertical
lines for the initial 119 Hz request. A 144 Hz base and 30 Hz request
give 11,088 lines. Integer-kHz OEM clocks can place nominal 30/48/50/90 Hz
slightly below their integer labels; the exact base is retained when only
one line separates it from the rational floor. Extensions always use floor.
Each INTF multiplies this count by its actual
programmed horizontal period after split/DSC conversion. Overflow, register
readback failure and unequal periods reject activation. Both DSI hosts are
validated under the existing bonded lock order before either is changed.
A failed host readback clears AVR on both hosts. One logical encoder owns
enable/disable and triggers both interfaces after their shared CTL flush and
initial timing-enable callbacks.
Disable and hardware-reset paths clear both interfaces before host cleanup.
A failed activation is retried only after VRR off or a full modeset.
Leaving VRR for another fixed mode uses a full modeset; the existing DFPS
shortcut is excluded while either atomic state requests VRR.

The existing encoder debugfs `status` reports software `avr_enabled`.
It does not measure panel cadence. Register snapshots, DRM timestamps and
frame presentation also remain separate from calibrated optical/TE evidence.
During AVR the nominal scanout geometry cannot supply a precise variable
frame timestamp. Patch `0037` selects DRM's monotonic timestamp estimate;
fixed scanout keeps its existing helper. The resulting VRR timestamps have
IRQ/scheduling uncertainty and must not be reported as precise glass timing.

Patch `0041` removes a redundant watchdog armed flag and always drains the
timer after both physical encoders stop. A completion IRQ can precede timer
arming; an already completed frame must not become a false stop error. Genuine
busy-frame expiry retains its error, snapshot and CRTC notification paths.

## Validation and device procedure

The actual-source host test is `bash tests/o82-avr-contract.sh PREPARED_KERNEL`.
It executes rational timing and overflow boundaries, INTF operations, bonded
host validation/readback rollback, and logical encoder transitions with
injected failures. The existing DFPS atomic test additionally rejects the
shortcut for old or new VRR state. RPM `%check` runs the AVR test.

Before a device trial, preserve the current boot bundle and matching modules,
record the exact panel/build/configuration and coordinate exclusive display
and reboot access with any other session. Use an isolated kernel release
and the existing guarded boot update path. Enable the parameter only in
that test boot. Keep the installed fallback and Android return route.

1. Record fixed base-mode scanout, both INTF/DSI register snapshots, DRM events,
   touch state and the kernel log.
2. Verify the CRTC property on the selected KMS device. Obtain DRM
   master or a valid lease using the distribution's KMS tools;
   request `VRR_ENABLED=1` with an exact OEM mode. Test-only
   atomic requests for a modified clock must fail before hardware changes.
3. First repeat the narrow control. With the release-9 request floor 30,
   sweep delivery at 144, 120, 90, 60, 50, 48 and 30 fps using a 144 Hz base,
   then deliver deterministic irregular frames. Correlate frame IDs, DRM events and calibrated optical/TE capture
   on both panel halves. Stop frame delivery to check the bounded repeat.
4. Request `VRR_ENABLED=0`, verify both hosts/INTFs leave AVR, and repeat the
   fixed-mode baseline. Check full modeset, DPMS and suspend/resume separately.

Physical cadence, receiver tolerance, flicker, input behavior, reset/recovery
and suspend acceptance remain required before enabling VRR in production.
The experimental KDE option alone is not physical acceptance evidence.

`src/display/o82-avr-lab.cpp` is a native libdrm lab application, not a
desktop service. Build it with the host AArch64 SDK's C++17 compiler and
`pkg-config --cflags --libs libdrm`. Run `--self-test` first, switch to an
unused VT, then run `--run`; `--run fixed` repeats the same delivery schedule
without enabling AVR. It checks the opt-in parameter, rejects an invalid
test-only request, draws the same binary frame ID on both halves, logs
submit/DRM/completion timestamps, pauses for 250 ms, clears VRR and disables
its scanout. Return to the original logind session after execution. A normal
30 fps webcam can document patterns and visible corruption, but does not
directly resolve 119–120 Hz glass cadence.

Sources: [Uke OEM display drivers](https://github.com/MiCode/vendor_opensource_display-drivers/tree/44275c404a677d9d9e5230fedd1af2ef02fc7b9a),
[PortareOS AVR patch](https://github.com/portare-ch/portareos/tree/67ed458421d919aba9c687c3f72d7678954b6902),
[standard DRM semantics](https://docs.kernel.org/gpu/drm-kms.html#variable-refresh-properties).

## Auxiliary measurements, 18 October 2026

`o82-te-sample.cpp` is a read-only native laboratory sampler. It validates the
Cliffs TLMM compatible, aperture and current GPIO77/78 controls before mapping
two pages with read-only protection. A two-second release-8 sample detected no
edges. Wiring, pin input visibility and panel TE configuration remain unknown;
this result supplies no physical cadence measurement. Do not remux the pins
or infer a panel protocol from the generic OEM TE references.

`o82-scroll-lab.cpp` creates a temporary standard uinput mouse and delivers a
finite eight-second wheel sequence without clicks or held keys. Positioning
was checked with original KDE at scale 2.5 and a centered Dolphin window;
recheck it after layout changes. Run its self-test first. Synthetic input and
DRM presentation-event timing are separate from physical finger latency and
calibrated optical measurements. Both programs are laboratory source tools,
not startup services or release payloads.
