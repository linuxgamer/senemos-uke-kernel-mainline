#!/usr/bin/env bash
# Actual component admission and card shape, host only; no PCM/DSP access.
set -euo pipefail
kernel=${1:?Pass prepared kernel tree}
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
source_file=$kernel/sound/soc/qcom/qdsp6/q6apm-dai.c
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <stdbool.h>
#include <errno.h>
#include <string.h>
#include <stdio.h>
struct device_node { bool blocked; };
struct device { struct device_node *of_node; };
struct snd_soc_component { struct device *dev; };
static bool uke;
static bool of_machine_is_compatible(const char *name) {
 assert(!strcmp(name, "xiaomi,uke")); return uke;
}
static bool of_property_read_bool(struct device_node *node, const char *name) {
 assert(!strcmp(name, "xiaomi,registration-only")); return node && node->blocked;
}
C
awk '/^static bool q6apm_registration_only\(/ {emit=1} emit {print} emit && /^}/ {exit}' \
    "$source_file" >> "$work/check.c"
for function in q6apm_dai_open q6apm_dai_compr_open q6apm_dai_pcm_new; do
    # Only the actual guard may precede graph selection/allocation; reject its absence.
    awk -v name="$function" '
      $0 ~ "^static int " name "\\(" {emit=1}
      emit && /q6apm_registration_only\(component\)/ {guard=1; print; next}
      emit && guard && /return (-EACCES|0);/ {denied=1; print; next}
      emit && /graph_id = cpu_dai/ {exit !(guard && denied)}
      emit && /q6apm_graph_open|kzalloc_obj|dma_alloc/ {exit 1}
      END {if (!guard || !denied) exit 1}
    ' "$source_file" > "$work/$function.c"
    {
        printf 'static int %s_guard(struct snd_soc_component *component) {\n' "$function"
        cat "$work/$function.c"
        printf 'return 1; }\n'
    } >> "$work/check.c"
done
awk '
  /^static void q6apm_dai_pcm_free\(/ {emit=1}
  emit && /q6apm_registration_only\(component\)/ {guard=1; print; next}
  emit && guard && /return;/ {denied=1; print; next}
  emit && /substream = pcm->/ {exit !(guard && denied)}
  emit && /q6apm_dai_memory_unmap/ {exit 1}
  END {if (!guard || !denied) exit 1}
' "$source_file" > "$work/free.c"
{
    printf 'static int free_calls;\nstatic void pcm_free_guard(struct snd_soc_component *component) {\n'
    cat "$work/free.c"
    printf 'free_calls++; }\n'
cat <<'C'
struct snd_soc_dai_link { bool no_pcm, dynamic; };
struct snd_soc_pcm_runtime { struct snd_soc_dai_link *dai_link; };
struct snd_soc_card { unsigned count; struct snd_soc_pcm_runtime *rtd; };
#define for_each_card_rtds(c, r) for (r=(c)->rtd; r<(c)->rtd+(c)->count; r++)
C
awk '/^static int uke_audio_late_probe\(/ {emit=1} emit {print} emit && /^}/ {exit}' \
    "$root/src/audio/uke-audio-card.c"
cat <<'C'
int main(void) {
 struct device_node node={.blocked=true}; struct device device={.of_node=&node};
 struct snd_soc_component component={.dev=&device};
 for (int board=0; board<2; board++) for (int blocked=0; blocked<2; blocked++) {
  uke=board; node.blocked=blocked;
  int expected=board && blocked ? -EACCES : 1;
  assert(q6apm_dai_open_guard(&component)==expected);
  assert(q6apm_dai_compr_open_guard(&component)==expected);
  assert(q6apm_dai_pcm_new_guard(&component)==(board && blocked ? 0 : 1));
  free_calls=0; pcm_free_guard(&component);
  assert(free_calls==(board && blocked ? 0 : 1));
 }
 device.of_node=NULL; assert(!q6apm_registration_only(&component));
 struct snd_soc_dai_link links[3]={{.dynamic=true},{.dynamic=true},{.dynamic=true}};
 struct snd_soc_pcm_runtime rtd[3]={{&links[0]},{&links[1]},{&links[2]}};
 struct snd_soc_card card={.count=2,.rtd=rtd};
 assert(uke_audio_late_probe(&card)==0);
 for (unsigned count=0;count<=3;count++) if(count!=2) {
  card.count=count; assert(uke_audio_late_probe(&card)==-EINVAL);
 }
 card.count=2; links[0].no_pcm=true; assert(uke_audio_late_probe(&card)==-EINVAL);
 links[0].no_pcm=false; links[1].dynamic=false; assert(uke_audio_late_probe(&card)==-EINVAL);
 puts("Actual Uke PCM lifecycle, compressed admission and two-frontend card shape passed.");
}
C
} >> "$work/check.c"
${CC:-cc} -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined \
    "$work/check.c" -o "$work/check"
"$work/check"
overlay=$kernel/native-generated/display.dtbo
node=$(fdtget -t s "$overlay" /__symbols__ uke_q6apm_dais)
[[ $(fdtget -t s "$overlay" "$node" status) == okay ]]
if fdtget "$overlay" "$node" xiaomi,hdmi-only >/dev/null 2>&1; then
    fdtget "$overlay" "$node" iommus >/dev/null
    if fdtget "$overlay" "$node" xiaomi,registration-only >/dev/null 2>&1; then exit 1; fi
else
    fdtget "$overlay" "$node" xiaomi,registration-only >/dev/null
    if fdtget "$overlay" "$node" iommus >/dev/null 2>&1; then
        echo 'Closed registration profile must not attach an IOMMU' >&2; exit 1
    fi
fi
alsatplg -c "$root/src/audio/POCO-Pad-X1-AudioReach.conf" -o "$work/frontends.bin"
alsatplg -d "$work/frontends.bin" -o "$work/decoded.conf"
grep -Fq 'AudioReach Playback (disabled)' "$work/decoded.conf"
grep -Fq 'AudioReach Capture (disabled)' "$work/decoded.conf"
if grep -E 'SectionWidget|SectionControl|SectionGraph|SectionLink' "$work/decoded.conf"; then
    echo 'Registration topology must not create physical/DSP routes' >&2; exit 1
fi
printf 'Native topology roundtrip: two frontends, no graph, mixer or endpoint.\n'
