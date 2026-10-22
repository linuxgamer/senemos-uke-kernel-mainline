#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
source "$root/scripts/prepare-upstream-candidate.sh"
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
cat > "$work/release.json" <<'JSON'
{"latest_stable":{"version":"7.3"},"releases":[{"moniker":"mainline","version":"7.3","source":"https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.3.tar.xz","pgp":"https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.3.tar.sign","released":{"timestamp":1792365298}}]}
JSON
[[ $(release_fields "$work/release.json" | cut -f1) == 7.3 ]]
jq '.releases[0].source="https://example.invalid/linux-7.3.tar.xz"' "$work/release.json" > "$work/foreign.json"
if release_fields "$work/foreign.json" 2>/dev/null; then exit 1; fi
jq '.releases += [.releases[0]]' "$work/release.json" > "$work/duplicate.json"
if release_fields "$work/duplicate.json" 2>/dev/null; then exit 1; fi
jq '.latest_stable.version="7.3/../../foreign"' "$work/release.json" > "$work/path.json"
if release_fields "$work/path.json" 2>/dev/null; then exit 1; fi
for invalid in '0' '-1' '1792365298.5' '"1792365298"' '999999999999999'; do
    jq --argjson epoch "$invalid" '.releases[0].released.timestamp=$epoch' "$work/release.json" > "$work/epoch.json"
    if release_fields "$work/epoch.json" 2>/dev/null; then exit 1; fi
done
cat > "$work/contract" <<'TEXT'
7.2.11-16-kvm 7\.2\.11-16 7[.]2[.]11-16
7.2.11 7\.2\.11 7[.]2[.]11
TEXT
replace_version "$work/contract" 7.2.11 7.3.0 16 1
cat > "$work/expected" <<'TEXT'
7.3.0-1-kvm 7\.3\.0-1 7[.]3[.]0-1
7.3.0 7\.3\.0 7[.]3[.]0
TEXT
cmp "$work/contract" "$work/expected"
cat > "$work/builds.json" <<'JSON'
{"items":[{"id":42,"state":"succeeded","source_package":{"name":"senemos-uke-linux-kernel-mainline","version":"7.3.0-1","url":"https://download.copr.fedorainfracloud.org/results/mcc45tr/uke-linux-test/srpm-builds/42/kernel.src.rpm"},"chroots":["fedora-rawhide-aarch64"]}]}
JSON
[[ $(matching_build "$work/builds.json" senemos-uke-linux-kernel-mainline 7.3.0-1 | jq -r .id) == 42 ]]
[[ $(matching_build "$work/builds.json" senemos-uke-linux-kernel-mainline-kvm 7.3.0-1 | jq -r .state) == absent ]]
[[ $(matching_build "$work/builds.json" senemos-uke-linux-kernel-mainline 7.2.11-16 | jq -r .state) == absent ]]
for change in '.items[0].chroots=["fedora-rawhide-x86_64"]' \
              '.items[0].source_package.url="https://download.copr.fedorainfracloud.org/results/mcc45tr/uke-linux-test:custom:trial/srpm-builds/42/kernel.src.rpm"' \
              '.items[0].id="42/foreign"'; do
    jq "$change" "$work/builds.json" > "$work/rejected-builds.json"
    [[ $(matching_build "$work/rejected-builds.json" senemos-uke-linux-kernel-mainline 7.3.0-1 | jq -r .state) == absent ]]
done
jq '.items += [.items[0]|.id=43|.state="failed"]' "$work/builds.json" > "$work/latest-builds.json"
[[ $(matching_build "$work/latest-builds.json" senemos-uke-linux-kernel-mainline 7.3.0-1 | jq -r .state) == failed ]]
mkdir -p "$work/source/packaging" "$work/bin"
cat > "$work/source/packaging/senemos-uke-linux-kernel-mainline.spec" <<'SPEC'
Name: source-fixture
Version: 7.2.11
Release: 16%{?dist}
Summary: Source query fixture
License: MIT
%description
Source query fixture.
%files
SPEC
cp "$work/source/packaging/senemos-uke-linux-kernel-mainline.spec" "$work/source/packaging/senemos-uke-linux-kernel-mainline-singleboot.spec"
real_rpmspec=$(command -v rpmspec)
printf '#!/usr/bin/env bash\nexec %q --define %q --define %q "$@"\n' "$real_rpmspec" 'dist .fc44' 'dist %{nil}' > "$work/bin/rpmspec"
chmod 755 "$work/bin/rpmspec"
jq '.latest_stable.version="7.2.11" | .releases[0].version="7.2.11" |
 .releases[0].source="https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.2.11.tar.xz" |
 .releases[0].pgp="https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.2.11.tar.sign"' "$work/release.json" > "$work/current-release.json"
[[ $(cd "$work/source"; PATH="$work/bin:$PATH" prepare_metadata singleboot 7.2.11-16) == unchanged$'\t'7.2.11-16 ]]
[[ $(cd "$work/source"; PATH="$work/bin:$PATH" prepare_common "$work/current-release.json") == unchanged$'\t'7.2.11-16 ]]
echo 'Exact release, timestamp, version, package, repository, architecture and newest-build selection passed'
