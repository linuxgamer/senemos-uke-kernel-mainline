# Uke STK3BCx ambient-light vectors

5 November 2026. On `7.3.1-12204-unstable`, bounded native IIO front-light
reads time out while the installed libssc client receives an event1025 with
six finite values and accuracy HIGH. Its metadata names `stk_stk3bcx`, datatype
`ambient_light`, API `sns_ambient_light.proto`, available and physical. Libssc
publishes the first value as lux. Raw packets and readings remain private.

The native caller requires exactly two values, so it rejects this observed
six-value event independently of the already corrected pre-ACK ordering. The
common decoder remains bounded at16 values; no parser limit changes are needed.

The source patch accepts exactly two or six values only for that named front
ALS endpoint. All values must remain finite and all existing metadata, status,
ownership, ordering and scaling checks remain. Only the first lux value is
published. No units are assigned to the extra fields. Other light suppliers,
rear light, motion and temperature retain their existing dimensions.

The primary Qualcomm schema at `qualcomm/sensinghub` commit
`329551963bcc063f6a89f6cbca259c5b5c9c4e0b`,
`apis/proto/sns_ambient_light.proto`, identifies the first field as lux. The
current file at `9afa5c27b305761945e233504030ed11ee57b157` retains that contract;
its change is the SPDX license correction to BSD-3-Clause. This six-value OEM
extension is observed Uke behavior, not the standard two-value shape. No
Qualcomm implementation code or device payload is imported.

The unchanged local libssc0.4.4 archive and its installed light validity patch
consume the first finite, nonnegative intensity with a valid status. This is
comparison evidence, not GPL3 code imported into the kernel. Exact Uke OEM
sources do not contain the ADSP implementation. The pinned Peridot registry
lifecycle and upstream SMGR driver do not define this Uke SSC event layout.

Synthetic actual-callback tests cover exact/near/foreign supplier names,
standard and OEM shapes, other light endpoints, packed/unpacked floats,
non-finite extra fields, unreliable/negative data and small/large reports
before ACK. They contain no device values or identifiers. COPR compilation,
full cumulative integration, a matching kernel boot and physical light/unit/
lifecycle checks are separate gates. This source change alone does not prove
that native ALS works or close the remaining sensor requirements.

Initial check 11263691 reproduces the old vector refusal under both compilers,
then stops in the new metadata fixture: the synthetic sensor was not declared
before its metadata report. The driver correctly ignores that undeclared
sensor. Corrected check revision 2 declares it first.

COPR [11263802](https://copr.fedorainfracloud.org/coprs/mcc45tr/uke-linux-unstable/build/11263802/)
passes at source `9896de456f92c9a0a27c5509c80c6bbf38fc90b5`: both exact former-source
compiler refusals,186 vector cases and4 real report/metadata/ACK cases per
compiler, all retained cumulative controls and the AArch64 SSC composite
object with `-Werror`. The signed 47,398-byte text RPM verifies the trusted
repository key, exact source/spec/composition and header/payload digests.
It has no scriptlets or executable payload and was not installed. Full
cumulative kernel integration and physical ALS/unit/lifecycle tests remain open.
