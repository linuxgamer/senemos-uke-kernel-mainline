#!/usr/bin/env bash
# Execute the real supplier ON grouping and verify every transferred packet.
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <errno.h>
#include <string.h>
typedef uint8_t u8; typedef uint16_t u16;
#define ARRAY_SIZE(a) (sizeof(a)/sizeof((a)[0]))
#define BIT(n) (1U<<(n))
#define ALIGN(n,a) (((n)+(a)-1)&~((a)-1))
#define MIPI_DSI_DCS_LONG_WRITE 0x39
#define MIPI_DSI_MSG_USE_LPM 1
#define dev_err(...) ((void)0)
#define dev_info(...) ((void)0)
struct drm_display_mode {unsigned int clock,hdisplay,hsync_start,hsync_end,htotal,
    vdisplay,vsync_start,vsync_end,vtotal,width_mm,height_mm;};
C
sed -n '/^struct o82_command {/,/^struct o82_panel {/p' "$root/src/display/panel-xiaomi-o82.c" |
    sed '$d; /#include "o82-data.h"/d' >> "$work/check.c"
cat "$root/src/display/o82-data.h" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
struct mipi_dsi_device {int unused;};
struct mipi_dsi_msg {unsigned int channel,type,flags;size_t tx_len;const void *tx_buf;};
struct o82_panel {const struct o82_profile *profiles,*active;struct mipi_dsi_device *dsi[2];
    bool initial_120hz_only,oem_refresh_modes;};
static const struct o82_profile *expected;
static unsigned int command,chunks,total,settled;
static int failure;
static void msleep(unsigned int ms) {assert(ms==120);settled+=ms;}
static int qcom_uke_dsi_on_batch(struct mipi_dsi_device *dsi,const struct mipi_dsi_msg *msgs,unsigned int count) {
    (void)dsi; assert(count && count<=31);
    unsigned int bytes=0;
    for(unsigned int i=0;i<count;i++) {
        const struct o82_command *cmd=&expected->on[command++];
        assert(msgs[i].type==cmd->type && msgs[i].channel==cmd->channel);
        assert(msgs[i].flags==MIPI_DSI_MSG_USE_LPM && msgs[i].tx_len==cmd->len);
        assert(!memcmp(msgs[i].tx_buf,cmd->data,cmd->len));
        bytes+=ALIGN(cmd->len+4,4);
    }
    assert(bytes<=248);total+=bytes;
    return (int)chunks++==failure ? -EIO:0;
}
C
sed -n '/^static int o82_on_batch(/,/^static int o82_power_off(/p' "$root/src/display/panel-xiaomi-o82.c" |
    sed '$d' >> "$work/check.c"
cat >> "$work/check.c" <<'C'
int main(void) {
    assert(ARRAY_SIZE(o82_modes)==7 && o82_modes[5].mode.hdisplay==3200);
    for(unsigned int supplier=0;supplier<2;supplier++)for(unsigned int group=0;group<3;group++) {
        struct o82_panel ctx={.profiles=supplier ? o82_42_02_0b_profiles:o82_36_02_0a_profiles,
            .oem_refresh_modes=true};
        ctx.active=expected=&ctx.profiles[group];
        const unsigned int count=supplier ? 8:10;
        for(failure=-1;failure<(int)count;failure++) {
            command=chunks=total=settled=0;
            assert(o82_on_batch(&ctx)==(failure<0 ? 0:-EIO));
            assert(chunks==(failure<0 ? count:(unsigned int)failure+1));
            if(failure<0) {
                assert(command==(supplier ? 108U:171U));
                assert(total==(supplier ? 884U:1448U) && settled==120);
            } else assert(settled==(failure>=(int)count-2 ? 120U:0U));
        }
        ctx.oem_refresh_modes=false;command=chunks=0;
        assert(o82_on_batch(&ctx)==-EINVAL && !command && !chunks);
        ctx.oem_refresh_modes=true;ctx.active=NULL;
        assert(o82_on_batch(&ctx)==-EINVAL && !command && !chunks);
    }
}
C
"${CC:-cc}" -std=gnu11 -O2 -Wall -Wextra -Werror "$work/check.c" -o "$work/check"
"$work/check"
printf 'O82 ON grouping: both suppliers/all groups, exact packets, counts, delays and every chunk failure passed\n'
