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
The ADSP phandle and all nine firmware-owned descriptions remain. Sensors
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
