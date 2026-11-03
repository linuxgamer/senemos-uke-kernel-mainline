#!/usr/bin/env bash
# Exercise the actual supplier admission without touching LED hardware.
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
stage=$(mktemp -d)
trap 'rm -rf -- "$stage"' EXIT
cat > "$stage/test.c" <<'C'
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include "uke-torch-uapi.h"
typedef uint32_t u32;
#define LED_DEV_CAP_FLASH 1
struct device_node {struct device_node *parent,*supplier;u32 reg,current,channels[2];int count;bool compatible,flash;};
struct device_driver {const char *name;};
struct device {const char *name;struct device *parent;struct device_driver *driver;struct device_node *of_node;};
struct platform_device {struct device dev;};
struct led_classdev {struct device *dev;unsigned max_brightness,flags;};
static bool read_error;
static unsigned refs;
static const char *dev_name(struct device *d){return d->name;}
static struct device_node *of_parse_phandle(struct device_node *n,const char *name,unsigned index){assert(!strcmp(name,"leds") && !index);if(n->supplier)++refs;return n->supplier;}
static struct device_node *of_get_parent(struct device_node *n){if(n && n->parent){++refs;return n->parent;}return NULL;}
static void of_node_put(struct device_node *n){if(n){assert(refs);--refs;}}
static bool of_device_is_compatible(struct device_node *n,const char *name){assert(!strcmp(name,"qcom,spmi-flash-led"));return n->compatible;}
static int of_property_read_u32(struct device_node *n,const char *name,u32 *value){if(read_error)return -1;if(!strcmp(name,"reg"))*value=n->reg;else{assert(!strcmp(name,"led-max-microamp"));*value=n->current;}return 0;}
static int of_property_count_u32_elems(struct device_node *n,const char *name){assert(!strcmp(name,"led-sources"));return n->count;}
static int of_property_read_u32_array(struct device_node *n,const char *name,u32 *values,unsigned count){assert(!strcmp(name,"led-sources") && count==2);memcpy(values,n->channels,sizeof(n->channels));return read_error?-1:0;}
static bool of_property_present(struct device_node *n,const char *name){assert(!strcmp(name,"flash-max-microamp"));return n->flash;}
C
awk '/^static bool torch_supplier_valid\(/ {copy=1} copy {print} copy && /^}/ {exit}' "$root/src/leds/leds-uke-torch.c" >> "$stage/test.c"
cat >> "$stage/test.c" <<'C'
int main(void){
    struct device_node parent={.reg=0xee00,.compatible=true};
    struct device_node node={.parent=&parent,.current=20000,.channels={1,4},.count=2};
    struct device_node consumer={.supplier=&node};struct platform_device p={.dev={.of_node=&consumer}};
    struct device_driver driver={"leds-qcom-flash"};struct device provider={.driver=&driver};
    struct device dev={.name="uke:white:torch",.parent=&provider};struct led_classdev led={.dev=&dev,.max_brightness=2};
    assert(torch_supplier_valid(&p,&led) && !refs);
    for(unsigned bad=0;bad<13;++bad){
        dev.name="uke:white:torch";led.max_brightness=2;led.flags=0;provider.driver=&driver;driver.name="leds-qcom-flash";
        parent.compatible=true;parent.reg=0xee00;node.current=20000;node.channels[1]=4;node.count=2;node.flash=false;consumer.supplier=&node;read_error=false;
        if(bad==0)dev.name="foreign:torch";
        if(bad==1)led.max_brightness=255;
        if(bad==2)led.flags=LED_DEV_CAP_FLASH;
        if(bad==3)provider.driver=NULL;
        if(bad==4)driver.name="foreign-driver";
        if(bad==5)parent.compatible=false;
        if(bad==6)parent.reg=0xef00;
        if(bad==7)node.current=20001;
        if(bad==8)node.channels[1]=2;
        if(bad==9)node.count=3;
        if(bad==10)node.flash=true;
        if(bad==11)consumer.supplier=NULL;
        if(bad==12)read_error=true;
        assert(!torch_supplier_valid(&p,&led) && !refs);
    }
}
C
${CC:-cc} -std=gnu11 -Wall -Wextra -Werror -fsanitize=undefined -fno-sanitize-recover=all \
    -I "$root/src/leds" "$stage/test.c" -o "$stage/test"
"$stage/test"
printf '%s\n' 'Actual torch supplier admission: exact LED/driver, torch-only scale, current/channel/DT checks and balanced references: PASS (simulated primitives only)'
