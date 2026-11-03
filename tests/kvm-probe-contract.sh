#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# == 1 && -x $1 ]] || exit 64
probe=$(realpath "$1")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
status=0
"$probe" unexpected > "$tmp/output" 2> "$tmp/error" || status=$?
[[ $status == 64 && ! -s $tmp/output ]]
grep -F 'Usage: uke-kvm-probe' "$tmp/error" >/dev/null
status=0
"$probe" > "$tmp/result" 2> "$tmp/error" || status=$?
if [[ $(uname -m) != aarch64 ]]; then
    [[ $status == 3 ]]
    [[ $(cat "$tmp/result") == '{"status":"unsupported-architecture","guest_ran":false}' ]]
elif [[ ! -e /dev/kvm ]]; then
    [[ $status == 2 ]]
    [[ $(cat "$tmp/result") == '{"status":"blocked-no-kvm","guest_ran":false}' ]]
else
    [[ $status == 0 ]]
    [[ $(cat "$tmp/result") == '{"status":"kvm-guest-pass","guest_ran":true,"api_version":12}' ]]
fi
echo 'Native KVM probe argument and environment contract passed'
