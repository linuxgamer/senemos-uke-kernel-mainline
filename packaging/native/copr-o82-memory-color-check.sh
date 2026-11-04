#!/usr/bin/env bash
# COPR only: generic memory-color arithmetic with synthetic protocol fields.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
root=$(cd -- "$(dirname -- "$0")/../.." && pwd)
output=$(realpath -m "${1:?Pass the remote source result directory}")
revision=${2:-1}
[[ $revision =~ ^[1-9][0-9]*$ ]]
bash "$root/packaging/native/refuse-published-release.sh" uke-o82-memory-color-check "1.0-$revision"
(cd "$root"; jq -r '.inputs[]|.sha256+"  "+.path' \
    manifests/o82-memory-color-source-20261104.json | sha256sum -c --strict --quiet -)
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
mkdir -p "$output" "$stage/uke-o82-memory-color-check-1.0"
git -C "$root" archive HEAD src/display/o82-memory-color.h tests/o82-memory-color-contract.cpp \
    src/display/o82-memory-format.h src/display/o82-hsic-format.h \
    src/display/o82-sixzone-format.h src/display/uke-o82-hdr-format.h \
    tests/o82-memory-pipeline-contract.cpp \
    manifests/o82-memory-color-source-20261104.json LICENSE |
    tar -xf - -C "$stage/uke-o82-memory-color-check-1.0"
tar --sort=name --mtime=@1793750400 --owner=0 --group=0 --numeric-owner \
    -czf "$output/uke-o82-memory-color-check-1.0.tar.gz" -C "$stage" uke-o82-memory-color-check-1.0
cat > "$output/uke-o82-memory-color-check.spec" <<'SPEC'
Name: uke-o82-memory-color-check
Version: 1.0
Release: @REVISION@%{?dist}
Summary: Synthetic arithmetic checks for O82 memory-color conversion
License: MIT
Source0: %{name}-%{version}.tar.gz
BuildArch: noarch
BuildRequires: bash gcc-c++ clang compiler-rt coreutils jq
%description
Remote optimized and sanitized checks of typed memory-color adjustment, extent,
named regions, reciprocal, blend and hold fields. An independent integer IEEE754
oracle checks the binary32/binary64 instruction boundaries. The semantic bridge
also checks the kernel integer validator. Only synthetic inputs are
used. The package contains a text receipt, with no executable, private profile,
firmware or device writer. This does not qualify JSON mapping, shared PA memory
or protection programming, a cumulative kernel, HDR or physical image quality.
%prep
%autosetup
jq -r '.inputs[]|.sha256+"  "+.path' manifests/o82-memory-color-source-20261104.json | sha256sum -c --strict -
%build
g++ -std=c++20 -O2 -UNDEBUG -Wall -Wextra -Werror -ffp-contract=fast -Isrc/display \
    tests/o82-memory-color-contract.cpp -o memory-optimized
clang++ -std=c++20 -O1 -g -UNDEBUG -Wall -Wextra -Werror -ffp-contract=off -Isrc/display \
    -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer \
    tests/o82-memory-color-contract.cpp -o memory-sanitized
g++ -std=c++20 -O2 -UNDEBUG -Wall -Wextra -Werror -Isrc/display \
    tests/o82-memory-pipeline-contract.cpp -o bridge-optimized
clang++ -std=c++20 -O1 -g -UNDEBUG -Wall -Wextra -Werror -Isrc/display \
    -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer \
    tests/o82-memory-pipeline-contract.cpp -o bridge-sanitized
%install
install -d %{buildroot}%{_docdir}/%{name}
%check
set -o pipefail
./memory-optimized | tee %{buildroot}%{_docdir}/%{name}/checks.txt
./memory-sanitized | tee -a %{buildroot}%{_docdir}/%{name}/checks.txt
./bridge-optimized | tee -a %{buildroot}%{_docdir}/%{name}/checks.txt
./bridge-sanitized | tee -a %{buildroot}%{_docdir}/%{name}/checks.txt
%files
%license LICENSE
%{_docdir}/%{name}/checks.txt
%changelog
* Wed Nov 04 2026 Uke contributors - 1.0-@REVISION@
- Verify generic memory-color conversion with an integer floating-point oracle.
SPEC
sed -i "s/@REVISION@/$revision/g" "$output/uke-o82-memory-color-check.spec"
[[ $(rpmspec --target aarch64 -q --srpm --qf '%{VERSION}-%{RELEASE}' \
    "$output/uke-o82-memory-color-check.spec") == "1.0-$revision.fc46" ]]
