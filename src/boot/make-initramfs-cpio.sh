#!/usr/bin/env bash
# Host-only: preserve the staged tree and encode the standard console node.
set -Eeuo pipefail
export LC_ALL=C
[[ $# == 4 ]]
root=$(realpath -- "$1")
generator=$(realpath -- "$2")
output=$(realpath -m -- "$3")
epoch=$4
[[ -d $root && $root != / && -f $generator && -x $generator ]]
[[ -d $root/dev && ! -L $root/dev && ! -e $root/dev/console && ! -L $root/dev/console ]]
[[ $output != "$root/"* && ! -e $output && ! -L $output ]]
[[ $epoch =~ ^[0-9]{1,10}$ && 10#$epoch -le 4294967295 ]]
work=$(mktemp -d "${output}.work.XXXXXX")
trap 'find "$work" -depth -delete' EXIT
(
    cd -- "$root"
    declare -A first_path=() file_mode=() aliases=()
    declare -a files=()
    find . -print0 | sort -z > "$work/paths"
    while IFS= read -r -d '' path; do
        [[ $path != *[[:space:][:cntrl:]]* ]] || { echo 'Unsupported whitespace/control in initramfs path' >&2; exit 1; }
        [[ $path != *'${'* ]] || { echo 'Unsupported variable expansion in initramfs path' >&2; exit 1; }
        name=/${path#./}
        [[ $path != . ]] || name=.
        mode=$(stat -c %a -- "$path")
        if [[ -L $path ]]; then
            IFS= read -r -d '' target < <(readlink --zero -- "$path")
            [[ $target != *[[:space:][:cntrl:]]* ]] || { echo 'Unsupported whitespace/control in initramfs link' >&2; exit 1; }
            printf 'slink %s %s %s 0 0\n' "$name" "$target" "$mode"
        elif [[ -d $path ]]; then
            printf 'dir %s %s 0 0\n' "$name" "$mode"
        elif [[ -f $path ]]; then
            inode=$(stat -c '%d:%i' -- "$path")
            if [[ -v first_path[$inode] ]]; then
                aliases[$inode]+=" $name"
            else
                first_path[$inode]=$path
                file_mode[$inode]=$mode
                aliases[$inode]=
                files+=("$inode")
            fi
        else
            echo 'Unexpected special file in initramfs source tree' >&2
            exit 1
        fi
    done < "$work/paths"
    for inode in "${files[@]}"; do
        printf 'file /%s %s %s 0 0%s\n' "${first_path[$inode]#./}" "${first_path[$inode]}" "${file_mode[$inode]}" "${aliases[$inode]}"
    done
    # Linux usr/default_cpio_list uses this console ABI before early userspace.
    printf 'nod /dev/console 0600 0 0 c 5 1\n'
) > "$work/list"
(cd -- "$root"; "$generator" -t "$epoch" "$work/list") | gzip -n -9 > "$work/archive.gz"
gzip -t "$work/archive.gz"
ln -- "$work/archive.gz" "$output"
