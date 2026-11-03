# Uke torch PWM and current-resolution source review

Date: 30 October 2026. Target: Xiaomi Pad 7 / POCO Pad X1, Uke, SM7675,
PMXR2230. Evidence: exact OEM OSS sources, same-SoC comparison, current upstream
and the native candidate source. No driver, DT, current limit, installed package
or physical light setting is changed by this review. No new build or device
acceptance is claimed.

## Result

The two-level restriction is the result of the native candidate's **20 mA total
policy and coupled 5 mA/channel current steps**, not an established intrinsic
two-level hardware limit. Uke's OEM board overlay selects a **250 mA/channel**
torch ceiling with **5 mA resolution** on two channels. That admits 50 distinct
positive current targets per channel in source. It does not establish safe
native continuous operation at that ceiling, calibrated light output or 256
independent brightness levels.

The selected OEM torch path programs current, not PWM duty. Hardware PWM is
implemented in the separate RGB/LPG path. The flash hardware also has selectable
GPIO strobe inputs, so PWM gating remains a hardware hypothesis; an actual Uke
LPG-to-strobe route and admissible pulse timing have not been established.
Simply changing `max_brightness` to 255 would repeat current targets.

## Exact source path

| Source | Pin and relevant files | Observation |
|---|---|---|
| Uke kernel OSS | [MiCode kernel](https://github.com/MiCode/Xiaomi_Kernel_OpenSource/tree/5712080a4b0c0b1a879e6d145c601c649ddaddfd), `uke-v-oss`, Linux 6.1.68 | `build.config.msm.uke` inherits the Pineapple config. `pineapple_GKI.config` enables `LEDS_QTI_FLASH`, `LEDS_QTI_TRI_LED` and `PWM_QTI_LPG` as separate modules. |
| PMIC graph/bindings | [MiCode DT](https://github.com/MiCode/kernel_devicetree/tree/94c84aeb9e517dbde546fc732033c184094c8e57), `qcom/pmxr2230.dtsi`, `bindings/leds/leds-qti-flash.yaml` | Flash controller is `qcom,pm8350c-flash-led` at 0xee00. RGB at 0xef00 consumes LPG PWM channels. These are different peripheral paths. |
| Uke camera board overlay | [Camera DT](https://github.com/MiCode/vendor_qcom_proprietary_camera-devicetree/blob/57d2135ee6909ffb7d288a7dc4d82c85d95fc10d/uke-sm8635-camera-sensor.dtsi) | Rear-wide torch references `pmxr2230_torch0` and `torch3`; both override the generic PMIC defaults with 250 mA and 5000 uA resolution. The rear-ultra alternative is commented out. |
| Camera request producer | [Camera kernel](https://github.com/MiCode/vendor_qcom_opensource_camera-kernel/tree/699fa15a98abd40fbb94f3a6fc00f91723d29d35/drivers/cam_sensor_module/cam_flash) | Low/torch operations pass bounded `led_current_ma` through LED triggers to the PMIC driver. No PWM duty/period request was found in this path. |
| Same-SoC comparison | [OnePlus SM7675](https://github.com/OnePlusOSS/android_kernel_oneplus_sm7675/blob/fc892483f1d61f245924681eb5abd563564d9cba/drivers/leds/leds-qti-flash.c) | Same current-target and 5/12.5 mA resolution model; no PWM generator in the compared flash driver. No board pin or current value is transplanted. |

OEM flash IDs 0/3 correspond to upstream LED source numbering 1/4. They must
not be confused with LPG PWM channel numbers. The generic PMIC DTS defaults
alone are insufficient; the Uke camera overlay changes those defaults.
Source identities and file-level license headers are retained unchanged.

## Current control versus PWM

In [leds-qti-flash.c](https://github.com/MiCode/Xiaomi_Kernel_OpenSource/blob/5712080a4b0c0b1a879e6d145c601c649ddaddfd/drivers/leds/leds-qti-flash.c),
`__qti_flash_led_brightness_set()` treats brightness as a current request in mA,
clamps it to the configured current limit and programs `IRESOLUTION` and
`ITARGET`. `current_to_code()` rounds to the selected 5000 or 12500 uA step.
The 7-bit ITARGET field is a current code, not an 8-bit duty register.
Already-enabled torch updates only the target current. An LED-class integer
range or V4L2 step value of one does not change that hardware granularity.

In contrast, [leds-qti-tri-led.c](https://github.com/MiCode/Xiaomi_Kernel_OpenSource/blob/5712080a4b0c0b1a879e6d145c601c649ddaddfd/drivers/leds/leds-qti-tri-led.c)
computes duty from brightness/LED_FULL and calls the PWM framework.
`pmxr2230.dtsi` connects these PWM consumers to red/green/blue. Qualcomm's
[upstream LPG documentation](https://docs.kernel.org/leds/leds-qcom-lpg.html)
describes programmable duty and routing to RGB sinks or GPIOs; it does not prove
a particular Uke torch connection. The upstream PM8350C LPG catalog has a fourth
channel without a tri-LED sink, which is a candidate resource, not proof of a
usable route or pin assignment on PMXR2230/Uke.

The other OEM `leds-qpnp-flash-v2.c` contains `bst-pwm-ovrhd-uv`. That setting
concerns boost-converter voltage headroom, not torch brightness duty. Its match
table targets other PMICs; it is not the selected PM8350C-compatible flash path.
The QTI flash switch's on/off hrtimers return `HRTIMER_NORESTART`; they implement
delayed/safety transitions, not a repeating brightness PWM loop.

## Hardware strobe hypothesis

The [exact OEM binding](https://github.com/MiCode/kernel_devicetree/blob/94c84aeb9e517dbde546fc732033c184094c8e57/bindings/leds/leds-qti-flash.yaml)
documents `qcom,strobe-sel` (software/hardware), `qcom,strobe-config` (GPIO1–4
input selection) and hardware-strobe GPIOs. The driver defaults to software
strobe when the property is absent. The reviewed Uke torch nodes do not select
hardware strobe and do not contain a PWM consumer. Driver GPIO operations are
static enable/disable writes, not a duty-cycle generator.

There is also a binding/parser naming discrepancy in this pin: the schema uses
`qcom,hw-strobe-gpios`, while the driver reads `hw-strobe-gpios`. An example
cannot be copied without resolving that actual parser contract. Current
[upstream torch brightness code](https://github.com/torvalds/linux/blob/master/drivers/leds/flash/leds-qcom-flash.c)
explicitly selects software strobe while switching torch off/on. The native
step-count patch does not change that. A future hardware-PWM implementation
therefore needs driver ownership/sequencing changes as well as a proven route;
an extra DT PWM property alone will not enable it.

Thus the OSS does not demonstrate PWM-controlled stock torch brightness.
It also does not prove that PWM gating is impossible in the PMIC. Before using
it, establish the exact PMXR2230 LPG/pin-mux/strobe signal route, pin ownership,
strobe electrical semantics, minimum pulse/debounce/ramp timing and coordinated
off/error/suspend/removal behavior. A generic GPIO mux function or another
PMIC's example is insufficient. No GPIO is reconfigured and no software SPMI
toggle loop is substituted for this missing evidence.

## Native scale and implementation decision

The native candidate's `patches/boot/0011-qcom-flash-torch-steps.patch` exposes
the number of real coupled torch current steps instead of 255 repeated software
values. With two channels it is:

`steps = total_limit_uA / (5000 * 2)`

| Configuration | Coupled total current increment | Positive targets from source arithmetic |
|---|---|---|
| Current native 20 mA total policy | 10 mA | 2 |
| OEM 250 mA per channel, both equal | 10 mA | 50 up to 500 mA total |
| Hypothetical proven hardware PWM at the present peak limit | Requires measured duty/pulse behavior | Unqualified; no count claimed |

The OEM row is source capability evidence, not authorization to raise the native
continuous-current limit or a physical thermal result. The new native consumer
also deliberately admits scale 2/current 20 mA, so changing a DT number alone
would be refused rather than silently granting a larger range.

A 0–255 client range can be normalized onto admitted current targets, but that
alone cannot provide 256 distinct light outputs. Two useful paths remain:

- Establish hardware PWM routing/timing while retaining the current peak limit,
  then qualify real duty resolution and lifecycle handling before claiming a
  0–255 hardware brightness range.
- Qualify a larger native current range using exact OEM evidence and retained
  thermal/error protections; expose the actual current-step count and separately
  normalize client requests. This offers more than two steps without pretending
  the current DAC is an 8-bit PWM controller.

Neither path is activated by this report. Existing kernel/Control authorization,
current limits, matched-build and recoverable physical-acceptance gates remain.
