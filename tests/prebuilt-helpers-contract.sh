#!/usr/bin/env bash
# Exercise production helper selection and ELF checks; never execute a fixture.
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
# Only the ELF machine fields matter here; these copies are not target programs.
cp "$(type -P true)" "$work/aarch64"
printf '\267\000' | dd of="$work/aarch64" bs=1 seek=18 conv=notrunc status=none
cp "$work/aarch64" "$work/foreign"
printf '\003\000' | dd of="$work/foreign" bs=1 seek=18 conv=notrunc status=none
ln -s aarch64 "$work/link"
mkdir "$work/directory"
sed -n '/^if \[\[ -n ${UKE_PREBUILT_SWITCH_ROOT:-}/,/^readelf -h/p' \
    "$root/src/boot/build-payload.sh" > "$work/switch-root.sh"
for helper in switch-root; do
    [[ $(grep -c '^readelf -h' "$work/$helper.sh") == 1 ]]
done
compile_fixture() {
    printf 'compile\n' >> "$compiler_log"
    while (($# > 1)); do
        if [[ $1 == -o ]]; then cp "$fixture" "$2"; return; fi
        shift
    done
    return 2
}
clang++() { compile_fixture "$@"; }
g++() { compile_fixture "$@"; }
export -f compile_fixture clang++ g++
for helper in switch-root; do
    case $helper in
        switch-root) variable=UKE_PREBUILT_SWITCH_ROOT; binary=uke-offline-switch-root;;
        touch-capture) variable=UKE_PREBUILT_TOUCH_CAPTURE; binary=uke-touch-capture;;
    esac
    for input in source aarch64 foreign missing link directory; do
        stage=$work/$helper-$input
        mkdir -p "$stage/native-generated"
        (
            cd "$stage"
            unset UKE_PREBUILT_SWITCH_ROOT UKE_PREBUILT_TOUCH_CAPTURE
            export out=$stage here=$root/src/boot fixture=$work/aarch64 compiler_log=$stage/compiler.log
            [[ $input == source ]] || export "$variable=$work/$input"
            bash -Eeuo pipefail "$work/$helper.sh"
        ) > "$stage/result.log" 2>&1 && status=0 || status=$?
        case $input in
            source|aarch64)
                [[ $status == 0 ]]
                target=$stage/$binary
                [[ $helper == switch-root ]] || target=$stage/native-generated/$binary
                cmp "$work/aarch64" "$target"
                [[ -x $target ]]
                if [[ $input == source ]]; then [[ $(cat "$stage/compiler.log") == compile ]];
                else [[ ! -e $stage/compiler.log ]]; fi;;
            *) [[ $status != 0 && ! -e $stage/compiler.log ]];;
        esac
    done
done
echo 'Production helper source/prebuilt paths, foreign ELF and invalid-path refusals passed; no target execution.'
