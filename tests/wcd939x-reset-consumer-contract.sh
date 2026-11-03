#!/usr/bin/env bash
# Actual WCD reset acquisition and pulse; host fakes only, no codec access.
set -euo pipefail
kernel=${1:?Pass prepared kernel tree}
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#define CONFIG_TYPEC 0
#define IS_ENABLED(x) x
#define GPIOD_OUT_LOW 0
#define MIC_BIAS_2 2
#define WCD_MBHC_HS_V_MAX 1600
#define WCD939X_MBHC_MAX_BUTTONS 8
#define ERR_PTR(e) ((void *)(intptr_t)(e))
#define PTR_ERR(p) ((int)(intptr_t)(p))
#define IS_ERR(p) ((uintptr_t)(p)>=(uintptr_t)-4095)
#define ARRAY_SIZE(a) (sizeof(a)/sizeof((a)[0]))
struct device {void *of_node;};
struct gpio_desc {int unused;};
struct reset_control {int unused;};
struct wcd_mbhc_config {
 int mbhc_micbias,anc_micbias,v_hs_max,num_btn,micb_mv,linein_th,hs_thr,hph_thr;
};
struct wcd_common {int micb_mv[4];};
struct wcd939x_priv {
 struct gpio_desc *reset_gpio;struct reset_control *reset;
 struct wcd_mbhc_config mbhc_cfg;struct wcd_common common;
};
static struct gpio_desc gpio;
static struct reset_control reset;
static bool has_reset,has_gpio,is_uke;
static int reset_error,gpio_error,supply_error,bias_error;
static unsigned reset_gets,gpio_gets,supply_calls,bias_calls,mbhc_calls,pulses,gpio_sets,delays;
static int reset_result;
static bool of_machine_is_compatible(const char *name)
{assert(!strcmp(name,"xiaomi,uke"));return is_uke;}
static bool of_property_present(void *node,const char *name)
{(void)node;if(!strcmp(name,"resets"))return has_reset;assert(!strcmp(name,"reset-gpios"));return has_gpio;}
static struct reset_control *devm_reset_control_get_exclusive(struct device *d,const char *name)
{(void)d;assert(!name && has_reset);reset_gets++;return reset_error?ERR_PTR(reset_error):&reset;}
static struct gpio_desc *devm_gpiod_get(struct device *d,const char *name,int flags)
{(void)d;assert(!strcmp(name,"reset") && flags==0);gpio_gets++;return gpio_error?ERR_PTR(gpio_error):&gpio;}
static int dev_err_probe(struct device *d,int error,const char *message)
{(void)d;(void)message;return error;}
static int wcd939x_enable_supplies(struct device *d)
{(void)d;supply_calls++;return supply_error;}
static int wcd_dt_parse_micbias_info(struct wcd_common *c)
{(void)c;bias_calls++;return bias_error;}
static void wcd_dt_parse_mbhc_data(struct device *d,struct wcd_mbhc_config *cfg)
{(void)d;assert(cfg);mbhc_calls++;}
static int reset_control_reset(struct reset_control *r)
{assert(r==&reset);pulses++;return reset_result;}
static void gpiod_set_value_cansleep(struct gpio_desc *g,int value)
{assert(g==&gpio && value==(gpio_sets==0));gpio_sets++;}
static void usleep_range(unsigned low,unsigned high){assert(low==20 && high==30);delays++;}
C
awk '/^static int (wcd939x_populate_dt_data|wcd939x_reset)\(/ {emit=1}
 emit {print} emit && /^}/ {emit=0}' "$kernel/sound/soc/codecs/wcd939x.c" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
static void clear(struct wcd939x_priv *w) {
 memset(w,0,sizeof(*w));has_reset=has_gpio=is_uke=false;
 reset_error=gpio_error=supply_error=bias_error=reset_result=0;
 reset_gets=gpio_gets=supply_calls=bias_calls=mbhc_calls=pulses=gpio_sets=delays=0;
}
int main(void) {
 struct device dev={0};struct wcd939x_priv w;
 clear(&w);has_reset=true;has_gpio=true;
 assert(wcd939x_populate_dt_data(&w,&dev)==-EINVAL);
 assert(!reset_gets && !gpio_gets && !supply_calls);
 for(unsigned controller=0;controller<2;controller++) {
  clear(&w);has_reset=controller;has_gpio=!controller;
  assert(wcd939x_populate_dt_data(&w,&dev)==0);
  assert(reset_gets==controller && gpio_gets==!controller);
  assert(supply_calls==1 && bias_calls==1 && mbhc_calls==1);
  assert(wcd939x_reset(&w)==0);
  assert(pulses==controller && gpio_sets==2*!controller && delays==2*!controller);
  const int errors[]={-517,-ENODEV,-EINVAL};
  for(unsigned i=0;i<3;i++) {
   clear(&w);has_reset=controller;has_gpio=!controller;
   if(controller)reset_error=errors[i];else gpio_error=errors[i];
   assert(wcd939x_populate_dt_data(&w,&dev)==errors[i]);
   assert(!supply_calls && !bias_calls && !pulses && !gpio_sets);
  }
 }
 clear(&w);gpio_error=-ENOENT;
 assert(wcd939x_populate_dt_data(&w,&dev)==-ENOENT && !supply_calls);
 for(unsigned gpio_present=0;gpio_present<2;gpio_present++) {
  clear(&w);is_uke=true;has_gpio=gpio_present;
  assert(wcd939x_populate_dt_data(&w,&dev)==-EINVAL);
  assert(!gpio_gets && !reset_gets && !supply_calls && !bias_calls && !pulses);
 }
 clear(&w);is_uke=true;has_reset=true;
 assert(wcd939x_populate_dt_data(&w,&dev)==0);
 assert(reset_gets==1 && !gpio_gets && supply_calls==1);
 clear(&w);has_reset=true;supply_error=-517;
 assert(wcd939x_populate_dt_data(&w,&dev)==-517 && !bias_calls && !pulses);
 clear(&w);has_reset=true;bias_error=-EINVAL;
 assert(wcd939x_populate_dt_data(&w,&dev)==-EINVAL && !mbhc_calls && !pulses);
 clear(&w);has_reset=true;assert(wcd939x_populate_dt_data(&w,&dev)==0);
 reset_result=-EIO;assert(wcd939x_reset(&w)==-EIO && pulses==1 && !gpio_sets && !delays);
 puts("Actual WCD reset consumer: explicit provider, legacy sleepable GPIO timing, conflicting/missing properties and supplier/reset errors passed; host only.");
}
C
${CC:-cc} -std=gnu11 -Wall -Wextra -Werror -fsanitize=address,undefined \
    -fno-omit-frame-pointer "$work/check.c" -o "$work/check"
"$work/check"
