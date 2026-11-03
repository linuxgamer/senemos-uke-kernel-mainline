#!/usr/bin/env bash
# Exercise actual MSM AUX and DRM I2C callbacks against a protocol model, not hardware.
set -Eeuo pipefail
source_file=${1:?Pass prepared dp_aux.c}
helper_file=${2:?Pass drm_dp_helper.c}
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
cat > "$work/check.cpp" <<'CPP'
#include <cassert>
#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>
using u8=uint8_t;
using u32=uint32_t;
using ssize_t=long;
#define DP_AUX_I2C_READ 1
#define DP_AUX_I2C_WRITE 0
#define DP_AUX_NATIVE_READ 9
#define DP_AUX_NATIVE_WRITE 8
#define DP_AUX_I2C_MOT 4
#define DP_AUX_NATIVE_REPLY_ACK 0
#define DP_AUX_I2C_REPLY_ACK 0
#define DP_AUX_NATIVE_REPLY_DEFER 2
#define DP_AUX_I2C_REPLY_DEFER 8
#define DP_AUX_NATIVE_REPLY_NACK 1
#define DP_AUX_I2C_REPLY_NACK 4
#define DP_AUX_MAX_PAYLOAD_BYTES 16
#define MAX_AUX_RETRIES 5
#define I2C_M_RD 1
#define I2C_M_STOP 0x8000
#define DRM_ERROR(...) do {} while (0)
#define container_of(p,t,m) reinterpret_cast<t *>(reinterpret_cast<char *>(p)-offsetof(t,m))
struct drm_dp_aux_msg { unsigned address; u8 request,reply; void *buffer; size_t size; };
struct drm_dp_aux { void *dev; bool powered_down,no_zero_sized; ssize_t (*transfer)(drm_dp_aux *,drm_dp_aux_msg *); };
enum msm_dp_aux_err { DP_AUX_ERR_NONE,DP_AUX_ERR_ADDR,DP_AUX_ERR_TOUT,DP_AUX_ERR_NACK,DP_AUX_ERR_DEFER,DP_AUX_ERR_NACK_DEFER,DP_AUX_ERR_PHY };
struct msm_dp_aux_private {
 int mutex; void *phy; unsigned retry_cnt; bool cmd_busy,native,read,no_send_addr,no_send_stop,initted,is_edp,enable_xfers;
 u32 offset,segment; msm_dp_aux_err aux_error_num; drm_dp_aux msm_dp_aux;
};
struct command { unsigned address; size_t size; bool read,stop; };
static std::vector<command> commands;
static bool reply_ready;
static size_t reply_offset;
static int pm_error;
static int pm_gets,pm_puts;
static int pm_runtime_resume_and_get(void *) { ++pm_gets; return pm_error; }
static void pm_runtime_put_sync(void *) { ++pm_puts; }
static void mutex_lock(int *) {}
static void mutex_unlock(int *) {}
static void phy_calibrate(void *) {}
static bool msm_dp_aux_is_link_connected(drm_dp_aux *) { return false; }
static void msm_dp_aux_reset(msm_dp_aux_private *) {}
static ssize_t msm_dp_aux_cmd_fifo_tx(msm_dp_aux_private *a,drm_dp_aux_msg *m) {
 commands.push_back({m->address,m->size,a->read,!a->no_send_stop});
 if (m->address==0x37 && !a->read) {
  reply_ready=m->size==5 && !a->no_send_stop;
  reply_offset=0;
 }
 return static_cast<ssize_t>(m->size);
}
static ssize_t msm_dp_aux_cmd_fifo_rx(msm_dp_aux_private *,drm_dp_aux_msg *m) {
 static const u8 reply[]={0x6e,0x88,0x02,0x00,0x10,0x00,0x00,0x64,0x00,0x32,0xf2};
 auto *out=static_cast<u8 *>(m->buffer);
 for(size_t i=0;i<m->size;i++) out[i]=m->address==0x37 && reply_ready && reply_offset<sizeof(reply) ? reply[reply_offset++] : 0;
 return static_cast<ssize_t>(m->size);
}
CPP
awk '/^static (void msm_dp_aux_(update_offset_and_segment|transfer_helper)|ssize_t msm_dp_aux_transfer)\(/ {emit=1} emit {print} emit && /^}/ {emit=0}' "$source_file" |
 sed 's/data = input_msg->buffer;/data = static_cast<u8 *>(input_msg->buffer);/' >> "$work/check.cpp"
