# Native SSC consumer work

3 November 2026. The firmware-owned sensor description in DT does not create
working IIO devices. The ADSP retains the sensor buses; no duplicate AP I2C
clients or direct register accesses are added.

`src/sensors/uke-ssc-protocol.c` adds a bounded C decoder for the future native
consumer. It validates SUID identity, event framing, required fields, duplicate
fields, vector dimensions, sample status and finite IEEE754 wire values.
Discovery retains empty results and refuses duplicate SUIDs. Event payloads
borrow immutable input storage. Integer conversion rejects overflow without
kernel floating point. Failed decoding leaves the output unchanged.

Protocol sources are the pinned
[Qualcomm client API](https://github.com/qualcomm/sensinghub/blob/329551963bcc063f6a89f6cbca259c5b5c9c4e0b/apis/proto/sns_client.proto),
standard sensor/SUID schemas at the same commit, and the project's existing
MIT SSC discovery/sample code. Upstream Linux 7.3.1 QMI helper declarations
were compared separately. The older SMGR service is a different protocol;
its IIO driver cannot be selected as an SSC service 400 implementation.

The remote check producer is `packaging/native/copr-ssc-protocol-check.sh`.
It exercises synthetic valid/malformed packets with GCC and Clang sanitizers
and compares integer scaling with independent host floating-point arithmetic.
[COPR build 11251116](https://copr.fedorainfracloud.org/coprs/mcc45tr/uke-linux-unstable/build/11251116/)
passed at 1.0-1: both compiler/sanitizer runs completed, including 30,000 numeric
comparisons and 20,000 malformed-input cases per compiler. These are synthetic
host tests, not a linked kernel consumer or sensor trial. No compile ran on
the tablet.

The subsequent metadata/request check passed in
[COPR build 11251255](https://copr.fedorainfracloud.org/coprs/mcc45tr/uke-linux-unstable/build/11251255/)
at 1.0-2. It verifies exact datatype/API metadata, availability, physical/stream
fields, rates, APSS delivery, disable requests and golden request bytes.

`uke-ssc-iio.c` now implements the native QMI/IIO consumer as source. It
tracks unambiguous service discovery, response acknowledgements and client/
peer/generation ownership. Qualified motion/light streams and the separately
encoded proximity/SAR events use direct reads and IIO buffers. Invalidated
generations stop publication; a lost enable/disable acknowledgement closes
the client socket. Service restart and suspend release requests and require
fresh discovery/metadata before restoring requested buffers.

The supported API contracts are accel m/s², gyro radians/s, mag microtesla
converted to IIO gauss, ambient-light `[lux, raw ADC]`, and proximity/SAR
near/far enums. The latter are boolean proximity observations, not inferred
distances. Exact API metadata and sample shape are required; a vendor datatype
alone cannot select these units. Buffers use host receipt timestamps. Sensor
ticks enforce order without inventing a DSP clock conversion. No fallback
mount matrix is installed; coordinate/mount integration remains open.

The consumer validates QMI framing, TLV boundaries, duplicates and payload
lengths before decoding. Its transaction dispatcher follows the pinned upstream
lock/IDR lifetime order and requires the complete decoded byte count.
[COPR build 11251376](https://copr.fedorainfracloud.org/coprs/mcc45tr/uke-linux-unstable/build/11251376/)
passed at 1.0-6. GCC and Clang sanitizer runs executed the actual callbacks
with fake providers and the unchanged upstream QMI encoder/decoder. The actual
protocol and QMI/IIO objects also compiled and linked into their composite
object against Linux 7.3.1 AArch64 headers with `KCFLAGS=-Werror`. Only the
unchanged upstream QMI host object's deliberate unaligned wire accesses omit
alignment instrumentation; native parser/callback instrumentation remains.

The source now selects `CONFIG_IIO_UKE_SSC=m` and adds `xiaomi,uke-ssc-iio`
before the legacy description compatible in the early Uke DT transformation.
The ADSP phandle and the existing firmware-owned descriptions remain. Sensors
load from the normal root module set after firmware is available; they are
not required in the early initramfs. Existing libssc clients are preserved.

`packaging/native/copr-ssc1500.sh` prepares a retained release 1303 candidate
with SSC integration. It preserves panel/touch suppliers, bounded touch
recovery, native MEMLAT and Binder settings. Its remote checks repeat the
protocol/callback tests, exercise the actual early FDT helper, and require
complete module linkage, provider dependencies and the exact OF alias.
The pinned upstream QMI dispatcher/decoder files must match before staging.
These source checks and the earlier composite-object build do not yet
establish that the complete candidate passes or that sensors work on Uke.

[Candidate 11251503](https://copr.fedorainfracloud.org/coprs/mcc45tr/uke-linux-unstable/build/11251503/)
produced the `7.3.1-1500` source RPM and passed both compiler/sanitizer protocol
and actual-callback runs in the retained kernel build. The native-compatible
FDT/ADSP and foreign-board fixtures also passed. Complete kernel/module/package
results remain pending. The earlier 1400 submission stopped before producing
a source RPM because a concurrent custom build had already used release 1401;
the fresh-release guard remains unchanged.

Mount/clock handling, device lifecycle acceptance, vendor CCT/flicker semantics
and live physical sensor behavior remain unqualified. The driver reports host
receipt timestamps and does not infer a mounting matrix or DSP tick frequency.

The subsequent source extension adds the physical `sensor_temperature` datatype
with exact `sns_sensor_temperature.proto` metadata, a streaming endpoint and
one HIGH-accuracy Celsius value. It converts that value to millicelsius and
exposes `IIO_TEMP` with scale 1, as required by the Linux IIO temperature ABI.
Negative temperatures are retained; unreliable/lower-status, malformed and
nonfinite values are refused. The DT adds a firmware-owned temperature
description, without a new AP bus client. This is sensor-die temperature,
not an ambient-temperature, battery-temperature or thermal-limit substitute.
No factory calibration or thermal policy is changed.

That extension is not in the immutable 1500 candidate.
[Remote source check 11251535](https://copr.fedorainfracloud.org/coprs/mcc45tr/uke-linux-unstable/build/11251535/)
passed at 1.0-7. It covers the actual conversion, metadata/stream and scale
functions, positive/negative Celsius values, invalid accuracy and updated FDT.
The native AArch64 composite object also compiled against Linux 7.3.1.
A later combined kernel needs complete linkage and distinct device acceptance.
The protocol is the pinned Qualcomm
[physical sensor temperature API](https://github.com/qualcomm/sensinghub/blob/329551963bcc063f6a89f6cbca259c5b5c9c4e0b/apis/proto/sns_sensor_temperature.proto),
and the output unit follows the exact
[Linux IIO ABI](https://github.com/torvalds/linux/blob/79a907609d53d5cd645b42c11550d295d43abf99/Documentation/ABI/testing/sysfs-bus-iio).

`packaging/native/copr-hardware1710.sh` prepares the combined successor from
release 1600, retaining its secure RTC, SSC integration, Binder, MEMLAT and supplier/touch
changes. It adds the checked temperature source and NFC/IR updates qualified
in separate build 11251492. Full combined kernel/package and physical results
are required separately.

Combined kernel 1710/build11251648 subsequently passed complete kernel, module
and package checks. The first read-only observation of running1500 finds the
SSC module bound and ADSP running, with the file services active, but no native
SSC IIO devices registered. Sensor publication and physical behavior remain
unqualified. The boot log also records a driver-core managed-link warning.

The new source correction defers SSC probe until the ADSP supplier has fully
bound. The bound check and managed-link creation hold the supplier device lock
to exclude concurrent unbind; all paths unlock and retain ordinary reference
cleanup. It does not start ADSP or change the sensor protocol. Remote check
1.0-8 exercises the actual helper with fake providers and compiles the native
AArch64 objects. [Build11251980](https://copr.fedorainfracloud.org/coprs/mcc45tr/uke-linux-unstable/build/11251980/)
passed those checks. This correction is absent from immutable1710. The1900
producer retains the newer adaptive-L3 kernel1800 and adds the correction with
the checked DPU resource extension. Complete delivery and later boot/sensor
acceptance remain separate requirements.

4 November2026. A bounded query through the installed libssc route confirms
Report Large0x22 delivery. The native source now explicitly selects LARGE=1
in Control TLV0x10 and admits both documented0x21/0x22 indications through the
existing strict two-byte-length TLV decoder. Its16KiB limit, required/unique
TLVs and client/peer/generation checks remain in force. Unknown message IDs
are refused before decoding.

The wire contract is the installed-version upstream libqmi1.36.0
[SSC message schema](https://github.com/linux-mobile-broadband/libqmi/blob/defb13dcab0adc7f44f6741807244507a14a30c5/data/qmi-service-ssc.json)
and [report enumeration](https://github.com/linux-mobile-broadband/libqmi/blob/defb13dcab0adc7f44f6741807244507a14a30c5/src/libqmi-glib/qmi-enums-ssc.h).
The new remote check covers the actual request TLV, complete large-report
discovery/metadata/sample dispatch, maximum-size payloads and unknown-ID
refusal using synthetic identities.
[Build11252237](https://copr.fedorainfracloud.org/coprs/mcc45tr/uke-linux-unstable/build/11252237/)
passed those GCC/Clang sanitizer and actual AArch64 composite checks at1.0-9.
Immutable kernel1900 predates this correction. The1910 producer retains that
complete cohort and adds only the checked SSC sources and fixture, waiting for
the complete parent build before preparation. Full1910 delivery and corrected
native IIO publication remain pending.

## Positive transaction IDs, 5 November 2026

Running `7.3.1-12101-unstable` exposes all ten cached discovery attributes:
one service, no lookup fault or suspend, eight declared sensors, no connected
client or discovered/ready/registered sensors, and error `0/none`.

The source caller incorrectly treats a positive successful `qmi_txn_init()`
return as failure. [Linux 7.3.1](https://github.com/torvalds/linux/blob/79a907609d53d5cd645b42c11550d295d43abf99/drivers/soc/qcom/qmi_interface.c#L308)
returns the allocated transaction ID. The previous fake provider returned zero
regardless of ID and masked that contract. The correction refuses only negative
results and makes the test provider return its ID. Both compiler fixtures now
cover all 65,535 valid IDs and reject the exact former guard.

[COPR 11261868](https://copr.fedorainfracloud.org/coprs/mcc45tr/uke-linux-unstable/build/11261868/)
passed both compiler/sanitizer fixtures and the real AArch64 SSC/MSM/sensor
objects on the complete qualified source union. The
[source layer](../manifests/ssc-transaction-layer-20261105.json) retains all
other source, configuration, DT, firmware and hardware gates. Full kernel
delivery and observed native sensor publication remain separate requirements.
The [qualification receipt](../manifests/ssc-transaction-source-20261105.json)
records source `b38a29f`, retained configuration and the signed text-only package.
