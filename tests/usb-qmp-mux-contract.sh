#!/usr/bin/env bash
# Execute the actual QMP mux callback; all power and register operations are mocks.
set -Eeuo pipefail
source_file=${1:?Pass prepared phy-qcom-qmp-combo.c}
mock=$(mktemp)
binary=$(mktemp)
trap 'rm -- "$mock" "$binary"' EXIT
cat > "$mock" <<'C'
#include <assert.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <errno.h>
#include <string.h>
#define guard(type) (void)
#define dev_dbg(dev, ...) do { (void)(dev); if (0) printf(__VA_ARGS__); } while(0)
#define USB_TYPEC_DP_SID 0xff01
#define QSERDES_DP_PHY_PD_CTL 0
#define DP_PHY_PD_CTL_PSR_PWRDN 1
enum { TYPEC_STATE_SAFE, TYPEC_STATE_USB, TYPEC_STATE_MODAL };
enum { TYPEC_MODE_USB2=TYPEC_STATE_MODAL, TYPEC_MODE_USB3 };
enum { TYPEC_DP_STATE_A=TYPEC_STATE_MODAL, TYPEC_DP_STATE_B,
       TYPEC_DP_STATE_C, TYPEC_DP_STATE_D, TYPEC_DP_STATE_E, TYPEC_DP_STATE_F };
