#!/usr/bin/env bash
# Source admission only; never inspect or change a connected device.
set -Eeuo pipefail
case ${1:-} in
    normal|el2-require) ;;
    el2-exit-experimental)
        echo 'EL2 firmware exit is not admitted: the Uke service, all-CPU return and DMA/SMMU contract are unverified; firmware allowlist is empty.' >&2
        exit 78;;
    *) echo 'Expected normal, el2-require or el2-exit-experimental' >&2; exit 64;;
esac
