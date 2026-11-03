#!/usr/bin/env bash
# Exercise the actual inspector and producer guards; no device or boot write.
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'find "$work" -depth -delete' EXIT
"${CXX:-g++}" -std=c++17 -O2 -Wall -Wextra -Werror "$root/src/boot/boot-status.cpp" -o "$work/status"
mkdir -p "$work/root/sys/firmware/devicetree/base" "$work/root/proc/sys/kernel"
printf 'xiaomi,uke\0qcom,sm7675\0' > "$work/root/sys/firmware/devicetree/base/compatible"
for release in 7.3.0-1-kvm 7.2.12-9-kvm 7.3.0-1 7.3.1-1 7.3.17-39 7.2.12-37 7.2.10-senemos.1; do
    printf '%s\n' "$release" > "$work/root/proc/sys/kernel/osrelease"
    "$work/status" --root "$work/root" --identity | jq -e '.selected_kernel_release and (.hardware_acceptance_granted|not)' >/dev/null
done
for release in 7.3.0-1-kvm-exit 7.3.0-0 7.3.0-01 7.3.00-1 7.3.01-1 7.3.-1 7.3.0-1-unstable 7.3.1-1-unstable 7.4.0-1 7.2.0-1; do
    printf '%s\n' "$release" > "$work/root/proc/sys/kernel/osrelease"
    if "$work/status" --root "$work/root" --identity > "$work/result"; then exit 1; fi
    jq -e '(.selected_kernel_release|not) and (.hardware_acceptance_granted|not)' "$work/result" >/dev/null
done
build_guard=$(sed -n '/^\[\[ \$release =~ /p' "$root/src/boot/build-payload.sh")
base_guard=$(sed -n '/^\[\[ \$# == 2 && \$2 =~ /p' "$root/src/boot/make-initramfs-base.sh")
release=7.3.0-1 jobs=2
eval "$build_guard"
(set -- fixture "$release"; eval "$base_guard")
for release in 7x3y0-1 7.3.0-1-unstable; do
    if (eval "$build_guard") || (set -- fixture "$release"; eval "$base_guard"); then exit 1; fi
done
echo 'Read-only mainline 7.3 identity, producer ABI, legacy fallback and malformed/foreign refusals passed'
