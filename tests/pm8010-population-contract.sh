#!/usr/bin/env bash
# Native-only: exercise the actual optional-device gate, without any bus access.
set -Eeuo pipefail
kernel=${1:?Pass the prepared kernel}
header=$kernel/drivers/mfd/uke-pm8010.h
owner=$(cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cmp "$owner/src/power/uke-pm8010.h" "$header"
grep -Fq 'ret = uke_pm8010_should_probe(sdev);' "$kernel/drivers/mfd/qcom-spmi-pmic.c"
awk '/ret = uke_pm8010_should_probe\(sdev\);/ {gate=NR} /regmap = devm_regmap_init_spmi_ext/ {if (!gate || gate>=NR) exit 1; found=1} END {if (!found) exit 1}' "$kernel/drivers/mfd/qcom-spmi-pmic.c"
cat > "$work/test.c" <<'C'
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
typedef uint8_t u8;
typedef uint32_t u32;
typedef uint32_t __le32;
#define SMEM_SOCINFO_BUILD_ID_LENGTH 32
#define SMEM_SOCINFO_CHIP_ID_LENGTH 32
#define SOCINFO_MAJOR(v) (((v)>>16)&0xffff)
#define SOCINFO_MINOR(v) ((v)&0xffff)
#define QCOM_SMEM_HOST_ANY -1
#define SMEM_HW_SW_BUILD_ID 137
#define EPROBE_DEFER 517
#define IS_ENABLED(x) TEST_ACTIVE
#define IS_REACHABLE(x) TEST_ACTIVE
#define IS_ERR(p) ((uintptr_t)(p)>=(uintptr_t)-4095)
#define PTR_ERR(p) ((int)(intptr_t)(p))
static uint32_t get_unaligned_le32(const void *p) {
    const uint8_t *b=p;
    return (uint32_t)b[0]|((uint32_t)b[1]<<8)|((uint32_t)b[2]<<16)|((uint32_t)b[3]<<24);
}
C
awk '/^struct socinfo \{/ {copy=1} copy {print} copy && /^};/ {exit}' \
    "$kernel/include/linux/soc/qcom/socinfo.h" >> "$work/test.c"
cat >> "$work/test.c" <<'C'
struct device_node { int identity; } target,foreign;
struct device { struct device_node *of_node; };
struct spmi_device { struct device dev; unsigned usid; };
static bool uke=true,node_exists=true;
static unsigned reads,queries,messages,gets,node_puts;
static int smem_error,db_error,resource_present=-1;
static unsigned char table[1024];
static size_t table_size;
static bool of_machine_is_compatible(const char *s) {
    assert(!strcmp(s,"xiaomi,uke"));return uke;
}
static struct device_node *of_find_node_by_path(const char *s) {
    assert(!strcmp(s,"/soc/qcom,spmi@c42d000/qcom,pm8010@d"));
    if(!node_exists)return NULL;
    ++gets;return &target;
}
static void of_node_put(struct device_node *p) { if(p){assert(p==&target);++node_puts;} }
static void *qcom_smem_get(int host,unsigned item,size_t *size) {
    assert(host==QCOM_SMEM_HOST_ANY && item==137);++reads;
    *size=table_size;return smem_error?(void *)(intptr_t)smem_error:table;
}
static int cmd_db_ready(void) { return db_error; }
static u32 cmd_db_read_addr(const char *s) {
    assert(!strncmp(s,"ldon",4) && strlen(s)==5 && s[4]>='1' && s[4]<='7');
    ++queries;return s[4]-'1'==resource_present?0x40000:0;
}
#define dev_info(d,...) do { (void)(d);++messages; } while(0)
C
sed '/^#include /d' "$header" >> "$work/test.c"
cat >> "$work/test.c" <<'C'
static void set32(size_t offset,u32 value) {
    assert(offset+4<=sizeof(table));
    for(unsigned i=0;i<4;++i)table[offset+i]=(u8)(value>>(i*8));
}
static void reset(void) {
    memset(table,0,sizeof(table));
    set32(offsetof(struct socinfo,fmt),19);
    set32(offsetof(struct socinfo,num_pmics),7);
    set32(offsetof(struct socinfo,pmic_array_offset),sizeof(struct socinfo));
    const unsigned models[]={74,80,69,70,51,76,67};
    for(unsigned i=0;i<7;++i)set32(sizeof(struct socinfo)+i*8,models[i]);
    table_size=sizeof(struct socinfo)+7*8;
    uke=true;node_exists=true;smem_error=0;db_error=0;resource_present=-1;
    reads=queries=messages=gets=node_puts=0;
}
int main(void) {
    struct spmi_device dev={{&target},13};
    reset();
#if TEST_ACTIVE
    assert(!uke_pm8010_should_probe(&dev) && reads==1 && queries==7 && messages==1 && gets==node_puts);
    reset();uke=false;assert(uke_pm8010_should_probe(&dev)==1 && !reads);
    reset();dev.usid=7;assert(uke_pm8010_should_probe(&dev)==1 && !reads);dev.usid=13;
    reset();node_exists=false;assert(uke_pm8010_should_probe(&dev)==1 && !reads);
    reset();dev.dev.of_node=&foreign;assert(uke_pm8010_should_probe(&dev)==1 && !reads && gets==node_puts);dev.dev.of_node=&target;
    for(unsigned i=0;i<7;++i){
        reset();set32(sizeof(struct socinfo)+i*8,65);
        assert(uke_pm8010_should_probe(&dev)==1 && !queries && !messages && gets==node_puts);
        reset();resource_present=(int)i;
        assert(uke_pm8010_should_probe(&dev)==1 && queries==i+1 && !messages);
    }
    reset();smem_error=-EPROBE_DEFER;assert(uke_pm8010_should_probe(&dev)==-EPROBE_DEFER && !queries);
    reset();db_error=-EPROBE_DEFER;assert(uke_pm8010_should_probe(&dev)==-EPROBE_DEFER && !queries);
    reset();table_size--;assert(uke_pm8010_should_probe(&dev)==-EINVAL && !queries && !messages);
    /* A positive entry cannot hide an incomplete later inventory entry. */
    reset();set32(sizeof(struct socinfo),65);set32(sizeof(struct socinfo)+6*8,0);
    assert(uke_pm8010_should_probe(&dev)==-ENODATA && !queries && !messages);
    reset();table_size=offsetof(struct socinfo,pmic_array_offset)+3;assert(uke_pm8010_should_probe(&dev)==-EINVAL);
    const u32 invalid_counts[]={0,65,UINT32_MAX};
    for(unsigned i=0;i<3;++i){reset();set32(offsetof(struct socinfo,num_pmics),invalid_counts[i]);assert(uke_pm8010_should_probe(&dev)==-EINVAL);}
    const u32 invalid_offsets[]={0,1,sizeof(struct socinfo)+1,UINT32_MAX-3};
    for(unsigned i=0;i<4;++i){reset();set32(offsetof(struct socinfo,pmic_array_offset),invalid_offsets[i]);assert(uke_pm8010_should_probe(&dev)==-EINVAL);}
    const u32 invalid_formats[]={0,10,0x1000b};
    for(unsigned i=0;i<3;++i){reset();set32(offsetof(struct socinfo,fmt),invalid_formats[i]);assert(uke_pm8010_should_probe(&dev)==-EINVAL);}
    reset();set32(sizeof(struct socinfo)+6*8,0);assert(uke_pm8010_should_probe(&dev)==-ENODATA);
    assert(uke_pm8010_inventory(NULL,1024)==-EINVAL);
    puts("Actual Uke PM8010 population gate: absent, all populated/resource alternatives, foreign nodes, deferred and malformed firmware paths pass; no transport or power access");
#else
    assert(uke_pm8010_should_probe(&dev)==1 && !reads && !queries);
    puts("Disabled Uke profile preserves ordinary PMIC probing");
#endif
    return 0;
}
C
for active in 1 0; do
    "${CC:-cc}" -std=c11 -O2 -g -Wall -Wextra -Werror -Wno-unused-parameter \
        -Wno-unused-function -fsanitize=address,undefined -fno-omit-frame-pointer \
        -DTEST_ACTIVE="$active" "$work/test.c" -o "$work/test-$active"
    ASAN_OPTIONS=detect_leaks=1 "$work/test-$active"
done
