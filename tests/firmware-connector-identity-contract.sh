#!/usr/bin/env bash
# Ensure the temporary firmware connector cannot consume native DSI identity 1.
set -Eeuo pipefail
file=${1:?Pass prepared simpledrm.c}
work=$(mktemp -d)
trap 'find "$work" -depth -delete' EXIT
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <stdbool.h>
#include <stdio.h>
enum { DRM_MODE_CONNECTOR_Unknown, DRM_MODE_CONNECTOR_DSI };
static int dev, simpledrm_connector_funcs, counts[2];
static int drm_connector_init(int d,int *c,int *f,int type) {(void)d;(void)c;(void)f;counts[type]++;return 0;}
static void check(bool uke_internal_panel) {
 int connector=0,ret;(void)uke_internal_panel;
C
awk '/ret = drm_connector_init\(dev, connector, &simpledrm_connector_funcs,/{emit=1} emit{print} emit&&/;/{exit}' "$file" | sed 's/dev, connector,/dev, \&connector,/;s/&simpledrm_connector_funcs/\&simpledrm_connector_funcs/' >> "$work/check.c"
cat >> "$work/check.c" <<'C'
 assert(!ret && counts[DRM_MODE_CONNECTOR_DSI]==0);
 assert(++counts[DRM_MODE_CONNECTOR_DSI]==1);
 counts[0]=counts[1]=0;
}
int main(void) {check(false);check(true);puts("Temporary framebuffer retains native DSI-1 identity; host only");}
C
"${CC:-cc}" -std=gnu11 -O2 -Wall -Wextra -Werror "$work/check.c" -o "$work/check"
"$work/check"
grep -Fq drm_connector_set_panel_orientation_with_quirk "$file"
