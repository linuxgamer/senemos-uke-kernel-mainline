#!/usr/bin/env bash
# COPR-only: exercise the exact control-ID helper without an audio device.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cat > "$work/eld.c" <<'C'
#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#define SNDRV_CTL_ELEM_IFACE_PCM 3
struct snd_card { int unused; };
struct snd_ctl_elem_id { unsigned iface, device; char name[44]; };
static int source_present, target_present, rename_error, renamed;
static unsigned source_device;
static void strscpy(char *to, const char *from, unsigned size) { assert(strlen(from) < size); strcpy(to, from); }
static void *snd_ctl_find_id(struct snd_card *card, struct snd_ctl_elem_id *id)
{
 assert(card && id->iface == 3 && !strcmp(id->name, "ELD"));
 if (id->device == source_device) return source_present ? card : NULL;
 assert(id->device == 0); return target_present ? card : NULL;
}
static int snd_ctl_rename_id(struct snd_card *card, struct snd_ctl_elem_id *from, struct snd_ctl_elem_id *to)
{
 assert(card && from->device == source_device && to->device == 0);
 assert(from->iface == to->iface && !strcmp(from->name, to->name));
 renamed++; return rename_error;
}
C
printf '#include "%s/src/audio/uke-dp-eld.h"\n' "$root" >> "$work/eld.c"
cat >> "$work/eld.c" <<'C'
int main(void)
{
 struct snd_card card = {0};
 for (unsigned device = 16; device <= 18; device += 2) {
  source_device=device; source_present=1; target_present=0; rename_error=0; renamed=0;
  assert(uke_dp_eld_to_frontend(&card, device) == 0 && renamed == 1);
  source_present=0; renamed=0;
  assert(uke_dp_eld_to_frontend(&card, device) == -ENOENT && renamed == 0);
  source_present=1; target_present=1;
  assert(uke_dp_eld_to_frontend(&card, device) == -EEXIST && renamed == 0);
  target_present=0; rename_error=-EIO;
  assert(uke_dp_eld_to_frontend(&card, device) == -EIO && renamed == 1);
 }
 renamed=0; assert(uke_dp_eld_to_frontend(&card, 0) == 0 && renamed == 0);
 puts("ELD backend16/reprobe18 to FE0, absent/collision/error and identity checks passed");
}
C
"${CC:-cc}" -std=c11 -Wall -Wextra -Werror "$work/eld.c" -o "$work/eld"
"$work/eld"
