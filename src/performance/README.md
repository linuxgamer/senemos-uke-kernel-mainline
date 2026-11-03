# Cliffs7 LLCC source candidate

20 October 2026. Native Linux 7.2.11 source and host-only Fedora fixtures.
Patches 0095–0097 add the exact Cliffs7 policy, native five-window binding
and GPU supplier ordering to the 97-patch release-15 candidate. The first 94
patches retain their release-14 hashes. No tablet boot result is established.

The source uses MiCode Uke kernel `5712080a4b0c0b1a879e6d145c601c649ddaddfd`,
DT `94c84aeb9e517dbde546fc732033c184094c8e57`, the matching Nord 4 policy
`fc892483f1d61f245924681eb5abd563564d9cba` and upstream
`f47d223627f80cb7a1eb14c585fe6cb35de5e984`. Copyright and GPL attribution stay
with the translated data. See the [source/check manifest](../../manifests/llcc-source-candidate-20261020.json).

The driver candidate validates four 2 MiB banks, the OEM broadcast window,
hardware bank count and v5 version before configuration writes. It retains
all 17 OEM slices, using the native MODPE/WRCACHE names for the same numeric
use-case IDs. EDAC creation is disabled pending its exact access/IRQ contract.
Native Adreno already has the A7xx cache-field path; no Android GPU driver,
frequency lock or performance table is imported.

The source producer applies the three patches after the release-14 queue.
The following commands exercise the actual probe, configuration and A7xx
cache-field source, followed by the synthetic DT/binding cases:

```bash
bash tests/llcc-sm7675-contract.sh "$kernel"
bash tests/llcc-gpu-startup-contract.sh "$kernel/drivers/gpu/drm/msm/adreno/adreno_device.c"
CC=clang LLCC_TEST_CFLAGS='-O1 -fsanitize=address,undefined -fno-omit-frame-pointer' \
    bash tests/llcc-sm7675-contract.sh "$kernel"
dt-doc-validate "$kernel/Documentation/devicetree/bindings/cache/qcom,llcc.yaml"
dt-mk-schema -j "$kernel/Documentation/devicetree/bindings/cache/qcom,llcc.yaml" \
    "$kernel/Documentation/devicetree/bindings/nvmem/nvmem-consumer.yaml" > processed-schema.json
bash tests/llcc-sm7675-dt-contract.sh processed-schema.json
```

dt-schema 2026.09 and its unmodified upstream Python tools run only in the
existing host schema SDK. No Python or new runtime dependency is introduced
on the tablet. GCC fixtures use O0 to avoid alias-analysis false positives
across simulated regmap calls; Clang sanitizer checks use O1. The real LLCC
AArch64 object compiles with `KCFLAGS=-Werror`.

`prepare-llcc-dt.sh` accepts an already adapted Uke/SM7675 base DT with the
exact OEM Cliffs7 node. It writes a new mode-0600 candidate, preserves its
input and refuses an existing output, including a symlink. It converts only
the cache-controller resources, removes legacy configuration/debug metadata
and preserves the remaining graph. It is host-only and is not called by the
boot producer. The kernel boot helper performs the equivalent operation
under a separately selected source profile. Never substitute a candidate
for an accepted boot DT without matched-package and recovery checks.

The GPU platform probe now requires the enabled native Cliffs7 supplier to
bind before component registration. A managed device link is created before
the readiness check; legacy GPU/DT paths retain their existing behavior.
The actual baseline fails this requirement, and corrected GCC/Clang sanitizer
fixtures and the Adreno AArch64 object pass. These tests do not emulate the
driver core's managed-link cleanup or validate physical supplier removal.

The source boot producer accepts `UKE_LLCC_PROFILE=disabled|native-v1` and
defaults to disabled. On a fresh source tree with the ordinary adaptation
and all three candidate patches applied, native-v1 runs the LLCC/GPU/boot
source fixtures before installing the enabled helper. The caller validates
the stock Uke tuple, admits the original cache graph before copying, then
transforms only its private DT copy. Generated profile selection and helper
hashes are recorded. An unknown profile or mismatched/disabled cache graph
is refused. The release-15 package selects native-v1 through the hashed
`packaging/native/llcc-profile` asset; the standalone helper still defaults
to disabled. Audio remains disabled.

```bash
bash tests/llcc-boot-fdt-contract.sh "$kernel"
UKE_LLCC_PROFILE=native-v1 bash src/boot/prepare-abl-source.sh "$kernel" "$output"
```

The actual boot helper passes eight admission faults, seven write faults,
space-exhaustion and input-preservation fixtures against bundled libfdt.
GCC and Clang ASan/UBSan pass. The earlier isolated ARM64 boot-object checks
covered the source profile enabled and disabled and restored that test tree
to disabled. The default host translation was byte-identical after preprocessing.

The release-15 local source RPM now passes fresh 97-patch native preparation
and LLCC/Adreno/boot AArch64 objects with KCFLAGS=-Werror. Fresh preparation
exposed a fixture dependency on Linux's omitted fdt_check.c; the fixture now
uses the same pinned, attributed DTC validator directly. Full binary packaging
is the next acceptance gate.
Actual GPU/provider ordering and lifetime, four-bank/v5 admission,
partial-programming recovery, cache coherency, suspend and performance still
require a recoverable device test. Source fixtures do not establish any of
those results. Preserve the accepted rollback, charging and thermal policy.
