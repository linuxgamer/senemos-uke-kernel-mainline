#!/usr/bin/env bash
# Actual proposed hwmon conversions, ADC cache, alarms and threshold boundaries.
set -Eeuo pipefail
source=${1:?Pass the prepared qcom-bcl-hwmon.c}
mode=${2:-all}
case $mode in all|conversion|sentinel) ;; *) exit 2;; esac
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
ulimit -c 0
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <limits.h>
typedef uint8_t u8; typedef uint16_t u16; typedef uint32_t u32;
typedef uint64_t u64; typedef int32_t s32; typedef int64_t s64;
struct device { int unused; }; struct mutex { int unused; };
struct delayed_work { int unused; }; struct regmap { int unused; };
struct reg_field { unsigned int reg,lsb,msb; };
struct regmap_field { unsigned int id,value; };
#define REG_FIELD(r,l,h) { .reg=(r),.lsb=(l),.msb=(h) }
#define GENMASK(h,l) ((UINT32_MAX>>(31-(h)))&~((1U<<(l))-1))
#define FIELD_PREP(m,v) (((v)<<__builtin_ctz(m))&(m))
#define ARRAY_SIZE(a) (sizeof(a)/sizeof((a)[0]))
#define BIT(n) (1UL<<(n))
#define HZ 1000UL
static unsigned long jiffies=2000;
#define time_before(a,b) ((long)((a)-(b))<0)
#define clamp_val(v,l,h) ((v)<(long)(l)?(long)(l):(v)>(long)(h)?(long)(h):(v))
static s64 rounded(s64 a,s64 b) { assert(b>0);return a>=0?(a+b/2)/b:(a-b/2)/b; }
#define DIV_S64_ROUND_CLOSEST(a,b) rounded((a),(b))
#define DIV_ROUND_CLOSEST_ULL(a,b) (((a)+(b)/2)/(b))
static s32 sign_extend32(u32 value,unsigned int index) { assert(index==7||index==15);return (s32)(value<<(31-index))>>(31-index); }
static unsigned int writes,reads,bulk_reads,errors,warnings;
static int bad_field=-1,bulk_error;
static u8 bytes[2];
#define dev_err(d,...) ((void)(d),errors++)
#define WARN_ON(v) ((v)?(warnings++,true):false)
static int regmap_field_read(struct regmap_field *field,u32 *out) { reads++;if((int)field->id==bad_field)return -EIO;*out=field->value;return 0; }
static int regmap_field_write(struct regmap_field *field,u32 value) { writes++;if((int)field->id==bad_field)return -EIO;field->value=value;return 0; }
static int regmap_bulk_read(struct regmap *map,unsigned int reg,void *out,size_t n) { assert(map&&(reg==0x4776||reg==0x4786)&&n==2);bulk_reads++;if(bulk_error)return bulk_error;memcpy(out,bytes,n);return 0; }
C
awk '/^#include/{next} /^static const u8 in_attr_to_lvl_map/{exit} {print}' "$source" >> "$work/check.c"
awk '/^static const struct reg_field bcl_pm7250b_reg_fields/{p=1} p && /^\/\*\*/{exit} p{print}' "$source" >> "$work/check.c"
awk '/^static int bcl_convert_raw_to_milliunit/{p=1} /^static unsigned int bcl_get_version_major/{p=0} p{print}' "$source" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
static struct device device;
static struct regmap map;
static struct regmap_field fields[F_MAX_FIELDS];
static struct bcl_device make_device(const struct bcl_desc *desc) {
    struct bcl_device d={.dev=&device,.regmap=&map,.base=0x4700,.desc=desc};
    for(unsigned int i=0;i<F_MAX_FIELDS;i++){fields[i]=(struct regmap_field){.id=i};d.fields[i]=&fields[i];}
    reads=writes=bulk_reads=errors=warnings=0;bad_field=-1;bulk_error=0;jiffies=2000;
    return d;
}
static void conversions(void) {
    const struct bcl_desc *all[]={&pm7250b_data,&pm7550ba_data,&pm8350c_data,&pm8550_data,&pmh0101_data,&pmih0108_data,&smb2360_data,&smb2370_data};
    for(unsigned int i=0;i<ARRAY_SIZE(all);i++) {
        assert(all[i]->num_reg_fields<=F_MAX_FIELDS);
        if(all[i]->in_input_enabled||all[i]->curr_mon_enabled)assert(all[i]->data_field_bits_size==8||all[i]->data_field_bits_size==16);
        for(unsigned int j=0;j<all[i]->num_reg_fields;j++)assert(all[i]->reg_fields[j].msb>=all[i]->reg_fields[j].lsb&&all[i]->reg_fields[j].msb<8);
    }
    struct bcl_device d=make_device(&pm7550ba_data);
    assert(bcl_convert_raw_to_milliunit(&d,86,CHANNEL_IN,8)==4285);
    assert(bcl_convert_raw_to_milliunit(&d,-1,CHANNEL_CURR,8)==-94);
    assert(bcl_convert_raw_to_milliunit(&d,127,CHANNEL_CURR,8)==11907);
    assert(bcl_convert_milliunit_to_raw(&d,3600,CHANNEL_IN,8)==72);
    assert(bcl_convert_milliunit_to_index(&d,2750,CHANNEL_IN)==20);
    assert(bcl_convert_index_to_milliunit(&d,20,CHANNEL_IN)==2750);
    assert(!bcl_in_thresh_write(&d,LONG_MIN,BCL_LIMIT_ALARM_LVL1)&&fields[F_IN_L1_THR].value==0);
    assert(!bcl_in_thresh_write(&d,LONG_MAX,BCL_LIMIT_ALARM_LVL1)&&fields[F_IN_L1_THR].value==54);
    assert(!bcl_curr_thresh_write(&d,LONG_MIN,BCL_LIMIT_ALARM_LVL0)&&fields[F_CURR_H0_THR].value==0);
    assert(!bcl_curr_thresh_write(&d,LONG_MAX,BCL_LIMIT_ALARM_LVL0)&&fields[F_CURR_H0_THR].value==127);
    long out=123;
    assert(!bcl_in_thresh_read(&d,BCL_LIMIT_ALARM_LVL1,&out)&&out==3600);
    assert(!bcl_curr_thresh_read(&d,BCL_LIMIT_ALARM_LVL0,&out)&&out==11907);
    bad_field=F_IN_L1_THR;out=123;
    assert(bcl_in_thresh_write(&d,2600,BCL_LIMIT_ALARM_LVL1)==-EIO);
    assert(bcl_in_thresh_read(&d,BCL_LIMIT_ALARM_LVL1,&out)==-EIO&&out==123);
    bad_field=F_CURR_H0_THR;
    assert(bcl_curr_thresh_write(&d,1000,BCL_LIMIT_ALARM_LVL0)==-EIO);
    assert(bcl_curr_thresh_read(&d,BCL_LIMIT_ALARM_LVL0,&out)==-EIO&&out==123);
    struct reg_field narrow={.msb=1,.lsb=0};unsigned int before=writes;
    assert(bcl_validate_threshold_fits(&d,&narrow,4,1000,"mA")==-EINVAL&&writes==before);
    narrow.msb=0;narrow.lsb=1;
    assert(bcl_validate_threshold_fits(&d,&narrow,0,0,"mA")==-EINVAL&&warnings==1&&writes==before);
    d=make_device(&pm7550ba_data);fields[F_IN_INPUT].value=86;
    assert(!bcl_in_input_read(&d,&out)&&out==4285&&reads==1);
    fields[F_IN_INPUT].value=80;jiffies++;
    assert(!bcl_in_input_read(&d,&out)&&out==4285&&reads==1);
    jiffies+=HZ;bad_field=F_IN_INPUT;out=321;
    assert(bcl_in_input_read(&d,&out)==-EIO&&out==321&&d.last_in_updated==2000);
    bad_field=-1;assert(!bcl_in_input_read(&d,&out)&&out==3986);
    fields[F_CURR_INPUT].value=0xff;
    assert(!bcl_curr_input_read(&d,&out)&&out==-94);
    jiffies+=HZ;bad_field=F_CURR_INPUT;out=321;
    assert(bcl_curr_input_read(&d,&out)==-EIO&&out==321);
    bad_field=-1;fields[F_LVL2_ALARM].value=1;
    assert(!bcl_read_alarm_status(&d,BCL_LIMIT_ALARM_LVL2,&out)&&out==1);
    bad_field=F_LVL2_ALARM;out=321;assert(bcl_read_alarm_status(&d,BCL_LIMIT_ALARM_LVL2,&out)==-EIO&&out==321);
    d=make_device(&smb2370_data);d.batt_config=BCL_BATT_2S;bytes[0]=0xff;bytes[1]=0xff;
    assert(!bcl_curr_input_read(&d,&out)&&out==-1&&bulk_reads==1&&!reads);
    jiffies+=HZ;bulk_error=-EIO;out=321;
    assert(bcl_curr_input_read(&d,&out)==-EIO&&out==321&&bulk_reads==2);
    assert(!writes);
}
static int sentinel(void) {
    struct bcl_device d=make_device(&pm7550ba_data);fields[F_IN_INPUT].value=0x7f;
    long out=321;int ret=bcl_in_input_read(&d,&out);
    if(ret!=-ENODATA||out!=321||d.last_in_updated) {fprintf(stderr,"8-bit unavailable sample: ret=%d out=%ld cache_stamp=%lu\n",ret,out,d.last_in_updated);return 1;}
    d=make_device(&smb2370_data);d.batt_config=BCL_BATT_2S;bytes[0]=0xff;bytes[1]=0x7f;
    ret=bcl_in_input_read(&d,&out);
    if(ret!=-ENODATA||out!=321||d.last_in_updated) {fprintf(stderr,"16-bit unavailable sample: ret=%d out=%ld cache_stamp=%lu\n",ret,out,d.last_in_updated);return 1;}
    d=make_device(&pm7550ba_data);out=321;
    ret=bcl_curr_input_read(&d,&out);
    if(ret!=-ENODATA||out!=321||d.last_curr_updated) {fprintf(stderr,"PM7550BA empty current sample: ret=%d out=%ld cache_stamp=%lu\n",ret,out,d.last_curr_updated);return 1;}
    fields[F_CURR_INPUT].value=0xfe;
    assert(!bcl_curr_input_read(&d,&out)&&out==-188&&d.last_curr_updated==2000);
    jiffies+=HZ;fields[F_CURR_INPUT].value=0;out=321;
    assert(bcl_curr_input_read(&d,&out)==-ENODATA&&out==321&&d.last_curr_updated==2000&&d.last_curr_input==-188);
    d=make_device(&smb2370_data);d.batt_config=BCL_BATT_2S;bytes[0]=bytes[1]=0;
    assert(!bcl_curr_input_read(&d,&out)&&out==0&&d.last_curr_updated==2000);
    return 0;
}
int main(int argc,char **argv) {
    assert(argc==2);
    if(strcmp(argv[1],"sentinel"))conversions();
    if(strcmp(argv[1],"conversion")&&sentinel())return 1;
    puts("PASS: actual BCL units/signs, threshold bounds/errors, cache, bulk read and unavailable sample contract; host only");
}
C
"${CC:-cc}" -std=gnu11 -O1 -Wall -Wextra -Werror -Wno-unused-parameter \
    -fsanitize=address,undefined -fno-omit-frame-pointer "$work/check.c" -o "$work/check"
"$work/check" "$mode"
