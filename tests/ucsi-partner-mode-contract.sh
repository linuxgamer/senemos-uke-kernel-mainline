#!/usr/bin/env bash
# Execute the shared partner handler with USB/Alt Mode status combinations.
set -Eeuo pipefail
source_file=${1:?Pass prepared ucsi.c}
header=${source_file%/*}/ucsi.h
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#define BIT(n) (1U << (n))
#define fallthrough __attribute__((fallthrough))
C
awk '$1=="#define" && ($2 ~ /^UCSI_CONSTAT_PARTNER_TYPE_/ ||
    $2 ~ /^UCSI_VERSION_[123]_0$/ || $2=="UCSI_USB4_IMPLIES_USB") {print}' "$header" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
enum usb_role { USB_ROLE_NONE, USB_ROLE_HOST, USB_ROLE_DEVICE };
enum { TYPEC_HOST, TYPEC_DEVICE, TYPEC_STATE_USB=10, TYPEC_MODE_DEBUG,
       TYPEC_MODE_AUDIO, USB_MODE_USB4 };
enum field { F_CONNECTED, F_PARTNER_TYPE, F_PARTNER_FLAG_USB,
             F_PARTNER_FLAG_ALT_MODE, F_PARTNER_FLAG_USB4_GEN3,
             F_PARTNER_FLAG_USB4_GEN4 };
struct ucsi { unsigned version, quirks; void *dev; };
struct ucsi_connector {
    struct ucsi *ucsi;
    void *port, *partner, *usb_role_sw;
    unsigned num, flags, type;
    bool connected;
};
static unsigned field_value(struct ucsi_connector *c, enum field f) {
    switch(f) {
    case F_CONNECTED: return c->connected;
    case F_PARTNER_TYPE: return c->type;
    case F_PARTNER_FLAG_USB: return !!(c->flags & 1);
    case F_PARTNER_FLAG_ALT_MODE: return !!(c->flags & 2);
    case F_PARTNER_FLAG_USB4_GEN3: return !!(c->flags & 4);
    case F_PARTNER_FLAG_USB4_GEN4: return !!(c->flags & 8);
    }
    assert(0); return 0;
}
#define UCSI_CONSTAT(c, name) field_value(c, F_##name)
static unsigned mode_calls, usb4_calls, role_calls, errors;
static int last_mode, data_role, role_error;
static enum usb_role last_role;
static void typec_set_data_role(void *p, int role) { assert(p); data_role=role; }
static int typec_set_mode(void *p, int mode) { assert(p); ++mode_calls; last_mode=mode; return 0; }
static void typec_partner_set_usb_mode(void *p, int mode) { assert(p && mode==USB_MODE_USB4); ++usb4_calls; }
static int usb_role_switch_set_role(void *s, enum usb_role role) {
    assert(s); ++role_calls; last_role=role; return role_error;
}
#define dev_err(...) (++errors)
C
awk '/^static void ucsi_partner_change\(/ {emit=1;found=1}
    emit {print} emit && /^}/ {exit} END {if(!found)exit 1}' "$source_file" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
int main(void) {
    const unsigned versions[]={UCSI_VERSION_1_0,UCSI_VERSION_2_0,UCSI_VERSION_3_0};
    for(unsigned v=0;v<3;++v) for(unsigned flags=0;flags<16;++flags)
    for(unsigned type=0;type<8;++type) for(unsigned connected=0;connected<2;++connected)
    for(unsigned quirk=0;quirk<2;++quirk) for(unsigned fail=0;fail<2;++fail)
    for(unsigned partner=0;partner<2;++partner) {
        struct ucsi u={versions[v],quirk?UCSI_USB4_IMPLIES_USB:0,NULL};
        struct ucsi_connector c={&u,(void *)1,partner?(void *)1:NULL,(void *)1,1,flags,type,connected};
        mode_calls=usb4_calls=role_calls=errors=0;
        last_mode=99; data_role=-1; role_error=fail?-5:0;
        enum usb_role expected_role=USB_ROLE_NONE;
        int expected_data=-1, expected_mode=99;
        if(type==UCSI_CONSTAT_PARTNER_TYPE_UFP || type==UCSI_CONSTAT_PARTNER_TYPE_CABLE_AND_UFP)
            expected_role=USB_ROLE_HOST;
        if(type==UCSI_CONSTAT_PARTNER_TYPE_DFP) expected_role=USB_ROLE_DEVICE;
        if(type==UCSI_CONSTAT_PARTNER_TYPE_UFP || type==UCSI_CONSTAT_PARTNER_TYPE_CABLE_AND_UFP ||
           type==UCSI_CONSTAT_PARTNER_TYPE_CABLE) expected_data=TYPEC_HOST;
        if(type==UCSI_CONSTAT_PARTNER_TYPE_DFP) expected_data=TYPEC_DEVICE;
        if(!(flags&1) && quirk && !(flags&12)) expected_role=USB_ROLE_NONE;
        if(connected) {
            if(type==UCSI_CONSTAT_PARTNER_TYPE_DEBUG) expected_mode=TYPEC_MODE_DEBUG;
            else if(type==UCSI_CONSTAT_PARTNER_TYPE_AUDIO) expected_mode=TYPEC_MODE_AUDIO;
            else if((flags&3)==1) expected_mode=TYPEC_STATE_USB;
        }
        bool expected_usb4=connected && partner && ((v>=2 && (flags&8)) || (v>=1 && (flags&4)));
        ucsi_partner_change(&c);
        assert(last_mode==expected_mode && mode_calls==(unsigned)(expected_mode!=99));
        assert(last_role==expected_role && data_role==expected_data && role_calls==1);
        assert(errors==fail && usb4_calls==(unsigned)expected_usb4);
    }
}
C
"${CC:-cc}" -std=gnu11 -O2 -Wall -Wextra -Werror "$work/check.c" -o "$work/check"
"$work/check"
printf 'Actual UCSI partner handler preserves Alt Mode, USB/data roles, accessories, USB4 and role errors across 6144 cases\n'
