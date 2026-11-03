#!/usr/bin/env bash
# Run the actual 7.3 dispatch and UBWC helpers against bounded host fixtures.
set -Eeuo pipefail
kernel=${1:?Pass the prepared Linux 7.3 source}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cat > "$work/usb.c" <<'C'
#include <assert.h>
#include <stdbool.h>
#include <errno.h>
struct device { void *of_node; };
struct usb_phy { void *set_power; struct device *dev; };
struct usb_gadget { int unused; };
struct notifier_block { void *notifier_call; };
struct dwc3 { struct usb_phy *usb2_phy; void *usb_psy; struct notifier_block psy_nb; int vbus_draw_lock, vbus_draw_work; unsigned int current_limit; struct device *dev; };
static struct dwc3 active;
static bool uke;
static int queued, direct, phy_calls, locked;
static void *system_percpu_wq;
#define spin_lock_irqsave(l,f) ((void)(l),(f)=0,++locked)
#define spin_unlock_irqrestore(l,f) ((void)(l),(void)(f),--locked)
#define dev_dbg(...) ((void)0)
static struct dwc3 *gadget_to_dwc(struct usb_gadget *g) { (void)g; return &active; }
static bool of_device_is_compatible(void *node,const char *name) { (void)node;(void)name; return true; }
static bool of_machine_is_compatible(const char *name) { (void)name; return uke; }
static int usb_phy_set_power(struct usb_phy *phy,unsigned int ma) { (void)phy; assert(ma==500); ++phy_calls; return 7; }
static bool mod_delayed_work(void *q,int *w,unsigned long delay) { assert(q==system_percpu_wq && w==&active.vbus_draw_work && !delay && locked==1); ++queued; return true; }
static int dwc3_gadget_vbus_draw(struct usb_gadget *g,unsigned int ma) { (void)g; assert(ma==500); ++direct; return 42; }
C
for name in dwc3_gadget_vbus_draw_async dwc3_gadget_vbus_draw_select; do
    awk -v name="$name" '$0~"^static int "name"\\("{emit=1} emit{print} emit&&/^}/{emit=0}' "$kernel/drivers/usb/dwc3/gadget.c" >> "$work/usb.c"
done
cat >> "$work/usb.c" <<'C'
int main(void) {
 struct usb_gadget g={0}; struct usb_phy phy={.set_power=&active};
 uke=true; assert(dwc3_gadget_vbus_draw_select(&g,500)==42 && direct==1 && !queued);
 uke=false; active.usb_psy=&active;
 assert(!dwc3_gadget_vbus_draw_select(&g,500) && active.current_limit==500 && queued==1 && !locked);
 active.usb_psy=0; assert(dwc3_gadget_vbus_draw_select(&g,500)==-EOPNOTSUPP && !locked);
 active.psy_nb.notifier_call=&active;
 assert(!dwc3_gadget_vbus_draw_select(&g,500) && queued==1 && !locked);
 active.usb2_phy=&phy;
 assert(dwc3_gadget_vbus_draw_select(&g,500)==7 && phy_calls==1 && direct==1);
 return 0;
}
C
"${CC:-cc}" -std=gnu11 -O2 -Wall -Wextra -Werror "$work/usb.c" -o "$work/usb"
"$work/usb"
mkdir -p "$work/include/linux"
printf '#define BIT(n) (1U << (n))\n' > "$work/include/linux/bits.h"
printf '#include <stdint.h>\n#include <stdbool.h>\ntypedef uint32_t u32;\n' > "$work/include/linux/types.h"
touch "$work/include/linux/err.h" "$work/include/linux/printk.h"
cat > "$work/ubwc.c" <<'C'
#include <assert.h>
#define IS_ENABLED(x) 1
#include <linux/soc/qcom/ubwc.h>
C
awk '/^static const struct qcom_ubwc_cfg_data ubwc_4_0_hbb16 =/{emit=1} emit{print} emit&&/^};/{emit=0}' "$kernel/drivers/soc/qcom/ubwc_config.c" >> "$work/ubwc.c"
cat >> "$work/ubwc.c" <<'C'
int main(void) {
 const struct qcom_ubwc_cfg_data *c=&ubwc_4_0_hbb16;
 assert(c->ubwc_enc_version==UBWC_4_0 && c->highest_bank_bit==16);
 assert(qcom_ubwc_swizzle(c)==(UBWC_SWIZZLE_ENABLE_LVL2|UBWC_SWIZZLE_ENABLE_LVL3));
 assert(qcom_ubwc_bank_spread(c) && qcom_ubwc_macrotile_mode(c));
 return 0;
}
C
grep -Fq '{ .compatible = "qcom,sm7675", .data = &ubwc_4_0_hbb16, },' "$kernel/drivers/soc/qcom/ubwc_config.c"
"${CC:-cc}" -std=gnu11 -O2 -Wall -Wextra -Werror -Wno-unused-parameter -I "$work/include" -I "$kernel/include" "$work/ubwc.c" -o "$work/ubwc"
"$work/ubwc"
cat > "$work/rpmh.c" <<'C'
#include <assert.h>
#include <errno.h>
#include <stdint.h>
struct device { int unused; };
struct tcs_cmd { uint32_t addr, data; int wait; };
C
awk '/^static inline int rpmh_read\(/{emit=1} emit{print} emit&&/^}/{emit=0}' "$kernel/include/soc/qcom/rpmh-uke.h" >> "$work/rpmh.c"
cat >> "$work/rpmh.c" <<'C'
int main(void) {
 struct device dev={0}; struct tcs_cmd cmd={.addr=0x1234,.data=0xdeadbeef,.wait=1};
 assert(rpmh_read(&dev,&cmd)==-EOPNOTSUPP);
 assert(cmd.addr==0x1234 && cmd.data==0xdeadbeef && cmd.wait==1);
 assert(rpmh_read(0,0)==-EOPNOTSUPP);
 return 0;
}
C
"${CC:-cc}" -std=gnu11 -O2 -Wall -Wextra -Werror -Wno-unused-parameter "$work/rpmh.c" -o "$work/rpmh"
"$work/rpmh"
echo 'Actual gadget dispatch, UBWC defaults and unsupported RPMh read refusal passed'
