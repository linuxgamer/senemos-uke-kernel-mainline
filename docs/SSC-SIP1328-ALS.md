# Uke logical rear ambient-light endpoint

5 November 2026. On `7.3.1-12204-unstable`, bounded metadata requests identify
one available `sip1328 back ambient` endpoint of type `ambient_light_back`,
API `sns_ambient_light.proto`, on-change mode and `physical=false`. A single
metadata-gated, non-wakeup request 514 returns event 1025 with six finite values,
accuracy HIGH and a nonnegative first field. Raw values and identities remain
private. A separate SAR lookup returns no SUID; that does not prove absent
hardware or authorize an AP probe or invented IIO device.

The primary [Qualcomm standard schema](https://github.com/qualcomm/sensinghub/blob/9afa5c27b305761945e233504030ed11ee57b157/apis/proto/sns_std_sensor.proto),
commit `9afa5c27b305761945e233504030ed11ee57b157`,
defines attribute 21 as the physical-versus-virtual/fusion distinction, with
default false. The file is attributed to Qualcomm Technologies under
BSD-3-Clause. Availability is a separate attribute. The ambient-light API
defines its first standard-event field in lux. The observed six-value OEM
extension retains no verified unit mapping for the other fields.

The current native admission requires every endpoint to be physical, so it
rejects this available logical rear ALS. Its two-value sample requirement
would separately reject the observed six-value event. The new source patch
admits only this exact named rear datatype without the physical flag and
accepts exactly two or six finite values. It publishes only the first lux
field. Exact API/type, availability, HLOS, stream/rate, client/peer/SUID,
generation, status and ACK gates remain. Other sensor types and supplier names
keep the physical requirement and existing dimensions. The qualified STK3BCx
front-light correction is retained. The existing firmware-owned Uke DT entry
provides this endpoint; the ADSP keeps ownership of its sensor buses.

Evidence uses the installed native socat transport with bounded public metadata
decoding. Requests match the retained native metadata and on-change golden
bytes. The transport connects to the uniquely discovered SSC endpoint and
checks QMI client/SUID/type/length, but does not export recvmsg sender addresses.
This is protocol comparison evidence, not a replacement for the kernel's peer
admission, optical accuracy, orientation, calibration or lifecycle tests.
No new binary, local compilation, factory request or calibration write occurs.

The unchanged [libssc](https://codeberg.org/DylanVanAssche/libssc)0.4.4 archive
SHA256 `716d6bd6b34d2d753060c6b54c9a87e34fae75b724c763bf9ef487efa3621587`,
`src/libssc-sensor-light.c`, is comparison evidence for consuming the first
light field. It is attributed to Dylan Van Assche under GPL-3.0-or-later; no
implementation is copied into the kernel. Exact Uke OSS
lacks the ADSP implementation; the pinned Peridot registry lifecycle and
upstream SMGR protocol do not define this Uke SSC endpoint. No registry,
calibration, bus resource or mount matrix is transplanted.

The source-only check retains full 12204 and the qualified front layer, proves
both original and front-only refusals, exercises synthetic rear metadata and
two/six-value reports, then compiles the real AArch64 SSC composite with
`-Werror`. [COPR 11264114](https://copr.fedorainfracloud.org/coprs/mcc45tr/uke-linux-unstable/build/11264114/)
succeeded on 5 November 2026 using source
`f4b5020e3bcf25ec23ee3831960962c9a2e0439f`. Both GCC and Clang reproduce
the original rejection and the front-only metadata and vector rejections. Each
compiler passes 68 rear metadata, 162 vector and 16 actual callback/ACK cases,
retaining 186 front vectors, four front callback cases and all prior controls.
The real AArch64 SSC composite compiles with `-Werror`.

The independently verified, trusted signed text RPM preserves the complete
12204 source composition except for eight declared front/rear ALS layer keys.
Its payload contains only receipts and licenses, without executable code or
scriptlets; it was inspected without installation or a retained RPM. The
[qualification manifest](../manifests/ssc-sip1328-als-layer-20261105.json)
records exact source, object, configuration, log and receipt digests. Complete
cumulative kernel integration, matching boot and physical rear-light/unit/
lifecycle acceptance remain pending.
