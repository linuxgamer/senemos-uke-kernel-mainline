# Uke paired KTZ8866 dimming observation

Date: 2026-10-18. Environment: source candidate based on kernel24 source
`b818ce5f563e04462e33c6c6c504b5ed0660216d`. No test, compiler, kernel build,
device read or device write was performed by this source task. Patch 0074 is
for the next candidate; it does not change the running kernel24 build.

## Interface and limits

The primary bound I2C driver provides read-only `uke_dimming_state`, also
reachable at `/sys/class/backlight/uke-backlight/device/uke_dimming_state`.
The driver core creates its device group after successful probe and removes
the group before unbinding. Secondary and non-Uke devices expose no attribute.
The existing peer device reference/link and paired brightness mutex are reused.

One read attempts BL_CFG1 (0x02) once on each regmap under the primary mutex.
It reports `status=ok` only when both agree on PWM_ENABLE bit 0, PWM_CONFIG
bit 2 and BLED_MAP bit 3 (mask 0x0d). It then reports `mode=i2c` or
`mode=i2c-times-pwm`, `mapping=linear|exponential` and
`pwm_polarity=active-high|active-low`, together with both raw register values.
Other BL_CFG1 bits do not participate in the mode comparison. This is a
sequential paired read, not a physically atomic snapshot or protection from
external direct bus access.

`status=mismatch` contains both raw values and their relevant XOR mask, without
a decoded common mode. `status=read-error` contains both signed regmap errno
values (zero for a successful side), without raw or decoded values. A successful
sysfs read can therefore contain a diagnostic failure: consumers must inspect
`status`. Reads are not cached or retried. No register, GPIO, bias supply,
current limit, brightness value or HBM setting is written by this interface.
Reading it performs real I2C transactions and must not be described as a cached
status interface.

KTZ8866 register mode does not establish optical DC dimming, flicker, PWM duty
or frequency, measured brightness, gamut or panel bit depth. Those require
separate evidence. The datasheet's current-sink description is not an optical
measurement of the complete Uke display assembly.

## Brightness range

The exact Uke OEM backlight uses normal logical levels 0-2047 and HBM logical
levels 2048-4095. Normal levels map to table indices 0-1535; the HBM branch maps
to indices 1535-2047. The remap table produces an 11-bit chip brightness code
stored in registers 0x04/0x05. The OEM's logical range does not establish 4096
distinct hardware current codes. The current Linux driver exposes the normal
logical maximum 2047 and retains its existing OEM remap and visible minimum.
Patch 0074 changes none of these values and does not enable HBM or claim 800 nit.

## Reviewed sources

The workspace donor policy, SM7675 donor survey, acquisition inventory and
component research-donor manifest were consulted before implementation.
Reference code was read as evidence; no donor scripts were run or modified.

