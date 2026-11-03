#!/usr/bin/env bash
# Execute the production DP routing helper with a cached retimer and failed writes.
set -Eeuo pipefail
source=${1:?Pass prepared pmic_glink_altmode.c}
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
cat > "$work/test.c" <<'C'
#include <assert.h>
#include <stdint.h>
#include <stdbool.h>
#include <errno.h>
#include <stdio.h>
typedef uint8_t u8;
#define DP_STATUS_ENABLED 8
#define DP_STATUS_HPD_STATE 128
#define DP_STATUS_IRQ_HPD 256
#define DP_CONF_SET_PIN_ASSIGN(p) ((p)<<8)
#define BIT(n) (1U<<(n))
#define TYPEC_MODAL_STATE(n) (n)
#define dev_err(dev,...) do {(void)(dev);if(0)printf(__VA_ARGS__);}while(0)
struct typec_displayport_data {unsigned status,conf;};
struct state {void *alt,*data;unsigned mode;};
struct pmic_glink_altmode {void *dev;};
struct pmic_glink_altmode_port {
 struct state state,retimer_state;int dp_alt;void *typec_mux,*typec_retimer;
 unsigned orientation,retimer_dp_orientation;
 bool retimer_dp_valid,retimer_dp_hpd_state;u8 retimer_dp_mode;
};
static unsigned mux_writes,retimer_writes;static int mux_error,retimer_error;
static int typec_mux_set(void *mux,struct state *state) {(void)mux;assert(state->alt&&state->data);++mux_writes;return mux_error;}
static int typec_retimer_set(void *retimer,struct state *state) {(void)retimer;assert(state->alt&&state->data);++retimer_writes;return retimer_error;}
C
awk '/^static int pmic_glink_altmode_enable_dp\(/ {emit=1} emit{print} emit&&/^}/{exit}' "$source" >> "$work/test.c"
cat >> "$work/test.c" <<'C'
int main(void) {
 struct pmic_glink_altmode am={0};struct pmic_glink_altmode_port port={.orientation=1};
 assert(!pmic_glink_altmode_enable_dp(&am,&port,3,true,false));
 assert(port.retimer_dp_valid&&retimer_writes==1);
 assert(!pmic_glink_altmode_enable_dp(&am,&port,3,true,true)&&retimer_writes==1&&mux_writes==2);
 port.orientation=2;
 assert(!pmic_glink_altmode_enable_dp(&am,&port,3,true,true)&&retimer_writes==2);
 assert(!pmic_glink_altmode_enable_dp(&am,&port,3,false,true)&&retimer_writes==3);
 assert(!pmic_glink_altmode_enable_dp(&am,&port,2,false,true)&&retimer_writes==4);
 retimer_error=-EIO;port.orientation=1;
 assert(pmic_glink_altmode_enable_dp(&am,&port,2,false,true)==-EIO&&!port.retimer_dp_valid&&retimer_writes==5);
 retimer_error=0;
 assert(!pmic_glink_altmode_enable_dp(&am,&port,2,false,true)&&port.retimer_dp_valid&&retimer_writes==6);
 mux_error=-EIO;
 assert(pmic_glink_altmode_enable_dp(&am,&port,2,false,true)==-EIO&&!port.retimer_dp_valid&&retimer_writes==6);
 mux_error=0;
 assert(!pmic_glink_altmode_enable_dp(&am,&port,2,false,true)&&retimer_writes==7);
 puts("Production DP IRQ retimer: unchanged routing preserved, pin/orientation/HPD changes and failed-write invalidation: PASS; host only.");
}
C
"${CC:-cc}" -std=gnu11 -O2 -Wall -Wextra -Werror "$work/test.c" -o "$work/test"
"$work/test"
