#!/usr/bin/env bash
# Exercise the actual read-only inspector against synthetic identity files.
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
"${CXX:-g++}" -std=c++17 -O2 -Wall -Wextra -Werror "$root/src/boot/boot-status.cpp" -o "$work/status"
mkdir -p "$work/root/sys/firmware/devicetree/base" "$work/root/proc/sys/kernel"
printf 'xiaomi,uke\0qcom,sm7675\0' > "$work/root/sys/firmware/devicetree/base/compatible"
for release in 7.3.0-1-unstable 7.3.0-12-unstable 7.2.12-1; do
    printf '%s\n' "$release" > "$work/root/proc/sys/kernel/osrelease"
    "$work/status" --root "$work/root" --identity | jq -e '.selected_kernel_release and (.hardware_acceptance_granted|not)' >/dev/null
done
for release in 7.3.0-0-unstable 7.3.0-01-unstable 7.3.0--unstable 7.3.0-1 7.3.0-1-unstable-extra 7.4.0-1-unstable; do
    printf '%s\n' "$release" > "$work/root/proc/sys/kernel/osrelease"
    if "$work/status" --root "$work/root" --identity > "$work/result"; then exit 1; fi
    jq -e '(.selected_kernel_release|not) and (.hardware_acceptance_granted|not)' "$work/result" >/dev/null
done
echo 'Read-only unstable identity and malformed/foreign release refusals passed'
