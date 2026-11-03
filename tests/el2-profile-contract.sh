#!/usr/bin/env bash
# Source admission only; no firmware calls or hardware acceptance.
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
bash "$root/src/boot/admit-el2-profile.sh" normal
bash "$root/src/boot/admit-el2-profile.sh" el2-require
if bash "$root/src/boot/admit-el2-profile.sh" el2-exit-experimental; then
    echo 'Unreviewed firmware exit was admitted' >&2; exit 1
else
    [[ $? == 78 ]]
fi
family=$(sed -n 's/^Name: //p' "$root/packaging/senemos-uke-linux-kernel-mainline.spec")
config=$root/packaging/native/native.config
if [[ $family == senemos-uke-linux-kernel-mainline ]]; then
    config=$root/packaging/kvm/binder.config
    # The ordinary producer must not select a CPU-parking experimental entry.
    ! grep -Eq '^CONFIG_QCOM_UKE_(EL2_ENTRY|GUNYAH_EXIT)=y' "$root/packaging/native/native.config"
    ! grep -Fq 'prepare-el2-source.sh' "$root/packaging/native/prepare.sh"
fi
grep -Fx 'CONFIG_ANDROID_BINDER_IPC=y' "$config"
grep -Fx 'CONFIG_ANDROID_BINDERFS=y' "$config"
grep -Fx 'CONFIG_ANDROID_BINDER_DEVICES=""' "$config"
grep -Fq 'x23, x0' "$root/src/boot/uke-el2-entry.S"
grep -Fq 'sigaction(SIGALRM' "$root/src/kvm/probe.cpp"
if [[ $family == senemos-uke-linux-kernel-mainline-kvm ]] && grep -Eq '^%(post|posttrans|pre|pretrans)($|[[:space:]])' "$root/packaging/senemos-uke-linux-kernel-mainline.spec"; then
    echo 'Experimental kernel must not activate itself' >&2; exit 1
fi
