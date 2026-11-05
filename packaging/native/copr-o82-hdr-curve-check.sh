#!/usr/bin/env bash
# Source/check production only in COPR. Never run on the target tablet.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
owner=$(cd -- "$(dirname -- "$0")/../.." && pwd)
output=$(realpath -m "${1:?Pass the remote source result directory}")
revision=${2:-1}
[[ $revision =~ ^[1-9][0-9]*$ ]]
bash "$owner/packaging/native/refuse-published-release.sh" uke-o82-hdr-curve-check "1.0-$revision"
(cd "$owner"; jq -r '.inputs[]|.sha256+"  "+.path' manifests/o82-hdr-curve-source-20261105.json | sha256sum -c --strict --quiet -)
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
mkdir -p "$output" "$stage/uke-o82-hdr-curve-check-1.0"
git -C "$owner" archive HEAD src/display/o82-hdr-tonemap.h tests/o82-hdr-curve-contract.cpp \
    docs/O82-HDR-TONEMAP-REVIEW.md manifests/o82-hdr-curve-source-20261105.json LICENSE |
    tar -xf - -C "$stage/uke-o82-hdr-curve-check-1.0"
git -C "$owner" rev-parse HEAD > "$stage/uke-o82-hdr-curve-check-1.0/source-commit"
tar --sort=name --mtime=@1793836800 --owner=0 --group=0 --numeric-owner \
    -czf "$output/uke-o82-hdr-curve-check-1.0.tar.gz" -C "$stage" uke-o82-hdr-curve-check-1.0
cat > "$output/uke-o82-hdr-curve-check.spec" <<'SPEC'
Name: uke-o82-hdr-curve-check
Version: 1.0
Release: @REVISION@%{?dist}
Summary: Synthetic checks of typed native HDR luminance conversion
License: MIT
Source0: %{name}-%{version}.tar.gz
BuildArch: noarch
BuildRequires: gcc-c++ clang compiler-rt coreutils jq sed
%description
Exact integer IEEE754 and analytic power-law checks of the offline typed
HDR luminance core, including forward/inverse plateaus and source/panel
normalization. A controlled wrong-owner implementation must fail its required
assertion. Only synthetic inputs are used. The RPM contains text receipts and
licenses; no executable, firmware or private values. XML/matrix/metadata policy,
complete kernel integration and physical HDR/color remain unqualified.
%prep
%autosetup
jq -r '.inputs[]|.sha256+"  "+.path' manifests/o82-hdr-curve-source-20261105.json | sha256sum -c --strict -
%build
set -e
mkdir mutant
sed 's/axis\[middle\] < value/axis[middle] <= value/' src/display/o82-hdr-tonemap.h > mutant/o82-hdr-tonemap.h
! cmp -s src/display/o82-hdr-tonemap.h mutant/o82-hdr-tonemap.h
for compiler in g++ clang++; do
 tag=$(echo "$compiler" | tr + x)
 "$compiler" -std=c++20 -O2 -UNDEBUG -Wall -Wextra -Werror -ffp-contract=fast \
   -Isrc/display tests/o82-hdr-curve-contract.cpp -o "$tag-optimized"
 "$compiler" -std=c++20 -O1 -g -UNDEBUG -Wall -Wextra -Werror -ffp-contract=fast \
   -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer \
   -Isrc/display tests/o82-hdr-curve-contract.cpp -o "$tag-sanitized"
 "$compiler" -std=c++20 -O2 -UNDEBUG -Wall -Wextra -Werror -Imutant \
   tests/o82-hdr-curve-contract.cpp -o "$tag-mutant"
done
%install
install -d %{buildroot}%{_docdir}/%{name}
%check
set -e
set -o pipefail
receipt=%{buildroot}%{_docdir}/%{name}/checks.txt
for compiler in gxx clangxx; do
 set +e
 ./$compiler-mutant --inverse-plateau-control > mutant-output.txt 2>&1
 status=$?
 set -e
 test "$status" = 42
 grep -Fx 'Required inverse plateau ownership assertion rejected mutant' mutant-output.txt | tee -a "$receipt"
 ./$compiler-optimized | tee -a "$receipt"
 ./$compiler-sanitized | tee -a "$receipt"
done
install -m644 source-commit %{buildroot}%{_docdir}/%{name}/source-commit
install -m644 manifests/o82-hdr-curve-source-20261105.json %{buildroot}%{_docdir}/%{name}/source-manifest.json
%files
%license LICENSE
%{_docdir}/%{name}/*
%changelog
* Thu Nov 05 2026 Uke contributors - 1.0-@REVISION@
- Check typed HDR luminance conversion without private inputs or target changes.
SPEC
sed -i "s/@REVISION@/$revision/g" "$output/uke-o82-hdr-curve-check.spec"
actual=$(rpmspec --target aarch64 -q --srpm --qf '%{NAME} %{VERSION}-%{RELEASE}' \
    "$output/uke-o82-hdr-curve-check.spec")
printf 'Source package identity: %s\n' "$actual"
case "$actual" in
    "uke-o82-hdr-curve-check 1.0-$revision"|"uke-o82-hdr-curve-check 1.0-$revision.fc46") ;;
    *) echo 'Unexpected HDR source package identity' >&2; exit 1 ;;
esac
