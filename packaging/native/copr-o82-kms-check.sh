#!/usr/bin/env bash
# COPR only: check the complete retained KMS preparation and new REGDMA hooks.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
[[ $(rpm --eval '%{_host_cpu}') == aarch64 && $(rpm --eval '%{fedora}') == 46 ]]
owner=$(cd -- "$(dirname -- "$0")/../.." && pwd)
output=$(realpath -m "${1:?Pass the remote source result directory}")
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
[[ $(curl -fsSL --max-time 45 https://copr.fedorainfracloud.org/api_3/build/11251559 | jq -er .state) == succeeded ]]
curl -fLsS --retry 2 --proto '=https' --proto-redir '=https' \
    https://download.copr.fedorainfracloud.org/results/mcc45tr/uke-linux-unstable/srpm-builds/11251559/senemos-uke-linux-kernel-mainline-7.3.1-1600.src.rpm \
    -o "$stage/parent.src.rpm"
[[ $(rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}' "$stage/parent.src.rpm") == senemos-uke-linux-kernel-mainline-7.3.1-1600 ]]
[[ $(rpm -qp --qf '%{SHA256HEADER}' "$stage/parent.src.rpm") == f71eea4d521b2937c08d81886c9338e0908834491ee9bb35238a2b72171f58e5 ]]
[[ $(rpm -qp --qf '%{PAYLOADSHA256}' "$stage/parent.src.rpm") == b4f6340ccd8cd72fcfba6d462b869621eaf62793b28abc083bad53072838d5e7 ]]
rpmkeys --checksig --nosignature --verbose "$stage/parent.src.rpm"
rpm2cpio "$stage/parent.src.rpm" > "$stage/parent.cpio"
cpio -t --quiet < "$stage/parent.cpio" > "$stage/entries"
awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' "$stage/entries"
mkdir -p "$output"
(cd "$output"; cpio -idm --quiet --no-absolute-filenames < "$stage/parent.cpio")
parent=$output/senemos-uke-linux-kernel-mainline.spec
[[ $(grep -c '^Source9:' "$parent") == 0 ]]
[[ $(grep -Fxc '%prep' "$parent") == 1 && $(grep -Fxc '%build' "$parent") == 1 ]]
# Keep every retained source and its original signed-source/adaptation preparation.
find "$output" -maxdepth 1 -type f ! -name '*.spec' -print0 | sort -z | \
    xargs -0 sha256sum > "$stage/retained.sha256"
mkdir -p "$stage/addon"
git -C "$owner" archive --prefix=native-addon/ HEAD \
    src/display/dpu_o82_platform.c src/display/dpu_o82_platform.h \
    src/display/dpu_o82_regdma.c src/display/dpu_o82_regdma.h src/display/o82-regdma.h \
    src/display/dpu_o82_lutbus.c src/display/dpu_o82_lutbus.h src/display/dpu_o82_profiles.h \
    src/display/uke-o82-hdr-format.h src/display/prepare-o82-regdma.sh \
    src/display/sm7675-uke-native-display.dtso src/display/bindings/qcom,sm7675-dpu.yaml \
    patches/display/0072-o82-regdma-resource.patch \
    tests/o82-platform-contract.sh tests/o82-lutbus-contract.c tests/o82-lutbus-contract.sh \
    packaging/native/check-o82-kms.sh LICENSE LICENSES/GPL-2.0-only.txt | \
    tar -xf - -C "$stage/addon"
git -C "$owner" rev-parse HEAD > "$stage/addon/native-addon/source-commit"
tar --sort=name --mtime="@$(git -C "$owner" show -s --format=%ct HEAD)" \
    --owner=0 --group=0 --numeric-owner -cJf "$output/uke-o82-kms-check-source.tar.xz" \
    -C "$stage/addon" native-addon
spec=$output/uke-o82-kms-check.spec
awk '
 /^%description/ {exit}
 /^Name:/ {$0="Name: uke-o82-kms-check"}
 /^Release:/ {$0="Release: 2%{?dist}"}
 /^Summary:/ {$0="Summary: Retained Uke DPU KMS and REGDMA source integration check"}
 /^(Requires|Provides|Recommends):/ {next}
 {print}
' "$parent" > "$spec"
cat >> "$spec" <<'SPEC'
Source9: uke-o82-kms-check-source.tar.xz

%description
Remote check of the complete retained Linux 7.3.1 Uke source preparation,
REGDMA resource hooks, linked MSM display object and both supplier DT overlays.
Only a text receipt is packaged. No kernel, module or boot image is delivered.

SPEC
awk '/^%prep$/ {emit=1} /^%build$/ {exit} emit {print}' "$parent" >> "$spec"
cat >> "$spec" <<'SPEC'
tar -xJf %{SOURCE9}
bash native-addon/src/display/prepare-o82-regdma.sh "$PWD"

%build
set -o pipefail
bash native-addon/packaging/native/check-o82-kms.sh "$PWD" %{_uke_out} \
    | tee %{_topdir}/o82-kms-checks.txt

%install
install -Dm644 %{_topdir}/o82-kms-checks.txt \
    %{buildroot}%{_docdir}/%{name}/checks.txt

%check
test -s %{buildroot}%{_docdir}/%{name}/checks.txt

%files
%license native-addon/LICENSE native-addon/LICENSES/GPL-2.0-only.txt
%{_docdir}/%{name}/checks.txt

%changelog
* Tue Nov 03 2026 Uke contributors - 7.3.1-2
- Include the shared profile declarations used by the LUT stream checks.

* Tue Nov 03 2026 Uke contributors - 7.3.1-1
- Compile the actual adapted KMS and REGDMA resource connection.
- Check both compiled supplier overlays and the new binding document.
SPEC
sha256sum -c "$stage/retained.sha256"
rm "$parent"
[[ $(rpmspec --target aarch64 -q --srpm --qf '%{NAME}-%{VERSION}-%{RELEASE}' "$spec") == uke-o82-kms-check-7.3.1-2.fc46 ]]
