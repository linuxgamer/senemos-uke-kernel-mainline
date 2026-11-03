#!/usr/bin/env bash
# Actual QCOM functions with simulated register I/O; never access a device.
set -Eeuo pipefail
source=${1:?Pass the patched leds-qcom-flash.c}
baseline=${2:-}
stage=$(mktemp -d)
trap 'rm -rf -- "$stage"' EXIT
cat > "$stage/prefix.c" <<'C'
#include <assert.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
typedef unsigned u32;
#define BIT(n) (1U << (n))
#define min_t(type,a,b) ((type)(a)<(type)(b)?(type)(a):(type)(b))
#define dev_dbg(...) ((void)0)
enum {QCOM_MVFLASH_3CH,QCOM_MVFLASH_4CH};
enum {REG_THERM_THRSH1,REG_THERM_THRSH2,REG_THERM_THRSH3,REG_STATUS2,REG_MAX_COUNT};
enum {SW_STROBE,TORCH_MODE};
enum led_brightness {LED_OFF=0,LED_FULL=255};
struct mutex {bool locked;};
struct regmap_field {unsigned id;};
struct led_classdev {unsigned max_brightness;};
struct led_classdev_flash {struct led_classdev led_cdev;};
struct qcom_flash_data {
    struct regmap_field *r_fields[REG_MAX_COUNT];
    struct mutex lock;
    unsigned hw_type,revision,total_ma;
};
struct qcom_flash_led {
    struct qcom_flash_data *flash_data;
    struct led_classdev_flash flash;
    unsigned current_in_use_ma,max_torch_current_ma,chan_count;
};
static struct qcom_flash_data data;
static struct qcom_flash_led led;
static struct regmap_field fields[REG_MAX_COUNT];
static unsigned values[REG_MAX_COUNT],reads,writes,programs,programmed;
static int read_errors[32],write_errors[32];
static bool ambiguous_write,module_enabled,strobe_enabled;
static const unsigned saved[]={7,6,5};
static void mutex_lock(struct mutex *m){assert(!m->locked);m->locked=true;}
static void mutex_unlock(struct mutex *m){assert(m->locked);m->locked=false;}
static int regmap_field_read(struct regmap_field *f,unsigned *value){
    assert(data.lock.locked && f->id<REG_MAX_COUNT && ++reads<32);
    if(read_errors[reads])return read_errors[reads];
    *value=values[f->id];return 0;
}
static int regmap_field_write(struct regmap_field *f,unsigned value){
    assert(data.lock.locked && f->id<REG_STATUS2 && ++writes<32);
    if(!write_errors[writes] || ambiguous_write)values[f->id]=value;
    return write_errors[writes];
}
static struct led_classdev_flash *lcdev_to_flcdev(struct led_classdev *p){return (void*)p;}
static struct qcom_flash_led *flcdev_to_qcom_fled(struct led_classdev_flash *p){
    return (void*)((char*)p - offsetof(struct qcom_flash_led,flash));
}
static int set_flash_strobe(struct qcom_flash_led *p,unsigned mode,bool on){
    assert(p==&led && mode==SW_STROBE);strobe_enabled=on;return 0;
}
static int set_flash_module_en(struct qcom_flash_led *p,bool on){assert(p==&led);module_enabled=on;return 0;}
static int set_flash_current(struct qcom_flash_led *p,unsigned value,unsigned mode){
    assert(p==&led && mode==TORCH_MODE);++programs;programmed=value;return 0;
}
static int set_flash_timeout(struct qcom_flash_led *p,unsigned value){assert(p==&led && !value);return 0;}
static void reset(bool three){
    memset(&data,0,sizeof(data));memset(&led,0,sizeof(led));
    memset(read_errors,0,sizeof(read_errors));memset(write_errors,0,sizeof(write_errors));
    for(unsigned i=0;i<REG_MAX_COUNT;++i){fields[i].id=i;data.r_fields[i]=&fields[i];values[i]=i<3?saved[i]:0;}
    data.hw_type=three?QCOM_MVFLASH_3CH:QCOM_MVFLASH_4CH;
    led.flash_data=&data;led.max_torch_current_ma=20;led.chan_count=2;led.flash.led_cdev.max_brightness=2;
    reads=writes=programs=programmed=0;ambiguous_write=false;module_enabled=strobe_enabled=true;
}
C
awk '/^#define[[:space:]]+(FLASH_TOTAL_CURRENT_MAX_UA|FLASH_4CH_REVISION_V0P1|OTST_3CH_MIN_VAL|OTST[12]_4CH(_V0P1)?_MIN_VAL|OTST[123]_MAX_CURRENT_MA|FLASH_STS_[34]CH_OTST[123]|TORCH_IRES_UA|UA_PER_MA)[[:space:]]/ {print}' "$source" >> "$stage/prefix.c"
cat > "$stage/suffix.c" <<'C'
static void restored(unsigned n){for(unsigned i=0;i<n;++i)assert(values[i]==saved[i]);assert(!data.lock.locked);}
int main(int argc,char **argv){
    if(argc==2 && !strcmp(argv[1],"baseline")){
        reset(false);read_errors[3]=-EIO;unsigned current=20;
        assert(update_allowed_flash_current(&led,&current,true)==0);
        reset(false);data.total_ma=2000;
        assert(!qcom_flash_led_brightness_set(&led.flash.led_cdev,1));
        assert(strobe_enabled && module_enabled && programs==1 && programmed==0);
        puts("Baseline actual QCOM functions reproduce lost thermal-read errors and zero-budget enable; simulated I/O only");
        return 0;
    }
    assert(argc==1);
    for(unsigned three=0;three<2;++three){
        const unsigned n=three?3:2;
        reset(three);unsigned current=20;
        assert(!update_allowed_flash_current(&led,&current,true) && current==20);
        assert(reads==n+1 && writes==2*n && data.total_ma==20);restored(n);
        for(unsigned i=1;i<=n+1;++i){
            reset(three);read_errors[i]=-EIO;current=20;
            assert(update_allowed_flash_current(&led,&current,true)==-EIO);
            assert(writes==(i<=n?0:2*n));restored(n);
        }
        for(unsigned i=1;i<=2*n;++i)for(unsigned ambiguous=0;ambiguous<2;++ambiguous){
            reset(three);write_errors[i]=-ENXIO;ambiguous_write=ambiguous;current=20;
            assert(update_allowed_flash_current(&led,&current,true)==-ENXIO);
            assert(writes==(i<=n?i+n:2*n) && !data.lock.locked);
            if(i<=n || ambiguous)restored(n);
            else for(unsigned j=0;j<n;++j)if(j!=i-n-1)assert(values[j]==saved[j]);
        }
        reset(three);read_errors[n+1]=-EIO;write_errors[n+1]=-ENXIO;write_errors[n+2]=-EFAULT;current=20;
        assert(update_allowed_flash_current(&led,&current,true)==-EIO && writes==2*n);
        reset(three);write_errors[n+1]=-ENXIO;write_errors[n+2]=-EFAULT;current=20;
        assert(update_allowed_flash_current(&led,&current,true)==-ENXIO && writes==2*n);
        reset(three);write_errors[1]=-ETIMEDOUT;write_errors[2]=-ENXIO;current=20;
        assert(update_allowed_flash_current(&led,&current,true)==-ETIMEDOUT && writes==n+1);
        // Caller stops output before the actual failing thermal transaction.
        reset(three);read_errors[n+1]=-EIO;
        assert(qcom_flash_led_brightness_set(&led.flash.led_cdev,2)==-EIO);
        assert(!strobe_enabled && !module_enabled && !programs);restored(n);
        for(unsigned available=0;available<10;++available){
            reset(three);data.total_ma=2000-available;
            assert(qcom_flash_led_brightness_set(&led.flash.led_cdev,2)==-EAGAIN);
            assert(!strobe_enabled && !module_enabled && !programs);
        }
        reset(three);data.total_ma=1990;
        assert(!qcom_flash_led_brightness_set(&led.flash.led_cdev,2));
        assert(strobe_enabled && module_enabled && programmed==10 && data.total_ma==2000);
        reset(three);led.current_in_use_ma=20;data.total_ma=30;current=0;
        assert(!update_allowed_flash_current(&led,&current,false) && data.total_ma==10 && !led.current_in_use_ma && !reads && !writes);
        // Keep the existing thermal-level selection and total-current limits.
        const unsigned status[]={FLASH_STS_3CH_OTST1,FLASH_STS_3CH_OTST2,FLASH_STS_3CH_OTST3};
        const unsigned cap[]={OTST1_MAX_CURRENT_MA,OTST2_MAX_CURRENT_MA,OTST3_MAX_CURRENT_MA};
        for(unsigned i=0;i<(three?3U:2U);++i){
            reset(three);values[REG_STATUS2]=three?status[i]:(i?FLASH_STS_4CH_OTST2:FLASH_STS_4CH_OTST1);current=2000;
            assert(!update_allowed_flash_current(&led,&current,true) && current==cap[i]);restored(n);
        }
    }
    reset(false);led.max_torch_current_ma=500;led.flash.led_cdev.max_brightness=255;
    assert(!qcom_flash_led_brightness_set(&led.flash.led_cdev,1));
    assert(programmed==10 && data.total_ma==10 && strobe_enabled);
    reset(false);led.max_torch_current_ma=4;led.flash.led_cdev.max_brightness=255;
    assert(qcom_flash_led_brightness_set(&led.flash.led_cdev,1)==-ERANGE);
    assert(!strobe_enabled && !module_enabled && !programs && !reads && !writes);
    reset(false);assert(!qcom_flash_led_brightness_set(&led.flash.led_cdev,0));
    assert(!strobe_enabled && !module_enabled && !reads && !writes);
    puts("Actual QCOM thermal/current functions: first-error preservation, all restore attempts, ambiguous writes, 3/4-channel paths and minimum-budget refusal passed; simulated I/O only");
}
C
build_test(){
    local input=$1 name=$2
    cat "$stage/prefix.c" > "$stage/$name.c"
    for function in update_allowed_flash_current qcom_flash_led_brightness_set; do
        awk -v name="$function" '$0 ~ "^static int "name"\\(" {copy=1} copy {print} copy && /^}/ {exit}' "$input" >> "$stage/$name.c"
        grep -q "^static int $function(" "$stage/$name.c"
    done
    cat "$stage/suffix.c" >> "$stage/$name.c"
    ${CC:-cc} -std=gnu11 -Wall -Wextra -Werror -Wno-unused-parameter -fsanitize=undefined -fno-sanitize-recover=all "$stage/$name.c" -o "$stage/$name"
}
if [[ -n $baseline ]]; then
    build_test "$baseline" baseline
    "$stage/baseline" baseline
fi
build_test "$source" fixed
"$stage/fixed"
