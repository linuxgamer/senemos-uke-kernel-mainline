# SSC indications preceding enable acknowledgements

5 November 2026. Running 7.3.1-12203-unstable establishes the corrected native
SSC connection and registers six IIO devices. Bounded direct reads succeed for
accelerometer, gyroscope, magnetometer, proximity and sensor temperature. Front
ambient-light reads time out twice despite accepted metadata. Its physical
cause is not yet established. The remaining discovery error is -ENODEV at the
attributes stage; aggregate status does not identify the rejected sensor.

The current callback discards samples arriving before their enable response
marks the stream active. An on-change sensor may publish its first value once;
discarding that indication can leave a direct read waiting for another change.
The new layer stages at most one fully decoded value for the pending sensor
and publishes it only after the matching successful acknowledgement. Foreign
peer/client/SUID, invalid data, changed metadata, stale generation and failed or
missing acknowledgement do not publish. Newer staged timestamps replace older
ones. Request completion, invalidation and client teardown discard the cache.
No payload, SUID or calibration is exported, and the exact API/units remain.

Sources: Qualcomm sensinghub 329551963bcc063f6a89f6cbca259c5b5c9c4e0b,
`apis/proto/sns_client.proto`, `sns_std_sensor.proto` and
`sns_ambient_light.proto`; pinned upstream Linux QMI dispatch remains unchanged.
The ALS API specifies lux and raw ADC, so this change preserves the exact
two-value decoder. Uke metadata admits that API, but the observed timeout alone
does not prove indication order or a format mismatch. The donor survey's
Peridot registry and native libssc lifecycle are comparison evidence, not
replacement Uke firmware, a mount matrix or a portable calibration.

The local libssc v0.4.4 source archive at component commit
6f272d03b1e05d9d67ab50f29b75177c49141b74 has SHA256
716d6bd6b34d2d753060c6b54c9a87e34fae75b724c763bf9ef487efa3621587.
Its `src/libssc-sensor-light.c` accepts one or more intensity values and uses
the first. That GPL-3.0-or-later consumer is comparison material only; no code
is imported and its broader shape is not substituted for the pinned Qualcomm
two-value API or used to infer the cause of the observed timeout.

The COPR-only check uses the frozen 12203 source, full original preparation and
dependency set. Both compilers must reproduce the early-report assertion with
the exact former source, then pass stream/on-change, direct/buffered, foreign
identity, malformed data, stale generation, metadata, acknowledgement fault
and timestamp cases with the revised callbacks. All existing QMI-ID, ownership,
decoder, observation and sanitizer controls remain. The native SSC composite
must compile for AArch64 with -Werror; complete effective config comparison is
retained. This check packages text receipts only and builds no Image or final
module. Physical ALS, rear light/SAR, mounting, suspend and calibration remain
open until a subsequent coordinated kernel and device measurements establish them.

Revision 1 / COPR 11263021 passed the initial 112 ordering cases, then review
identified an uncovered fault → valid attributes → successful ACK sequence.
Source 0dcfd5b can publish the sample staged before that fault because metadata
recovery restores readiness without changing its revision. It is withdrawn from
full-kernel integration. Revision 2 discards staged data when the pending sensor
receives either a fault or any attributes replacement. The existing revision
and metadata admission remain unchanged. Actual callback tests cover 48 recovery
orders, including invalid metadata, fresh data after recovery and unrelated
sensor metadata that must preserve the pending sample. Both compilers must
reach the recovery assertion with the exact revision-1 source as an additional
negative control. The original pre-ACK-loss control and all previous tests remain.
Use the immutable `ssc-early-layer-v2-20261105.json`; revision 1 is historical.
