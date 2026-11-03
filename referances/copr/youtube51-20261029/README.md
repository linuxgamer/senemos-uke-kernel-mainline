# Linux 7.3.0-51 video source

30 October 2026. [COPR 11228360](https://copr.fedorainfracloud.org/coprs/mcc45tr/uke-linux-unstable/build/11228360/)
built six `7.3.0-51.fc46.aarch64` RPMs on Fedora Rawhide AArch64. Source-function
contracts, the full kernel/modules build and package checks passed. Independent
inspection verified all six signatures and digests with the pinned unstable key,
plus matching Iris, kernel and boot-manifest identities. The
[build receipt](build11228360.json) records those identities.

The archive adds four bounded SM7675 Iris decoder changes to the exact
release-50 source from [COPR 11222548](https://copr.fedorainfracloud.org/coprs/mcc45tr/uke-linux-test/build/11222548/).
It preserves that kernel's display/DSC and boot changes. The base SRPM SHA256 is
`e76815db7f6d88758e0709574f69137467005d4d331a31e8eeaa7c4ed796ac44`;
its source commit is `8cbe0435f05c8a26dd891bd842ec8533a1504421`.

The [complete source patch](../../../patches/copr/youtube51-on-release50.patch)
is retained alongside the [exact COPR source recipe](../../../.copr/youtube51-source.sh).
The video source commit is `1024dc8aa5cddc73c5bb8f6f7949f62f1bda941f`.
The checksum file binds the source-only archive; no compiled payload, firmware
or media sample is included. All compilation occurred in COPR.

This is an experimental candidate. No release-51 installation or activation is
performed by this work. Sustained physical 4K60 presentation, thermal endurance
and HDR scanout remain unqualified; earlier release-49 measurements do not
establish those results for release51.
