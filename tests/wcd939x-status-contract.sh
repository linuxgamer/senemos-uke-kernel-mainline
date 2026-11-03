#!/usr/bin/env bash
# Compile the actual driver apply function against a fault-injected register map.
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d); trap 'rm -rf -- "$work"' EXIT
cat > "$work/check.c" <<'EOF'
#include <assert.h>
#include <stdbool.h>
#include <errno.h>
#include <string.h>
#define BIT(n) (1U<<(n))
#define GENMASK(h,l) (((~0U)>>(31-(h))) & ((~0U)<<(l)))
#define FIELD_PREP(mask,v) (((v)<<__builtin_ctz(mask))&(mask))
enum typec_orientation { TYPEC_ORIENTATION_NONE, TYPEC_ORIENTATION_NORMAL, TYPEC_ORIENTATION_REVERSE };
enum { TYPEC_STATE_SAFE, TYPEC_STATE_USB, TYPEC_STATE_MODAL, TYPEC_MODE_USB2, TYPEC_MODE_USB3,
       TYPEC_DP_STATE_C, TYPEC_DP_STATE_D, TYPEC_DP_STATE_E, TYPEC_DP_STATE_F };
#define USB_TYPEC_DP_SID 0xff01
struct regmap { unsigned int value[0x500]; int calls, fail, eq_drops; unsigned int read_address; };
struct uke_usbss { struct regmap *regmap; bool removing,applied; enum typec_orientation orientation;
 unsigned long mode; unsigned int svid; int last_error; };
static int regmap_update_bits(struct regmap *r,unsigned int a,unsigned int m,unsigned int v) {
 if(++r->calls==r->fail)return -EREMOTEIO;
 assert(a<0x500);
 if(a==0x415 && (r->value[a]&0x80) && (m&0x80) && !(v&0x80))++r->eq_drops;
 r->value[a]=(r->value[a]&~m)|(v&m);return 0;
}
static int regmap_clear_bits(struct regmap *r,unsigned int a,unsigned int m){return regmap_update_bits(r,a,m,0);}
static int regmap_set_bits(struct regmap *r,unsigned int a,unsigned int m){return regmap_update_bits(r,a,m,m);}
static int regmap_read(struct regmap *r,unsigned int a,unsigned int *v) {
 if(++r->calls==r->fail)return -EREMOTEIO;
 assert(a<0x500);r->read_address=a;*v=r->value[a];return 0;
}
static void usleep_range(unsigned int a,unsigned int b){(void)a;(void)b;}
EOF
sed -n '/^#define DP_DN_MISC1 /,/^#define EQ_EN /p' "$root/src/usb/wcd939x-uke-typec.c" >> "$work/check.c"
sed -n '/^static int uke_usbss_apply(/,/^static int uke_usbss_orientation(/p' "$root/src/usb/wcd939x-uke-typec.c" | sed '$d' >> "$work/check.c"
cat >> "$work/check.c" <<'EOF'
int main(void) {
 struct regmap r;struct uke_usbss u;
 for(unsigned int orientation=TYPEC_ORIENTATION_NORMAL;orientation<=TYPEC_ORIENTATION_REVERSE;++orientation)
  for(unsigned int bits=0;bits<256;++bits) {
   memset(&r,0,sizeof(r));memset(&u,0,sizeof(u));u.regmap=&r;
   r.value[0x406]=9; r.value[0x407]=bits;
   const bool p1=bits&BIT(3),m1=bits&BIT(2),p2=bits&BIT(7),m2=bits&BIT(6);
   const bool expected=orientation==TYPEC_ORIENTATION_NORMAL?(p1&&m2&&!p2&&!m1):(p2&&m1&&!p1&&!m2);
   int ret=uke_usbss_apply(&u,orientation,TYPEC_DP_STATE_C,USB_TYPEC_DP_SID);
   assert((ret==0)==expected && u.applied==expected && r.read_address==0x407);
   if(!expected)assert(!(r.value[0x403]&(BIT(6)|BIT(5)|BIT(4)|BIT(3))));
  }
 memset(&r,0,sizeof(r));memset(&u,0,sizeof(u));u.regmap=&r;r.value[0x407]=0x4b;
 assert(uke_usbss_apply(&u,TYPEC_ORIENTATION_NORMAL,TYPEC_DP_STATE_D,USB_TYPEC_DP_SID)==0);
 const int operations=r.calls;
 for(int failure=1;failure<=operations;++failure) {
  memset(&r,0,sizeof(r));memset(&u,0,sizeof(u));u.regmap=&r;r.value[0x407]=0x48;r.fail=failure;
  assert(uke_usbss_apply(&u,TYPEC_ORIENTATION_NORMAL,TYPEC_DP_STATE_C,USB_TYPEC_DP_SID)==-EREMOTEIO);
  assert(!u.applied && u.last_error==-EREMOTEIO);
 }
 memset(&r,0,sizeof(r));memset(&u,0,sizeof(u));u.regmap=&r;
 assert(uke_usbss_apply(&u,TYPEC_ORIENTATION_NORMAL,TYPEC_STATE_USB,0)==0 && !r.read_address);
 assert((r.value[0x403]&(BIT(4)|BIT(3)))==(BIT(4)|BIT(3)));
 int calls=r.calls;
 assert(uke_usbss_apply(&u,TYPEC_ORIENTATION_NORMAL,TYPEC_STATE_USB,0)==0 && r.calls==calls);
 for(unsigned long mode=TYPEC_DP_STATE_C;mode<=TYPEC_DP_STATE_F;++mode) {
  r.value[0x407]=0x48;r.eq_drops=0;
  assert(uke_usbss_apply(&u,TYPEC_ORIENTATION_NORMAL,mode,USB_TYPEC_DP_SID)==0);
  assert(!r.eq_drops && (r.value[0x403]&(BIT(4)|BIT(3)))==(BIT(4)|BIT(3)));
  calls=r.calls;
  assert(uke_usbss_apply(&u,TYPEC_ORIENTATION_NORMAL,mode,USB_TYPEC_DP_SID)==0 && r.calls==calls);
 }
 assert(uke_usbss_apply(&u,TYPEC_ORIENTATION_NORMAL,TYPEC_DP_STATE_C,0x1234)==-EOPNOTSUPP && !u.applied);
 assert(uke_usbss_apply(&u,TYPEC_ORIENTATION_NORMAL,TYPEC_STATE_USB,0)==0 && u.applied);
 u.removing=true;assert(uke_usbss_apply(&u,TYPEC_ORIENTATION_NORMAL,TYPEC_STATE_USB,0)==-ESHUTDOWN);
 return 0;
}
EOF
${CC:-cc} -std=c11 -Wall -Wextra -Werror "$work/check.c" -o "$work/check"
"$work/check"
echo 'Actual WCD apply: orientation/status/fault checks, unchanged-route no-op and uninterrupted USB EQ across DP transitions passed; no hardware test'
