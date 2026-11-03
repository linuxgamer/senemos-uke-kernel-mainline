#!/usr/bin/env bash
# Run the actual upstream IR functions after the Uke supply/label patch.
set -Eeuo pipefail
[[ $# == 1 && -f $1 ]] || exit 2
source=$(realpath "$1")
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
awk '/^struct ir_spi_data \{/ {copy=1} copy {print} copy && /^};/ {exit}' "$source" > "$work/struct.inc"
awk '/^static int ir_spi_(tx|set_tx_carrier|set_duty_cycle|probe)\(/ {copy=1} copy {print} copy && /^}/ {copy=0}' "$source" > "$work/functions.inc"
cat > "$work/test.c" <<'C'
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef uint8_t u8;typedef uint16_t u16;typedef uint32_t u32;typedef uint64_t u64;
#define GFP_KERNEL 0
#define RC_DRIVER_IR_RAW_TX 1
#define IR_SPI_DRIVER_NAME "ir-spi"
#define IR_SPI_DEFAULT_FREQUENCY 38000
#define IR_SPI_BITS_PER_PULSE 16
#define EPROBE_DEFER 517
#define GENMASK(h,l) (((1UL<<((h)+1))-1)&~((1UL<<(l))-1))
#define DIV_ROUND_CLOSEST_ULL(n,d) (((n)+(d)/2)/(d))
#define IS_ERR(p) ((uintptr_t)(p)>=(uintptr_t)-4095)
#define PTR_ERR(p) ((intptr_t)(p))
#define dev_err(...) ((void)0)
struct device { bool low;const char *label; };
struct spi_device { struct device dev;u32 max_speed_hz; };
struct regulator { int unused; };
struct spi_transfer { u32 speed_hz;unsigned int len;const void *tx_buf; };
struct rc_dev {
 int (*tx_ir)(struct rc_dev*,unsigned int*,unsigned int);
 int (*s_tx_carrier)(struct rc_dev*,u32);
 int (*s_tx_duty_cycle)(struct rc_dev*,u32);
 const char *device_name,*driver_name;void *priv;
};
#include "struct.inc"
static struct regulator supply;
static struct rc_dev *registered;
static void *allocations[16];static unsigned int allocated;
static int supply_error,enable_error,spi_error,register_error;
static unsigned int enable_calls,disable_calls,spi_calls;
static bool allocation_error,rc_error;
static void *allocate(size_t bytes){
 if(allocation_error)return NULL;
 assert(allocated<16);
 void *p=calloc(1,bytes);assert(p);allocations[allocated++]=p;return p;
}
static void *devm_kzalloc(struct device *d,size_t n,int flags){(void)d;(void)flags;return allocate(n);}
static void *kmalloc_array(size_t n,size_t size,int flags){(void)flags;return calloc(n,size);}
static void kfree(void *p){free(p);}
static struct regulator *devm_regulator_get_optional(struct device *d,const char *name){
 (void)d;assert(!strcmp(name,"power"));return supply_error?(void*)(intptr_t)supply_error:&supply;
}
static int dev_err_probe(struct device *d,int error,const char *message){(void)d;(void)message;return error;}
static struct rc_dev *devm_rc_allocate_device(struct device *d,int type){
 (void)d;assert(type==RC_DRIVER_IR_RAW_TX);return rc_error?NULL:allocate(sizeof(struct rc_dev));
}
static int devm_rc_register_device(struct device *d,struct rc_dev *rc){(void)d;registered=rc;return register_error;}
static bool device_property_read_bool(struct device *d,const char *name){assert(!strcmp(name,"led-active-low"));return d->low;}
static int device_property_read_u8(struct device *d,const char *name,u8 *v){(void)d;(void)v;assert(!strcmp(name,"duty-cycle"));return -EINVAL;}
static int device_property_read_string(struct device *d,const char *name,const char **v){assert(!strcmp(name,"label"));*v=d->label;return *v?0:-EINVAL;}
static int regulator_enable(struct regulator *r){assert(r==&supply);enable_calls++;return enable_error;}
static int regulator_disable(struct regulator *r){assert(r==&supply);disable_calls++;return 0;}
static int spi_sync_transfer(struct spi_device *s,struct spi_transfer *x,unsigned int n){
 assert(s&&n==1&&x->tx_buf&&x->speed_hz==38000*16&&x->len==24);spi_calls++;return spi_error;
}
#include "functions.inc"
static void reset(void){
 for(unsigned int i=0;i<allocated;i++)free(allocations[i]);
 allocated=0;
 supply_error=enable_error=spi_error=register_error=0;
 enable_calls=disable_calls=spi_calls=0;allocation_error=rc_error=false;registered=NULL;
}
int main(void){
 struct spi_device spi={.dev={.label="Uke infrared transmitter"},.max_speed_hz=19200000};
 reset();supply_error=-ENODEV;assert(!ir_spi_probe(&spi));assert(registered&&!spi_calls);
 assert(!strcmp(registered->device_name,"Uke infrared transmitter"));
 unsigned int pulses[]={100,100,100};assert(ir_spi_tx(registered,pulses,3)==3);
 assert(spi_calls==1&&!enable_calls&&!disable_calls);
 assert(ir_spi_set_tx_carrier(registered,0)==-EINVAL);
 assert(ir_spi_set_tx_carrier(registered,1200001)==-EINVAL);
 assert(!ir_spi_set_tx_carrier(registered,38000));
 reset();assert(!ir_spi_probe(&spi));unsigned int powered[]={100,100,100};
 assert(ir_spi_tx(registered,powered,3)==3&&enable_calls==1&&disable_calls==1&&spi_calls==1);
 spi_error=-EIO;unsigned int broken[]={100,100,100};
 assert(ir_spi_tx(registered,broken,3)==-EIO&&enable_calls==2&&disable_calls==2);
 enable_error=-EREMOTEIO;unsigned int unpowered[]={100,100,100};
 assert(ir_spi_tx(registered,unpowered,3)==-EREMOTEIO&&spi_calls==2&&disable_calls==2);
 reset();supply_error=-EPROBE_DEFER;assert(ir_spi_probe(&spi)==-EPROBE_DEFER&&!registered&&!spi_calls);
 reset();supply_error=-EINVAL;assert(ir_spi_probe(&spi)==-EINVAL&&!registered);
 reset();allocation_error=true;assert(ir_spi_probe(&spi)==-ENOMEM);
 reset();rc_error=true;assert(ir_spi_probe(&spi)==-ENOMEM);
 reset();register_error=-EIO;assert(ir_spi_probe(&spi)==-EIO);
 reset();spi.dev.label=NULL;assert(!ir_spi_probe(&spi));assert(!strcmp(registered->device_name,"IR SPI"));
 reset();puts("Actual IR SPI: optional/failed supply, 38 kHz encoding, bounded carrier, cleanup, labels and allocation errors passed; no optical test.");
}
C
${CC:-cc} ${CFLAGS:-} -std=gnu11 -O2 -Wall -Wextra -Werror -Wno-sign-compare -I "$work" "$work/test.c" -o "$work/test"
"$work/test"
