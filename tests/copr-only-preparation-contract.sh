#!/usr/bin/env bash
# Metadata control flow only. Upstream transport/signature replies are fixtures.
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
preparer=${1:-$root/scripts/prepare-upstream-candidate.sh}
[[ -f $preparer && ! -L $preparer ]]
work=$(mktemp -d)
trap 'find "$work" -depth -delete' EXIT
mkdir -p "$work/bin" "$work/archive/linux-7.3.1"
export UKE_FORBIDDEN_TOOL_LOG=$work/forbidden.log
export UKE_TEST_ARCHIVE=$work/upstream.tar.xz
cat > "$work/bin/forbidden" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$0" >> "$UKE_FORBIDDEN_TOOL_LOG"
exit 91
SH
chmod 755 "$work/bin/forbidden"
for tool in make rpmbuild gcc g++ cc c++ clang clang++; do
    ln -s forbidden "$work/bin/$tool"
done
cat > "$work/bin/rpmspec" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
spec=${!#}
case " $* " in
    *'%{VERSION}'*) awk '/^Version:/{print $2;exit}' "$spec";;
    *'%{RELEASE}'*) awk '/^Release:/{v=$2;sub(/%.*/,"",v);print v;exit}' "$spec";;
    *'%{NAME}'*) awk '/^Name:/{print $2;exit}' "$spec";;
    *) exit 92;;
esac
SH
cat > "$work/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
destination= url=
while (($#)); do
    case $1 in -o) destination=$2;shift;; https://*) url=$1;; esac
    shift
done
case $url in
    https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.3.1.tar.xz) cp "$UKE_TEST_ARCHIVE" "$destination";;
    https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.3.1.tar.sign) printf 'fixture signature\n' > "$destination";;
    *) exit 93;;
esac
SH
cat > "$work/bin/gpg" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
    *' --verify '*)
        cat > /dev/null
        printf '[GNUPG:] VALIDSIG ABAF11C65A2970B130ABE3C479BE3E4300411886 1 1 0 4 0 1 8 00 ABAF11C65A2970B130ABE3C479BE3E4300411886\n';;
    *' --export '*) printf 'fixture public key\n';;
esac
SH
printf '#!/usr/bin/env bash\nexit 0\n' > "$work/bin/gpgconf"
chmod 755 "$work/bin/"{rpmspec,curl,gpg,gpgconf}
printf 'VERSION = 7\nPATCHLEVEL = 3\nSUBLEVEL = 1\n' > "$work/archive/linux-7.3.1/Makefile"
tar -cJf "$UKE_TEST_ARCHIVE" -C "$work/archive" linux-7.3.1
cat > "$work/release.json" <<'JSON'
{"releases":[{"version":"7.3.1","moniker":"stable","source":"https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.3.1.tar.xz","pgp":"https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.3.1.tar.sign","released":{"timestamp":1}}]}
JSON
for role in singleboot kvm-singleboot common; do
    stage=$work/$role
    mkdir -p "$stage/packaging" "$stage/tests" "$stage/manifests" "$stage/patches/7.3.0" "$stage/configs/keys"
    case $role in
        singleboot) name=senemos-uke-linux-kernel-mainline-singleboot; descriptor=singleboot;;
        kvm-singleboot) name=senemos-uke-linux-kernel-mainline-kvm-singleboot; descriptor=kvm-singleboot;;
        common) name=senemos-uke-linux-kernel-mainline; descriptor=singleboot;;
    esac
    printf 'Name: %s\nVersion: 7.3.0\nRelease: 54\n%%setup -q -n linux-7.3\n' "$name" > "$stage/packaging/$name.spec"
    printf '{"kernel_release":"7.3.0-54"}\n' > "$stage/packaging/$descriptor.json"
    printf 'Source metadata fixture\n' > "$stage/packaging/SINGLEBOOT.md"
    printf 'version := 7.3.0\n' > "$stage/Makefile"
    printf '7.3.0-54\n' > "$stage/tests/mainline-package-contract.sh"
    printf 'fixture patch\n' > "$stage/patches/7.3.0/fixture.patch"
    printf 'fixture key\n' > "$stage/configs/keys/linux-stable.asc"
    printf '{"version":"7.3.0","hardware_tested":false,"patches":[{"path":"patches/7.3.0/fixture.patch"}]}\n' > "$stage/manifests/linux-7.3.0.json"
    printf '{"kernel_release":"7.3.0-54","tablet_tested":false}\n' > "$stage/manifests/llcc-source-candidate-20261020.json"
    git -C "$stage" init -q
    git -C "$stage" add .
    git -C "$stage" -c user.name='Source contract' -c user.email='41898282+github-actions[bot]@users.noreply.github.com' commit -qm fixture
    (
        export PATH="$work/bin:$PATH"
        if [[ $role == common ]]; then
            bash "$preparer" "$stage" "$role" "$work/release.json" > "$work/$role.log" 2>&1
        else
            bash "$preparer" "$stage" "$role" 7.3.0-55 > "$work/$role.log" 2>&1
        fi
    ) || {
        cat "$work/$role.log" >&2
        if [[ -s $UKE_FORBIDDEN_TOOL_LOG ]]; then
            printf 'Forbidden build tool reached: ' >&2
            cat "$UKE_FORBIDDEN_TOOL_LOG" >&2
        fi
        exit 1
    }
    [[ $(git -C "$stage" rev-list --count HEAD) == 2 ]]
    [[ ! -s $UKE_FORBIDDEN_TOOL_LOG ]]
    case $role in
        common)
            grep -Fxq $'prepared\t7.3.1-1' "$work/$role.log"
            jq -e '.version=="7.3.1" and .hardware_tested==false and .candidate.physical_tested==false and .patches[0].path=="patches/7.3.1/fixture.patch"' "$stage/manifests/linux-7.3.1.json" >/dev/null;;
        *)
            abi=7.3.0-55; [[ $role != kvm-singleboot ]] || abi+=-kvm
            jq -e --arg abi "$abi" '.kernel_release==$abi' "$stage/packaging/$descriptor.json" >/dev/null;;
    esac
done
echo 'Changed common/singleboot/KVM metadata paths passed with build tools forbidden; mocked upstream transport/signature only'
# The existing source-only CI entry also checks source-worker admission failures.
bash "$root/tests/copr-source-guards-contract.sh"
