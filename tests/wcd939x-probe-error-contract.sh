#!/usr/bin/env bash
# Actual codec probe with failing providers; host memory only, no hardware.
set -euo pipefail
kernel=${1:?Pass prepared kernel tree}
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#define EPROBE_DEFER 517
#define GFP_KERNEL 0
struct device {void *data;};
struct platform_device {struct device dev;};
struct component_match {int unused;};
struct wcd939x_priv {
 int micb_lock;
 struct {struct device *dev;unsigned max_bias;} common;
};
static struct wcd939x_priv storage;
static int errors[5],calls[5],resets,pm_calls;
static bool allocation_fails;
static const int wcd939x_comp_ops=0;
static void *devm_kzalloc(struct device *d,size_t n,int flags)
{(void)d;(void)flags;assert(n==sizeof(storage));return allocation_fails?NULL:&storage;}
static void dev_set_drvdata(struct device *d,void *p){d->data=p;}
static void mutex_init(int *lock){*lock=0;}
#define dev_err(...) ((void)0)
static int __attribute__((unused)) dev_err_probe(struct device *d,int error,const char *message)
{(void)d;(void)message;return error;}
static int wcd939x_populate_dt_data(struct wcd939x_priv *w,struct device *d)
{assert(w==&storage && d==w->common.dev && w->common.max_bias==4);calls[0]++;return errors[0];}
static int wcd939x_add_typec(struct wcd939x_priv *w,struct device *d)
{(void)w;(void)d;calls[1]++;return errors[1];}
static int wcd939x_add_slave_components(struct wcd939x_priv *w,struct device *d,struct component_match **m)
{(void)w;(void)d;(void)m;calls[2]++;return errors[2];}
static int wcd939x_reset(struct wcd939x_priv *w)
{(void)w;resets++;calls[3]++;return errors[3];}
static int component_master_add_with_match(struct device *d,const int *ops,struct component_match *m)
{(void)d;(void)m;assert(ops==&wcd939x_comp_ops);calls[4]++;return errors[4];}
static void pm_runtime_set_autosuspend_delay(struct device *d,int delay)
{(void)d;assert(delay==1000);pm_calls++;}
#define PM_STUB(name) static void name(struct device *d){(void)d;pm_calls++;}
PM_STUB(pm_runtime_use_autosuspend)
PM_STUB(pm_runtime_mark_last_busy)
PM_STUB(pm_runtime_set_active)
PM_STUB(pm_runtime_enable)
PM_STUB(pm_runtime_idle)
C
awk '/^static int wcd939x_probe\(/ {emit=1}
 emit {print} emit && /^}/ {emit=0}' "$kernel/sound/soc/codecs/wcd939x.c" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
static void clear(void) {
 memset(&storage,0,sizeof(storage));memset(errors,0,sizeof(errors));
 memset(calls,0,sizeof(calls));resets=pm_calls=0;allocation_fails=false;
}
int main(void) {
 struct platform_device p={0};
 const int failures[]={-EPROBE_DEFER,-ENODEV,-ENOMEM,-EINVAL};
 for(unsigned stage=0;stage<5;stage++) {
  for(unsigned e=0;e<sizeof(failures)/sizeof(failures[0]);e++) {
   clear();errors[stage]=failures[e];assert(wcd939x_probe(&p)==failures[e]);
   for(unsigned i=0;i<5;i++)assert(calls[i]==(i<=stage));
   assert(resets==(stage>=3));assert(pm_calls==0);
  }
 }
 clear();allocation_fails=true;assert(wcd939x_probe(&p)==-ENOMEM);
 for(unsigned i=0;i<5;i++)assert(calls[i]==0);
 assert(resets==0 && pm_calls==0);
 clear();assert(wcd939x_probe(&p)==0);
 for(unsigned i=0;i<5;i++)assert(calls[i]==1);
 assert(resets==1 && pm_calls==6);
 puts("Actual WCD939x probe: provider deferral and permanent errors preserved; later reset/registration skipped on early failures; host only.");
}
C
${CC:-cc} -std=gnu11 -Wall -Wextra -Werror -fsanitize=address,undefined \
    -fno-omit-frame-pointer "$work/check.c" -o "$work/check"
"$work/check"