cat >> "$work/check.cpp" <<'CPP'
struct i2c_adapter { drm_dp_aux *algo_data; };
struct i2c_msg { unsigned addr,flags; size_t len; u8 *buf; };
static unsigned dp_aux_i2c_transfer_size=16;
static unsigned clamp(unsigned v,unsigned lo,unsigned hi) { return v<lo?lo:v>hi?hi:v; }
static unsigned min(unsigned a,size_t b) { return a<b?a:static_cast<unsigned>(b); }
static int drm_dp_i2c_do_msg(drm_dp_aux *a,drm_dp_aux_msg *m) { return static_cast<int>(a->transfer(a,m)); }
static int drm_dp_i2c_drain_msg(drm_dp_aux *a,drm_dp_aux_msg *m) { return drm_dp_i2c_do_msg(a,m); }
CPP
awk '/^static (int drm_dp_i2c_xfer|void drm_dp_i2c_msg_set_request)\(/ {emit=1} emit {print} emit && /^}/ {emit=0}' "$helper_file" >> "$work/check.cpp"
if grep -Fq 'aux->msm_dp_aux.no_zero_sized = true;' "$source_file"; then
 printf 'static constexpr bool no_zero=true;\n' >> "$work/check.cpp"
else
 printf 'static constexpr bool no_zero=false;\n' >> "$work/check.cpp"
fi
cat >> "$work/check.cpp" <<'CPP'
int main() {
 msm_dp_aux_private a{};
 a.initted=a.enable_xfers=true;
 a.msm_dp_aux.no_zero_sized=no_zero;
 a.msm_dp_aux.transfer=msm_dp_aux_transfer;
 i2c_adapter bus{&a.msm_dp_aux};
 u8 request[]={0x51,0x82,0x01,0x10,0xac}, reply[40]{};
 i2c_msg write{0x37,0,sizeof(request),request},read{0x37,I2C_M_RD,sizeof(reply),reply};
 assert(drm_dp_i2c_xfer(&bus,&write,1)==1);
 assert(commands.size()==1 && commands.back().stop);
 commands.clear();
 assert(drm_dp_i2c_xfer(&bus,&read,1)==1);
 assert(commands.size()==3 && commands[0].read && commands[1].read && commands[2].read);
 assert(!commands[0].stop && !commands[1].stop && commands[2].stop);
 assert(reply[0]==0x6e && reply[1]==0x88 && reply[4]==0x10 && reply[9]==0x32);
 // EDID's final chunk still needs its segment/offset workaround without MOT.
 commands.clear(); a.native=false; a.segment=1; a.offset=0x90;
 drm_dp_aux_msg edid{0x50,DP_AUX_I2C_READ,0,reply,16};
 msm_dp_aux_transfer_helper(&a,&edid,true);
 assert(commands.size()==2 && commands[0].address==0x30 && commands[1].address==0x50);
 assert(a.offset==0xa0 && a.segment==1);
 commands.clear(); a.offset=0x70;
 msm_dp_aux_transfer_helper(&a,&edid,true);
 assert(a.offset==0x80 && a.segment==0);
 // DDC and native reads must never advance EDID state or inject offset writes.
 for (unsigned addr : {0x37U,0x40U,0x51U}) {
  commands.clear(); a.offset=0x90; a.segment=1;
  drm_dp_aux_msg m{addr,DP_AUX_I2C_READ|DP_AUX_I2C_MOT,0,reply,16};
  msm_dp_aux_transfer_helper(&a,&m,true);
  assert(commands.empty() && a.offset==0x90 && a.segment==1);
 }
 commands.clear(); a.native=true;
 msm_dp_aux_transfer_helper(&a,&edid,true);
 assert(commands.empty());
 // Preserve PM, initialization, disconnected-link and native-transfer boundaries.
 drm_dp_aux_msg native{0x100,DP_AUX_NATIVE_READ,0,reply,8};
 assert(msm_dp_aux_transfer(&a.msm_dp_aux,&native)==8 && commands.size()==1);
 commands.clear(); pm_error=-EHOSTDOWN;
 assert(msm_dp_aux_transfer(&a.msm_dp_aux,&native)==-EHOSTDOWN && commands.empty());
 pm_error=0; a.initted=false;
 assert(msm_dp_aux_transfer(&a.msm_dp_aux,&native)==-EIO && commands.empty());
 a.initted=true; a.enable_xfers=false;
 assert(msm_dp_aux_transfer(&a.msm_dp_aux,&native)==-ENXIO && commands.empty());
 assert(pm_gets==pm_puts+1);
 puts("Actual MSM AUX / DRM I2C callbacks: DDC STOP/chunks, EDID final segment, native and PM guards passed; protocol model, not hardware");
}
CPP
"${CXX:-c++}" -std=c++20 -O2 -Wall -Wextra -Werror -Wno-sign-compare "$work/check.cpp" -o "$work/check"
"$work/check"
