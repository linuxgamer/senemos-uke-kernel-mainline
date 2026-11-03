#!/usr/bin/env bash
# Native LTO/linker-GC fixture using the actual kernel ELFNOTE definition.
set -Eeuo pipefail
kernel=$1
manifest=$2
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
jq -e '.root_selector_capability.name=="UKE" and .root_selector_capability.type=="0x554b4501" and .root_selector_capability.descriptor=="root-selector-v2;userdata=f2fs,ext4,xfs,btrfs;slot=a,b;vrr-min=0,30" and .root_selector_capability.manifest_value=="uke-elfnote-v2" and .root_selector_capability.policy_changed==true and .root_selector_capability.physical_vrr_qualified==false' "$manifest" >/dev/null
mkdir -p "$work/include/linux" "$work/include/uapi/linux"
cp "$kernel/include/linux/elfnote.h" "$work/include/linux/elfnote.h"
cat > "$work/include/uapi/linux/elf.h" <<'C'
#include <stdint.h>
typedef uint32_t Elf64_Word;
struct elf64_note { Elf64_Word n_namesz, n_descsz, n_type; };
C
cat > "$work/include/linux/compiler.h" <<'C'
#define __used __attribute__((used))
#define JOIN_(a,b) a##b
#define JOIN(a,b) JOIN_(a,b)
#define __UNIQUE_ID(prefix) JOIN(prefix,__COUNTER__)
C
cat > "$work/entry.c" <<'C'
#include <stddef.h>
#include <string.h>
#define __KERNEL__
#define UKE_INIT
#include "uke-root-selector.h"
int main(void) {
    char line[128]="root=PARTLABEL=linux rw rootfstype=ext4,f2fs,xfs,btrfs panic=0";
    const char args[]="senemos.root=userdata msm.o82_vrr_test_min_hz=0";
    return uke_select_root(line,sizeof(line),args,sizeof(args))!=1;
}
C
cat > "$work/notes.lds" <<'LDS'
SECTIONS { .note.UKE : { KEEP(*(.note.UKE)) } }
INSERT AFTER .text;
LDS
compiler=$(printenv CC || printf 'cc')
set -- -std=gnu11 -O2 -flto -ffunction-sections -fdata-sections -Wall -Wextra -Werror
if [[ $("$compiler" --version) == *clang* ]]; then set -- "$@" -fuse-ld=lld; fi
"$compiler" "$@" -I"$work/include" -I"$root/src/boot" "$work/entry.c" \
    -Wl,--gc-sections -Wl,-T,"$work/notes.lds" -o "$work/entry"
"$work/entry"
check=$root/src/boot/check-root-capability.sh
bash "$check" "$work/entry"
bash "$check" "$work/entry" reset
objcopy --dump-section .note.UKE="$work/note" "$work/entry"
bash "$check" "$work/note"
bash "$check" "$work/note" reset
sed '/^#define __KERNEL__/d' "$work/entry.c" > "$work/absent.c"
"$compiler" "$@" -I"$work/include" -I"$root/src/boot" "$work/absent.c" \
    -Wl,--gc-sections -Wl,-T,"$work/notes.lds" -o "$work/absent"
reject() { if bash "$check" "$1" > /dev/null 2>&1; then echo 'Malformed note accepted' >&2; exit 1; fi; }
reject "$work/absent"
cat "$work/note" "$work/note" > "$work/duplicate"
reject "$work/duplicate"
cp "$work/note" "$work/bad-header"
root_offset=$(LC_ALL=C grep -aFob 'root-selector-v2;userdata=' "$work/note" | cut -d: -f1)
printf '\0' | dd of="$work/bad-header" bs=1 seek="$((root_offset-16))" conv=notrunc status=none
reject "$work/bad-header"
head -c 20 "$work/note" > "$work/truncated"
reject "$work/truncated"
{ printf x; cat "$work/note"; } > "$work/unaligned"
reject "$work/unaligned"
sed 's/root-selector-v2/root-selector-v3/' "$work/note" > "$work/unknown-version"
reject "$work/unknown-version"
printf 'msm.o82_vrr_test_min_hz=' > "$work/old-literal"
reject "$work/old-literal"
printf 'root-selector-v2;userdata=f2fs,ext4,xfs,btrfs;slot=a,b;vrr-min=0,30' > "$work/descriptor-only"
reject "$work/descriptor-only"
printf 'Actual ELFNOTE: optimized/LTO/GC retention and eight malformed/absent cases passed\n'
