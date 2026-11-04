#!/usr/bin/env bash
# COPR source producer only; never build or run on the tablet.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
owner=$(cd -- "$(dirname -- "$0")/../.." && pwd)
output=$(realpath -m "${1:?Pass the remote source result directory}")
bash "$owner/packaging/native/refuse-published-release.sh" uke-o82-color-profile 0.7.0-1
(cd "$owner"; jq -r '.inputs[]|.sha256+"  "+.path' \
    manifests/o82-stock-profile-source-20261105.json | sha256sum -c --strict --quiet -)
mkdir -p "$output"
while IFS=$'\t' read -r path name; do
    install -m644 "$owner/$path" "$output/$name"
done <<'SOURCES'
packaging/uke-o82-color-profile.spec	uke-o82-color-profile.spec
src/display/o82-color-profile.cpp	o82-color-profile.cpp
src/display/o82-stock-profile.hpp	o82-stock-profile.hpp
src/display/stock-profile/local.hpp	local.hpp
src/display/stock-profile/oem-video.hpp	oem-video.hpp
tests/o82-stock-profile-contract.cpp	o82-stock-profile-contract.cpp
docs/O82-COLOR-PROFILE.md	O82-COLOR-PROFILE.md
LICENSE	LICENSE
LICENSES/GPL-2.0-only.txt	GPL-2.0-only.txt
src/display/uke-o82-hdr-format.h	uke-o82-hdr-format.h
tests/o82-hdr-edid-contract.cpp	o82-hdr-edid-contract.cpp
src/display/o82-regdma.h	o82-regdma.h
src/display/o82-color-firmware.h	o82-color-firmware.h
src/display/o82-memory-format.h	o82-memory-format.h
src/display/o82-memory-color.h	o82-memory-color.h
tests/o82-memory-payload-contract.cpp	o82-memory-payload-contract.cpp
tests/o82-memory-payload-contract.sh	o82-memory-payload-contract.sh
src/display/dpu_o82_lutbus.c	dpu_o82_lutbus.c
src/display/dpu_o82_lutbus.h	dpu_o82_lutbus.h
src/display/dpu_o82_profiles.c	dpu_o82_profiles.c
src/display/dpu_o82_profiles.h	dpu_o82_profiles.h
tests/o82-profile-loader-contract.c	o82-profile-loader-contract.c
tests/o82-profile-loader-contract.sh	o82-profile-loader-contract.sh
tests/o82-gamut-grid-contract.cpp	o82-gamut-grid-contract.cpp
src/display/o82-sixzone-format.h	o82-sixzone-format.h
src/display/o82-sixzone.h	o82-sixzone.h
tests/o82-sixzone-payload-contract.cpp	o82-sixzone-payload-contract.cpp
tests/o82-sixzone-contract.cpp	o82-sixzone-contract.cpp
src/display/o82-hsic.h	o82-hsic.h
src/display/o82-hsic-format.h	o82-hsic-format.h
tests/o82-hsic-payload-contract.cpp	o82-hsic-payload-contract.cpp
tests/o82-hsic-contract.cpp	o82-hsic-contract.cpp
SOURCES
# Retain the actual pre-fix implementation for an independent negative control.
before=f414294fae8932dbe53c253cd498226f9ca8f0f9
if ! git -C "$owner" cat-file -e "$before^{commit}"; then
    git -C "$owner" fetch --depth=1 origin "$before"
fi
git -C "$owner" show "$before:src/display/o82-color-profile.cpp" > \
    "$output/o82-color-before-grid.cpp"
test "$(git -C "$owner" hash-object "$output/o82-color-before-grid.cpp")" = \
    34b18cb8e2361e5f562df944b90b2eebb3798caa
printf 'Color utility source %s; actual pre-fix source %s\n' \
    "$(git -C "$owner" rev-parse HEAD)" "$before"
test "$(rpmspec --target aarch64 -q --srpm --qf '%{NAME}-%{VERSION}-%{RELEASE}' \
    "$output/uke-o82-color-profile.spec")" = uke-o82-color-profile-0.7.0-1.fc46
