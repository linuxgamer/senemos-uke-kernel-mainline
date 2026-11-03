#!/usr/bin/env bash
# Actual policy/scan functions; host LRU and fence activity are modeled.
set -Eeuo pipefail
source_file=${1:?Pass the prepared msm_gem_shrinker.c}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cat > "$work/check.c" <<'C'
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#define __GFP_DIRECT_RECLAIM 1
#define __GFP_KSWAPD_RECLAIM 2
#define ARRAY_SIZE(a) (sizeof(a)/sizeof((a)[0]))
#define SHRINK_STOP (~0UL)
struct ww_acquire_ctx { int unused; };
struct drm_gem_object { int unused; };
struct drm_gem_lru { int id; };
struct msm_drm_private { void *dev; struct { struct drm_gem_lru dontneed,willneed; } lru; };
struct shrinker { struct msm_drm_private *private_data; };
struct shrink_control { unsigned gfp_mask; long nr_to_scan; };
static bool kswapd; static unsigned long swap_pages;
static bool current_is_kswapd(void) {return kswapd;}
static unsigned long get_nr_swap_pages(void) {return swap_pages;}
C
awk '/^static bool (enable_eviction|eviction_can_block) =/{print}' "$source_file" >> "$work/check.c"
if ! grep -q '^static bool eviction_can_block' "$work/check.c"; then
    echo 'static bool eviction_can_block = false;' >> "$work/check.c"
fi
for name in can_swap can_block; do
    awk -v n="$name" '$0 ~ "^static bool " n "\\(" {emit=1} emit{print} emit && /^}/{exit}' "$source_file" >> "$work/check.c"
done
cat >> "$work/check.c" <<'C'
#define CALLBACK(n) static bool n(struct drm_gem_object *o, struct ww_acquire_ctx *t) {(void)o;(void)t;return true;}
CALLBACK(purge) CALLBACK(evict) CALLBACK(active_purge) CALLBACK(active_evict)
static unsigned called[4]; static unsigned long stage_freed[4],stage_remaining[4];
static unsigned long drm_gem_lru_scan(void *dev,struct drm_gem_lru *lru,long nr,
 unsigned long *remaining,bool (*shrink)(struct drm_gem_object *,struct ww_acquire_ctx *),struct ww_acquire_ctx *ticket) {
 (void)dev;(void)nr;if(ticket)abort();
 unsigned index=shrink==purge?0:shrink==evict?1:shrink==active_purge?2:3;
 if(lru->id!=(int)(index&1))abort();
 ++called[index];
 *remaining=stage_remaining[index];return stage_freed[index];
}
static void trace_msm_gem_shrink(long n,unsigned long a,unsigned long b,unsigned long c,unsigned long d) {
 (void)n;(void)a;(void)b;(void)c;(void)d;
}
C
awk '/^msm_gem_shrinker_scan\(/ {print "static unsigned long";emit=1} emit{print} emit && /^}/{exit}' "$source_file" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
static unsigned checks,failed;
#define CHECK(v) do {++checks;if(!(v)){++failed;fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#v);}}while(0)
static void reset(void) {for(unsigned i=0;i<4;i++){called[i]=0;stage_freed[i]=stage_remaining[i]=0;}}
int main(void) {
 CHECK(enable_eviction);CHECK(!eviction_can_block);
 for(unsigned allow=0;allow<2;allow++)for(unsigned worker=0;worker<2;worker++)for(unsigned flags=0;flags<4;flags++) {
   eviction_can_block=allow;kswapd=worker;
   struct shrink_control sc={.gfp_mask=flags,.nr_to_scan=16};
   CHECK(can_block(&sc)==(allow && ((flags&__GFP_DIRECT_RECLAIM)||(worker&&(flags&__GFP_KSWAPD_RECLAIM)))));
 }
 for(unsigned enabled=0;enabled<2;enabled++)for(unsigned available=0;available<2;available++) {
   enable_eviction=enabled;swap_pages=available;CHECK(can_swap()==(enabled&&available));
 }
 struct msm_drm_private priv={.lru={.dontneed={.id=0},.willneed={.id=1}}};
 struct shrinker shrinker={.private_data=&priv};
 struct shrink_control sc={.gfp_mask=__GFP_DIRECT_RECLAIM,.nr_to_scan=16};
 enable_eviction=true;eviction_can_block=false;swap_pages=64;kswapd=false;
 reset();stage_freed[1]=9;
 CHECK(msm_gem_shrinker_scan(&shrinker,&sc)==9);
 CHECK(called[0]==1&&called[1]==1&&!called[2]&&!called[3]);
 reset();stage_freed[0]=16;
 CHECK(msm_gem_shrinker_scan(&shrinker,&sc)==16);
 CHECK(called[0]==1&&!called[1]&&!called[2]&&!called[3]);
 reset();stage_remaining[0]=64;stage_remaining[1]=64;
 CHECK(msm_gem_shrinker_scan(&shrinker,&sc)==SHRINK_STOP);
 CHECK(called[0]==1&&called[1]==1&&!called[2]&&!called[3]);
 reset();eviction_can_block=true;
 CHECK(msm_gem_shrinker_scan(&shrinker,&sc)==SHRINK_STOP);
 CHECK(called[0]==1&&called[1]==1&&called[2]==1&&called[3]==1);
 reset();eviction_can_block=false;swap_pages=0;
 CHECK(msm_gem_shrinker_scan(&shrinker,&sc)==SHRINK_STOP);
 CHECK(called[0]==1&&!called[1]&&!called[2]&&!called[3]);
 printf("MSM actual policy/scan: %u checks, %u failures; modeled LRU only, no device qualification\n",checks,failed);
 return failed?1:0;
}
C
"${CC:-cc}" -std=gnu11 -O2 -Wall -Wextra -Werror -Wno-missing-field-initializers "$work/check.c" -o "$work/check"
"$work/check"
