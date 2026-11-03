#!/usr/bin/env bash
# Host-only compilation and refusals, never a real guest or device probe.
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
for source in probe status; do
    "${CXX:-g++}" -std=c++17 -O2 -Wall -Wextra -Werror "$root/src/kvm/$source.cpp" -o "$work/$source"
    status=0
    "$work/$source" unexpected > "$work/out" 2> "$work/err" || status=$?
    [[ $status == 64 && ! -s $work/out ]]
done
if [[ $(uname -m) != aarch64 ]]; then
    bash "$root/tests/kvm-probe-contract.sh" "$work/probe"
else
    # Compile only: do not inspect /dev/kvm or execute a guest during source checks.
    echo 'AArch64 guest execution deliberately not requested by source fixture'
fi
bash "$root/src/boot/admit-el2-profile.sh" normal
bash "$root/src/boot/admit-el2-profile.sh" el2-require
status=0
bash "$root/src/boot/admit-el2-profile.sh" el2-exit-experimental 2> "$work/refusal" || status=$?
[[ $status == 78 ]]
echo 'KVM helper compilation, argument refusal and firmware-exit admission passed'
