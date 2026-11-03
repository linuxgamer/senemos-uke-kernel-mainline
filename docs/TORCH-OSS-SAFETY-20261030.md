# Uke OSS torch safety comparison

30 October 2026. Target: Uke, SM7675/PMXR2230. This follows the
[pinned OSS current/PWM review](TORCH-PWM-RESEARCH-20261030.md). Native source
work retains the 20 mA total ceiling, coupled 5 mA/channel steps, software strobe
and existing managed-consumer ABI. No device actuation or installation was done.

## OEM protection paths

The exact Uke camera DT permits 250 mA on each of torch sources 0 and 3. Its
300 ms duration properties belong to the **flash** nodes. They do not establish
a continuous torch deadline or a safe native 500 mA operating point. A current
limit in source is not a measured LED, board or battery thermal qualification.

The selected [OEM QTI flash driver](https://github.com/MiCode/Xiaomi_Kernel_OpenSource/blob/5712080a4b0c0b1a879e6d145c601c649ddaddfd/drivers/leds/leds-qti-flash.c)
and [camera producer](https://github.com/MiCode/vendor_qcom_opensource_camera-kernel/blob/699fa15a98abd40fbb94f3a6fc00f91723d29d35/drivers/cam_sensor_module/cam_flash/cam_flash_core.c)
have the following contracts:

| Path | Observed behavior | Porting consequence |
|---|---|---|
| Available-current query | Uses battery resistance, open-circuit voltage and signed current, a 2.8 V dip threshold plus 50 mV margin, 4.5 A battery-current threshold, voltage headroom and an efficiency estimate. | These are model parameters, not a blanket safe torch current. Native telemetry exists, but provider identity, validity, units, sign, freshness, arithmetic and failure handling need explicit integration. |
| Query bypasses | Missing battery or zero resistance returns the controller-wide 2000 mA maximum; secure-VM/external-LED paths also bypass parts of the calculation. | Do not import these debug/missing-data bypasses into a native safety policy. |
| Query invocation | Maximum-current query is an explicit camera operation. Regular torch enable does not universally invoke and enforce that queried result. | Copying the helper alone would not protect every request. |
| Thermal query | OEM has two configured derating values, 200/500 mA. Native upstream uses its own PMIC/revision-aware thresholds and 1000/500 mA defaults for the four-channel path. | Preserve the native thresholds while current remains 20 mA. A higher-current port needs an exact revision/threshold comparison and measured acceptance. |
| Timed operation | Camera duration operations can supply on/off times. The LOW_FIREDURATION path logs a parameter-setting failure and continues. | Do not describe every torch request as guaranteed timed shutoff. Propagate failures in any future native timed mode. |
| Xiaomi current/time table | Used only when the relevant DT properties exist; the reviewed Uke torch overlay supplies no such table. | Do not invent a current-duration curve or borrow one from another device. |
| Fault IRQ | Reports open/short and supply faults. | Logging a fault is not proof that every software fault path turns the output off. |

The same-SoC OnePlus source in the linked research inventory uses the same
current-target model. It adds no qualified Uke PWM route or continuous-current
thermal envelope. No Android scripts, vendor binaries, GPIO assignments or
foreign-board power limits are used by the native change.

## Native faults corrected

`patches/boot/0043-qcom-flash-preserve-thermal-errors.patch` is applied after
the existing cleanup and real-current-step patches during LED source preparation.
It addresses two faults in the actual upstream QCOM implementation:

- Thermal-status/threshold I/O errors could be overwritten by successful restore
  writes. Preserve the first error and attempt every saved threshold restore,
  including after an ambiguous first write. A successful cleanup cannot turn a
  failed thermal transaction into permission to enable the torch.
- A zero or sub-step granted budget could still enable the physical minimum
  current. Reserve the positive physical minimum before budgeting, reject a
  ceiling below that minimum and refuse a granted budget below it. The callback
  stops module/strobe before these checks. For the two admitted channels, the
  minimum is 10 mA total. Existing error recovery in the managed consumer remains.

The patch does not raise current, change thresholds, add a timer, claim a battery
model implementation or turn the 255 software scale into physical PWM. Persistent
bus faults can also prevent hardware shutoff; software cannot promise zero
hardware-damage risk under arbitrary faults.

## Validation and remaining acceptance

`tests/flash-thermal-errors.sh` extracts the actual QCOM functions and supplies
simulated register I/O. It reproduces both original faults against the pre-fix
source, then exercises first-error retention, all restore attempts, ambiguous
writes, three/four-channel paths, zero/sub-step budgets and the existing thermal
selection. Existing brightness, cleanup and managed-consumer fixtures remain.
`tests/fixtures/torch-oss-safety-check.spec` builds the patched provider and
managed consumer against recorded official Fedora ARM64 headers in COPR; its
output is text receipts only. The upstream input is pinned by commit and SHA-256
in `tests/fixtures/torch-safety-source.json`.

A passing fixture/module build is not a complete matched Uke kernel/DT build or
a physical safety result. Before offering a higher-current range: integrate a
validated battery/thermal admission model without the OEM bypasses; establish
continuous-operation and fault/timeout behavior for the fitted LED assembly;
build the matched runtime tuple with recovery; then measure current, supply dip,
LED/board/battery temperature and off behavior under attended fault/suspend tests.
The present source work does not activate the OEM 250 mA/channel ceiling.