C
sed -n '/^enum qmpphy_mode {/,/^};/p' "$source_file" >> "$mock"
cat >> "$mock" <<'C'
struct qmp_combo;
struct phy { struct qmp_combo *qmp;unsigned bus_width; };
struct phy_configure_opts_dp { unsigned lanes,link_rate,voltage[4],pre[4],set_voltages; };
union phy_configure_opts { struct phy_configure_opts_dp dp; };
struct qmp_phy_cfg { void (*dp_aux_init)(struct qmp_combo *); void (*configure_dp_tx)(struct qmp_combo *); };
struct qmp_combo {
 const struct qmp_phy_cfg *cfg;
 int phy_mutex,uke_route_error;
 bool uke_gdsc,dp_powered_on;
 enum qmpphy_mode qmpphy_mode;
 unsigned init_count,usb_init_count,dp_init_count;
 void *usb_phy,*dp_dp_phy,*dev;
 struct phy *dp_phy;
 struct phy_configure_opts_dp dp_opts;
};
struct typec_altmode { unsigned short svid; };
struct typec_mux_state { struct typec_altmode *alt; unsigned long mode; void *data; };
struct typec_mux_dev { struct qmp_combo *qmp; };
static unsigned reconfigurations,operations;
static int reconfigure_result;
static void *typec_mux_get_drvdata(struct typec_mux_dev *mux) { return mux->qmp; }
static int qmp_combo_uke_reconfigure(struct qmp_combo *qmp)
{ assert(qmp->uke_gdsc);reconfigurations++;if(reconfigure_result)qmp->uke_route_error=reconfigure_result;return reconfigure_result; }
static int qmp_combo_usb_power_off(void *phy) { (void)phy;operations++;return 0; }
static int qmp_combo_usb_power_on(void *phy) { (void)phy;operations++;return 0; }
static int qmp_combo_com_exit(struct qmp_combo *qmp,bool force)
{ (void)qmp;(void)force;operations++;return 0; }
static int qmp_combo_com_init(struct qmp_combo *qmp,bool force)
{ (void)qmp;(void)force;operations++;return 0; }
static void writel(unsigned value,void *address)
{ assert(address);*(unsigned *)address=value;operations++; }
static void phy_set_bus_width(struct phy *phy,unsigned width) {assert(phy);phy->bus_width=width;}
static unsigned phy_get_bus_width(struct phy *phy) {return phy->bus_width;}
static struct qmp_combo *phy_get_drvdata(struct phy *phy) {return phy->qmp;}
static bool of_machine_is_compatible(const char *name) {(void)name;return true;}
static const struct qmp_phy_cfg sm7675_usb3dpphy_cfg;
static unsigned voltage_writes;
static void configure_tx(struct qmp_combo *qmp) {assert(qmp->dp_opts.set_voltages);voltage_writes++;}
C
sed -n '/^static int qmp_combo_dp_configure(/,/^static int qmp_combo_dp_calibrate(/p' "$source_file" | sed '$d' >> "$mock"
sed -n '/^static int qmp_combo_typec_mux_set(/,/^static void qmp_combo_typec_switch_unregister(/p' "$source_file" | sed '$d' >> "$mock"
cat >> "$mock" <<'C'
int main(void)
{
 struct qmp_phy_cfg cfg={.configure_dp_tx=configure_tx};
 struct typec_altmode dp={USB_TYPEC_DP_SID},foreign={0x1234};
 struct qmp_combo qmp;
 struct phy phy={.qmp=&qmp};
 struct typec_mux_dev mux={&qmp};
 struct typec_mux_state state={.alt=&dp};
 const unsigned modes[]={TYPEC_DP_STATE_C,TYPEC_DP_STATE_D,TYPEC_DP_STATE_E,TYPEC_DP_STATE_F};
 for(unsigned i=0;i<4;i++) {
  qmp=(struct qmp_combo){.cfg=&cfg,.dp_phy=&phy,.uke_gdsc=true,.qmpphy_mode=QMPPHY_MODE_USB3_ONLY,.init_count=2};
  state.mode=modes[i];reconfigurations=0;
  assert(qmp_combo_typec_mux_set(&mux,&state)==0);
  assert(qmp.qmpphy_mode==((i==0||i==2)?QMPPHY_MODE_DP_ONLY:QMPPHY_MODE_USB3DP));
  assert(reconfigurations==1 && !operations);
  assert(phy.bus_width==((i==0||i==2)?4U:2U));
  union phy_configure_opts opts={.dp={.lanes=4,.link_rate=5400,.set_voltages=1}};
  voltage_writes=0;
  assert(qmp_combo_dp_configure(&phy,&opts)==((i==0||i==2)?0:-ENOSPC));
  assert(voltage_writes==((i==0||i==2)?1U:0U));
  opts.dp.lanes=2;assert(!qmp_combo_dp_configure(&phy,&opts));
  opts.dp.voltage[0]=4;assert(qmp_combo_dp_configure(&phy,&opts)==-EINVAL);
  assert(qmp_combo_typec_mux_set(&mux,&state)==0 && reconfigurations==1);
 }
 for(unsigned mode=TYPEC_STATE_MODAL;mode<32;mode++) {
  if(mode>=TYPEC_DP_STATE_C && mode<=TYPEC_DP_STATE_F)continue;
  qmp=(struct qmp_combo){.cfg=&cfg,.dp_phy=&phy,.uke_gdsc=true,.qmpphy_mode=QMPPHY_MODE_USB3_ONLY};
  state=(struct typec_mux_state){.alt=&dp,.mode=mode};reconfigurations=0;
  assert(qmp_combo_typec_mux_set(&mux,&state)==-EOPNOTSUPP);
  assert(qmp.qmpphy_mode==QMPPHY_MODE_USB3_ONLY && !reconfigurations);
 }
 for(unsigned mode=TYPEC_STATE_SAFE;mode<=TYPEC_MODE_USB3;mode++) {
  qmp=(struct qmp_combo){.cfg=&cfg,.dp_phy=&phy,.uke_gdsc=true,.qmpphy_mode=QMPPHY_MODE_USB3DP};
  state=(struct typec_mux_state){.mode=mode};reconfigurations=0;
  assert(qmp_combo_typec_mux_set(&mux,&state)==0);
  assert(qmp.qmpphy_mode==QMPPHY_MODE_USB3_ONLY && reconfigurations==1);
  assert(!phy.bus_width);
  union phy_configure_opts opts={.dp={.lanes=1,.link_rate=5400}};
  assert(qmp_combo_dp_configure(&phy,&opts)==-ENOSPC);
 }
 qmp=(struct qmp_combo){.cfg=&cfg,.dp_phy=&phy,.uke_gdsc=true,.qmpphy_mode=QMPPHY_MODE_USB3_ONLY};
 state=(struct typec_mux_state){.alt=&foreign,.mode=TYPEC_DP_STATE_D};reconfigurations=0;
 assert(qmp_combo_typec_mux_set(&mux,&state)==-EOPNOTSUPP && !reconfigurations);
 state=(struct typec_mux_state){.alt=&dp,.mode=TYPEC_DP_STATE_D};
 qmp.uke_route_error=-EIO;
 assert(qmp_combo_typec_mux_set(&mux,&state)==-EIO && !reconfigurations);
 qmp.uke_route_error=0;reconfigure_result=-ETIMEDOUT;
 assert(qmp_combo_typec_mux_set(&mux,&state)==-ETIMEDOUT && reconfigurations==1);
 assert(!phy.bus_width);
 assert(qmp_combo_typec_mux_set(&mux,&state)==-ETIMEDOUT && !phy.bus_width);
 reconfigure_result=0;reconfigurations=0;
 qmp.uke_route_error=0;
 qmp.qmpphy_mode=QMPPHY_MODE_DP_ONLY;qmp.dp_powered_on=true;
 assert(qmp_combo_typec_mux_set(&mux,&state)==-EBUSY && !reconfigurations);
 qmp=(struct qmp_combo){.cfg=&cfg,.dp_phy=&phy,.qmpphy_mode=QMPPHY_MODE_USB3_ONLY};
 state.mode=31;
 assert(qmp_combo_typec_mux_set(&mux,&state)==0 && qmp.qmpphy_mode==QMPPHY_MODE_USB3DP);
 puts("Actual QMP mux: valid C/D/E/F, strict unknown modes, unchanged-route no-op, powered-DP refusal, errors and non-Uke fallback passed; host only");
}
C
"${CC:-cc}" -x c -std=gnu11 -Wall -Wextra -Werror "$mock" -o "$binary"
chmod 700 "$binary"
"$binary"
