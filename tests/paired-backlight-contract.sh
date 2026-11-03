#!/usr/bin/env bash
# Host-only faults in the actual paired driver, including rollback and readback.
set -Eeuo pipefail
source_file=${1:?Pass the prepared ktz8866.c}
oem_header=${2:?Pass the pinned OEM mi_backlight_ktz8866.h}
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
{
    cat <<'CPP'
#include <cassert>
#include <cerrno>
#include <cstring>
#include <initializer_list>
#define BIT(n) (1U << (n))
#define MAX_BRIGHTNESS 2047U
#define BL_LEVEL_MAX 2047U
#define DIV_ROUND_UP(value, divisor) (((value)+(divisor)-1)/(divisor))
enum { DEVICE_ID=1, BL_CFG1=2, BL_BRT_LSB=4, BL_BRT_MSB=5, BL_EN=8, BL_EN_BIT=BIT(6),
       BACKLIGHT_RAW=1, BACKLIGHT_SCALE_NON_LINEAR=2, DL_FLAG_AUTOREMOVE_CONSUMER=4, EPROBE_DEFER=517 };
struct device { bool bound=true, locked=false; int refs=1; void *of_node=nullptr; };
struct ktz8866;
struct i2c_client { device dev; unsigned int addr=0x11; ktz8866 *data=nullptr; };
struct regmap { unsigned int regs[22]; };
struct mutex { bool locked = false; };
struct backlight_device;
struct ktz8866 { i2c_client *client; struct regmap *regmap; ktz8866 *peer; mutex lock;
                 bool secondary=false; backlight_device *backlight=nullptr; };
struct backlight_device { ktz8866 *data; struct { unsigned int brightness; } props; bool blank=false; };
int operations, writes, failure=-1, second_failure=-1, mismatch=-1, errors;
bool persistent_failure;
int bus() {
    int position=operations++;
    return position==failure || position==second_failure || (persistent_failure && position>=failure) ? -EIO : 0;
}
int regmap_read(regmap *map, unsigned int reg, unsigned int *value) {
    int position=operations, ret=bus(); if (ret) return ret;
    *value=map->regs[reg]; if (position==mismatch) *value ^= 1; return 0;
}
int ktz8866_write(ktz8866 *ktz, unsigned int reg, unsigned int value) {
    assert(reg==BL_EN || reg==BL_BRT_LSB || reg==BL_BRT_MSB);
    int ret=bus(); if (ret) return ret;
    writes++; ktz->regmap->regs[reg]=value; return 0;
}
int ktz8866_update_bits(ktz8866 *ktz, unsigned int reg, unsigned int mask, unsigned int value) {
    return ktz8866_write(ktz,reg,(ktz->regmap->regs[reg]&~mask)|value);
}
ktz8866 *bl_get_data(backlight_device *bl) { return bl->data; }
unsigned int backlight_get_brightness(backlight_device *bl) { return bl->blank ? 0 : bl->props.brightness; }
bool backlight_is_blank(backlight_device *bl) { return bl->blank; }
void mutex_lock(mutex *m) { assert(!m->locked); m->locked=true; }
void mutex_unlock(mutex *m) { assert(m->locked); m->locked=false; }
void dev_err(device *, const char *, int) { errors++; }
struct backlight_properties { int type; unsigned int max_brightness; int scale; int brightness=0; };
struct device_node {} node;
i2c_client *candidate;
bool absent_node, action_failure, link_failure, registration_failure;
void (*cleanup_action)(void *); void *cleanup_data;
backlight_device registered;
backlight_properties registered_properties{};
device_node *of_parse_phandle(void *, const char *, int) { return absent_node ? nullptr : &node; }
i2c_client *of_find_i2c_device_by_node(device_node *) { if(candidate) candidate->dev.refs++; return candidate; }
void of_node_put(device_node *) {}
bool device_is_bound(device *dev) { return dev->bound; }
void put_device(void *data) { static_cast<device *>(data)->refs--; }
void device_lock(device *dev) { assert(!dev->locked); dev->locked=true; }
void device_unlock(device *dev) { assert(dev->locked); dev->locked=false; }
ktz8866 *i2c_get_clientdata(i2c_client *client) { return client->data; }
int devm_add_action_or_reset(device *, void (*action)(void *), void *data) {
    if(action_failure) { action(data); return -ENOMEM; }
    cleanup_action=action; cleanup_data=data; return 0;
}
void *device_link_add(device *, device *, int) { return link_failure ? nullptr : &node; }
struct backlight_ops { int (*update_status)(backlight_device *); int (*get_brightness)(backlight_device *); };
const backlight_ops ktz8866_uke_backlight_ops{};
backlight_device *devm_backlight_device_register(device *, const char *, device *, ktz8866 *data,
                                               const backlight_ops *, const backlight_properties *props) {
    registered_properties=*props;
    registered={data,{static_cast<unsigned int>(props->brightness)}};
    return registration_failure ? reinterpret_cast<backlight_device *>(-ENOMEM) : &registered;
}
int PTR_ERR_OR_ZERO(backlight_device *ptr) { auto value=reinterpret_cast<long>(ptr); return value<0 ? value : 0; }
CPP
    cat "$(dirname "$source_file")/ktz8866-uke-levels.h"
    awk '/^static const int mi_bl_level_remap/ {emit=1} emit {print} emit && /};/ {exit}' "$oem_header"
    awk '/^struct ktz8866_state/ {emit=1} /^static const struct backlight_ops ktz8866_uke_backlight_ops/ {emit=0} emit {print}' "$source_file"
    awk '/^static void ktz8866_put_peer/ {emit=1} /^static int ktz8866_backlight_update_status/ {emit=0} emit {print}' "$source_file"
    cat <<'CPP'
void reset(regmap (&maps)[2]) {
    operations=writes=errors=0; failure=second_failure=mismatch=-1; persistent_failure=false;
    for (int i=0;i<2;i++) {
        for (unsigned int r=0;r<22;r++) maps[i].regs[r]=0xa0+r;
        maps[i].regs[BL_EN]=i ? 0x5f : 0x7f;
        maps[i].regs[BL_BRT_LSB]=0xb7;
        maps[i].regs[BL_BRT_MSB]=100;
    }
}
int main() {
    for (unsigned int i=0;i<1536;i++) assert(uke_normal_bl_remap[i]==mi_bl_level_remap[i]);
    unsigned int previous=0;
    for (unsigned int level=0;level<=MAX_BRIGHTNESS;level++) {
        unsigned int code=ktz8866_uke_code(level);
        assert(code==static_cast<unsigned int>(mi_bl_level_remap[level*1535/2047]));
        assert(code>=previous && code<=1952); previous=code;
    }
    assert(ktz8866_uke_level(0)==0 && ktz8866_uke_level(1953)==-ERANGE);
    i2c_client clients[2]; regmap maps[2];
    ktz8866 secondary{&clients[1],&maps[1],nullptr,{}};
    ktz8866 primary{&clients[0],&maps[0],&secondary,{}};
    backlight_device bl{&primary,{0}};
    for (unsigned int level=0;level<=MAX_BRIGHTNESS;level++) {
        reset(maps); bl.props.brightness=level;
        assert(ktz8866_uke_update_status(&bl)==0);
        const auto effective=level<21 ? 21 : level;
        const auto expected=static_cast<unsigned int>(mi_bl_level_remap[effective*1535/2047]);
        assert(bl.props.brightness==effective);
        for (int i=0;i<2;i++)
            assert((maps[i].regs[BL_BRT_MSB]<<3 | (maps[i].regs[BL_BRT_LSB]&7))==expected);
        const int actual=ktz8866_uke_get_brightness(&bl);
        assert(actual>=0 && ktz8866_uke_code(actual)==expected);
    }
    // The inverse reports the top of an OEM quantization plateau, not a changed code.
    assert(ktz8866_uke_level(ktz8866_uke_code(819))==821);
    for (unsigned int level : {0U,1U,2U,7U,8U,128U,512U,1024U,1535U,2047U}) {
        reset(maps); bl.props.brightness=level;
        regmap original[2]; std::memcpy(original,maps,sizeof(maps));
        assert(ktz8866_uke_update_status(&bl)==0 && !primary.lock.locked && !errors);
        const auto effective=level<21 ? 21 : level;
        assert(bl.props.brightness==effective);
        const int complete=operations;
        for (int i=0;i<2;i++) {
            assert((maps[i].regs[BL_EN]&~BL_EN_BIT)==(original[i].regs[BL_EN]&~BL_EN_BIT));
            assert((maps[i].regs[BL_BRT_LSB]&~7)==(original[i].regs[BL_BRT_LSB]&~7));
            assert((maps[i].regs[BL_EN]&BL_EN_BIT)==BL_EN_BIT);
            assert((maps[i].regs[BL_BRT_MSB]<<3 | (maps[i].regs[BL_BRT_LSB]&7))==ktz8866_uke_code(effective));
            for (unsigned int r=0;r<22;r++)
                if (r!=BL_EN && r!=BL_BRT_LSB && r!=BL_BRT_MSB) assert(maps[i].regs[r]==original[i].regs[r]);
        }
        assert(ktz8866_uke_get_brightness(&bl)>=0);
        for (int fault=0;fault<complete;fault++) {
            reset(maps); failure=fault;
            assert(ktz8866_uke_update_status(&bl)==-EIO && !primary.lock.locked && !errors);
            assert(!std::memcmp(maps,original,sizeof(maps)));
            if (fault<6) assert(writes==0);
        }
        for (int wrong : {9,10,11,15,16,17}) {
            reset(maps); mismatch=wrong;
            assert(ktz8866_uke_update_status(&bl)==-EIO && !errors);
            assert(!std::memcmp(maps,original,sizeof(maps)));
        }
    }
    reset(maps); bl.props.brightness=102; bl.blank=true;
    assert(ktz8866_uke_update_status(&bl)==0 && ktz8866_uke_get_brightness(&bl)==0);
    assert(!(maps[0].regs[BL_EN]&BL_EN_BIT) && !(maps[1].regs[BL_EN]&BL_EN_BIT) && bl.props.brightness==102);
    bl.blank=false;
    assert(ktz8866_uke_update_status(&bl)==0 && ktz8866_uke_get_brightness(&bl)==102);
    reset(maps); bl.props.brightness=2048; assert(ktz8866_uke_update_status(&bl)==-EINVAL && operations==0);
    reset(maps); maps[0].regs[BL_EN]|=BIT(7); bl.props.brightness=100;
    assert(ktz8866_uke_update_status(&bl)==-EBUSY && writes==0);
    reset(maps); maps[1].regs[BL_BRT_MSB]++; assert(ktz8866_uke_get_brightness(&bl)==-EIO);
    reset(maps); maps[1].regs[BL_EN]&=~BL_EN_BIT; assert(ktz8866_uke_get_brightness(&bl)==-EIO);
    reset(maps); failure=13; persistent_failure=true;
    assert(ktz8866_uke_update_status(&bl)==-EIO && errors==1 && !primary.lock.locked);
    reset(maps); failure=13; second_failure=14;
    assert(ktz8866_uke_update_status(&bl)==-EIO && errors==1 && !primary.lock.locked);
    auto setup_probe=[&]() {
        if(cleanup_action) { cleanup_action(cleanup_data); cleanup_action=nullptr; }
        reset(maps); candidate=&clients[1]; clients[0].data=&primary; clients[1].data=&secondary;
        clients[1].dev.bound=true; clients[1].addr=0x11; secondary.secondary=true;
        maps[0].regs[DEVICE_ID]=maps[1].regs[DEVICE_ID]=0x23;
        absent_node=action_failure=link_failure=registration_failure=false;
        assert(clients[1].dev.refs==1 && !clients[1].dev.locked);
    };
    setup_probe(); assert(ktz8866_uke_probe(&primary)==0 && writes==0);
    assert(registered_properties.type==BACKLIGHT_RAW &&
           registered_properties.max_brightness==MAX_BRIGHTNESS &&
           registered_properties.scale==BACKLIGHT_SCALE_NON_LINEAR);
    const int probe_reads=operations;
    for(int fault=0;fault<probe_reads;fault++) {
        setup_probe(); failure=fault;
        assert(ktz8866_uke_probe(&primary)==-EIO && writes==0 && !clients[1].dev.locked);
    }
    setup_probe(); absent_node=true; assert(ktz8866_uke_probe(&primary)==-EINVAL && writes==0);
    setup_probe(); candidate=nullptr; assert(ktz8866_uke_probe(&primary)==-EPROBE_DEFER && writes==0);
    setup_probe(); candidate=&clients[0]; assert(ktz8866_uke_probe(&primary)==-EINVAL && !clients[0].dev.locked);
    setup_probe(); clients[1].dev.bound=false; assert(ktz8866_uke_probe(&primary)==-EPROBE_DEFER && writes==0);
    setup_probe(); secondary.secondary=false; assert(ktz8866_uke_probe(&primary)==-EINVAL && writes==0);
    setup_probe(); clients[1].addr=0x12; assert(ktz8866_uke_probe(&primary)==-EINVAL && writes==0);
    setup_probe(); action_failure=true; assert(ktz8866_uke_probe(&primary)==-ENOMEM && writes==0);
    setup_probe(); link_failure=true; assert(ktz8866_uke_probe(&primary)==-ENOMEM && writes==0);
    setup_probe(); registration_failure=true; assert(ktz8866_uke_probe(&primary)==-ENOMEM && writes==0);
    setup_probe(); maps[0].regs[DEVICE_ID]=0x10; assert(ktz8866_uke_probe(&primary)==-ENODEV && writes==0);
    setup_probe(); maps[1].regs[BL_CFG1]^=8; assert(ktz8866_uke_probe(&primary)==-EINVAL && writes==0);
    setup_probe(); maps[0].regs[BL_BRT_MSB]=maps[1].regs[BL_BRT_MSB]=255;
    assert(ktz8866_uke_probe(&primary)==-ERANGE && writes==0);
    setup_probe(); assert(ktz8866_uke_probe(&secondary)==0 && operations==1 && writes==0);
    setup_probe();
}
CPP
} > "$work/check.cpp"
g++ -std=c++20 -O2 -Wall -Wextra -Werror "$work/check.cpp" -o "$work/check"
"$work/check"
printf 'Exact OEM normal mapping, all 2048 paired levels, non-linear API and I/O/readback/rollback faults: passed\n'