| Source pin | Files and finding | Compatibility limit |
|---|---|---|
| MiCode display `44275c404a677d9d9e5230fedd1af2ef02fc7b9a` | `msm/mi_disp/mi_backlight_ktz8866.c` and `.h`: normal/HBM logical ranges, remap and paired serialization | Exact Uke OEM source, not proof of the current firmware-adopted mode; no OEM mode values are transplanted |
| Kinetic KTZ8866-04b, January 2022, SHA256 `b5c2d639fcf159859496b6896b8123f7965a1d44e9fbddaa6ce4cc83b59a408a` | Retained manufacturer PDF, pp 19, 26 and 27: I2C versus I2C×PWM operation, register map and Table 7 BL_CFG1 fields | Shared chip semantics; no board mode, optical behavior or safe HBM qualification follows |
| Upstream snapshot `4056b3c9d3c92ea45955641dbafeb9b960e146ef`, and actual prepared Linux 7.2.10 | `drivers/video/backlight/ktz8866.c`, `include/linux/sysfs.h`, `drivers/base/dd.c`: regmap, attribute groups and bind/unbind ordering | Upstream driver has no Uke pair observer; its generic initialization writes are not copied into Uke adoption |
| Peridot `2ed9eadbecae21ef51134e556951e7305ba65f88` | `drivers/video/backlight/ktz8866.c`: upstream-style chip driver, no equivalent paired observer | Different board; no board setting is borrowed |
| OnePlus Nord4 modules/DT `1138e00fee63582a0cc6a53af3286621786827b7` | `vendor/qcom/opensource/display-drivers/msm/leds_ktz8866.c`: dual chip read/write paths | Same-SoC/shared-IP comparison only; its mode writes and inconsistent PWM comments are not Uke mode evidence |
| OnePlus Pad2 queue `127ee601667aa3ac0125138573176f512cb70292` | KTZ8866 slave patches 0007/0013 and default-brightness patch 0048 | Paired shared-IP comparison; default brightness and mode are separate concerns |
| Uke Fedora archive `cf4f9317a7fef3e9bdddc36bedcb257fa51b0994` | `kernel/display/backlight-xiaomi-o82.c`: component-owned paired regmaps and brightness writes | No equivalent mode observer; inherited Uke support claims remain separate from current source/device evidence |

This patch adds project observation code around existing GPL-2.0-only upstream
and Uke driver paths. Original upstream and OEM remap attribution remains intact.
No applicable donor provides a qualified Uke optical DC-dimming measurement or
a reason to change the adopted mode automatically.

## Deferred coordinator validation

`tests/ktz-dimming-observation-contract.sh` extracts the actual observer,
attribute and visibility code from the prepared driver. It checks all 65,536
BL_CFG1 pairs, unrelated-bit differences, failures on either/both adapters,
lock coverage, unchanged registers and hidden/unready devices. No write API is
provided to the extracted code. The fixture is added to the native RPM `%check`.
It is prepared, not executed in this source task. The coordinator must compile
the complete KTZ8866 translation unit as well; host stubs do not prove kernel
API/lifetime correctness or real bus behavior.

For kernel25, regenerate checked sources and run the fixture and actual AArch64
translation unit first. After the coordinator installs matching kernel/modules,
a bounded read of the driver-owned attribute can establish the observed pair
configuration. Do not use forced/direct I2C or a mode write to obtain the result.
Record a mismatch or error without normalizing it to a preferred mode. Optical
DC/flicker, HBM and the panel's advertised color specifications remain separate
physical acceptance gates.

## Coordinator result and source correction

The coordinator reports the first actual-code fixture passed in kernel25 COW
staging. Complete actual AArch64 `ktz8866.c` compilation then emitted a format
warning: Linux `BIT()` uses `unsigned long`, so the inline masked XOR did not
match `%02x`'s `unsigned int`. A host fixture PASS did not establish a clean
kernel translation unit. No tablet dimming read was performed.

The source successor stores the bounded mask in an explicit `unsigned int`
before formatting. The fixture now uses Linux-width `1UL` and gives its
`sysfs_emit` stub a printf-format attribute so the host compiler diagnoses
the same mismatch with warnings retained. No warning suppression, output
format or hardware behavior changes. The original source receipt is retained;
the coordinator must regenerate the revised patch and repeat the focused
fixture and actual translation-unit check. Neither check ran for this revision.

The coordinator subsequently withdrew the first fixture PASS report. Its
orchestration continued to the kernel translation unit after the host fixture
failed to compile: a C++ `void *` stub return cannot implicitly convert to
`ktz8866 *`. That first fixture never passed, and the same harness failure
persisted after the format successor. The production C conversion is valid.
The next source successor returns a typed pointer with an explicit C++ cast
from the host-only `dev_get_drvdata` stub, preserving the extracted production
C functions unchanged. This corrects the fixture rather than introducing a
driver bypass. Original report and correction remain separate evidence;
the corrected fixture and warning-free actual kernel translation unit still
require independent coordinator results. No test or compiler ran here.
