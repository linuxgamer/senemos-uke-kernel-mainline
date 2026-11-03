#!/usr/bin/env bash
# Actual controller probe and port parser, fault injection in host memory only.
set -euo pipefail
kernel=${1:?Pass prepared kernel tree}
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#define EPROBE_DEFER 517
#define GFP_KERNEL 0
#define IS_REACHABLE(x) 0
#define IS_ERR(p) ((uintptr_t)(p) >= (uintptr_t)-4095)
#define PTR_ERR(p) ((int)(intptr_t)(p))
#define FIELD_GET(mask, val) (((unsigned)(val) & (mask)) >> __builtin_ctz(mask))
#define BIT(n) (1U << (n))
#define SWRM_COMP_PARAMS 0x100
#define SWRM_COMP_PARAMS_DOUT_PORTS_MASK 31U
#define SWRM_COMP_PARAMS_DIN_PORTS_MASK (31U << 5)
#define SWRM_MCP_STATUS 0x104
#define SWRM_COMP_HW_VERSION 0x108
#define SWRM_COMP_MASTER_ID 0x10c
#define SWRM_REG_INTERRUPT_STATUS 0
#define SWRM_MCP_STATUS_BANK_NUM_MASK 1
#define SWRM_VERSION_1_3_0 0x01030000U
#define SWR_INVALID_PARAM 0xff
#define DEFAULT_CLK_FREQ 9600000
#define MAX_FREQ_NUM 1
#define IRQF_TRIGGER_RISING 1
#define IRQF_ONESHOT 2
#define IRQF_TRIGGER_HIGH 4
typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
struct device_node {int unused;};
struct device {struct device_node *of_node;struct device *parent;void *bus,*fwnode,*data;};
struct platform_device {struct device dev;};
struct sdw_bus_params {unsigned max_dr_freq,curr_dr_freq,col,row,curr_bank,next_bank;};
struct sdw_master_prop {unsigned mclk_freq,max_clk_freq,num_clk_gears,num_clk_freq,default_col,default_row;const int *clk_freq;};
struct sdw_bus {const int *ops,*port_ops,*compute_params;int clk_stop_timeout,controller_id;struct sdw_bus_params params;struct sdw_master_prop prop;};
struct qcom_swrm_data {int max_reg;const int *reg_layout;unsigned default_rows,default_cols;bool sw_clk_gate_required;};
struct qcom_swrm_port_config {u8 off1,off2,bp_mode,hstart,hstop,word_length,blk_group_count,lane_control;u16 si;};
struct qcom_swrm_ctrl {
 struct device *dev;void *mmio,*audio_cgcr,*hclk,*regmap;
 const int *reg_layout;int max_reg,rows_index,cols_index,irq,wake_irq;
 int port_lock,broadcast,enumeration;u32 version;
 int num_dout_ports,num_din_ports,nports;unsigned long port_mask;
 struct qcom_swrm_port_config *pconfig;
 struct sdw_bus bus;
 int (*reg_read)(struct qcom_swrm_ctrl *,int,void *);
 int (*reg_write)(struct qcom_swrm_ctrl *,int,int);
};
static struct qcom_swrm_ctrl storage;
static struct qcom_swrm_port_config ports[8];
static const int qcom_swrm_ops,qcom_swrm_port_ops,qcom_swrm_compute_params,qcom_swrm_freq_tbl[1];
static const int qcom_swrm_irq_handler,qcom_swrm_wake_irq_handler;
static const struct qcom_swrm_data match={.default_rows=48,.default_cols=16};
static int clock_error,read_error,read_address,wake_irq_error,wake_request_error;
static int bus_error,dai_error,clock_on,clock_off,reads,property_reads,init_calls,adds,deletes,pm_calls,irq_active;
static bool allocation_fails;
static void *devm_kzalloc(struct device *d,size_t n,int f)
{(void)d;(void)f;assert(n==sizeof(storage));return allocation_fails?NULL:&storage;}
static const struct qcom_swrm_data *of_device_get_match_data(struct device *d){(void)d;return &match;}
static int sdw_find_row_index(unsigned n){return (int)n;}
static int sdw_find_col_index(unsigned n){return (int)n;}
static int qcom_swrm_cpu_reg_read(struct qcom_swrm_ctrl *c,int address,void *out)
{(void)c;reads++;assert(clock_on-clock_off==1);if(address==read_address && read_error)return read_error;
 *(u32 *)out=address==SWRM_COMP_PARAMS?(2U|(2U<<5)):address==SWRM_COMP_HW_VERSION?0x01070000:0;return 0;}
static int qcom_swrm_cpu_reg_write(struct qcom_swrm_ctrl *c,int a,int v){(void)c;(void)a;(void)v;return 0;}
#define qcom_swrm_ahb_reg_read qcom_swrm_cpu_reg_read
#define qcom_swrm_ahb_reg_write qcom_swrm_cpu_reg_write
static void *dev_get_regmap(struct device *d,void *n){(void)d;(void)n;return &storage;}
static void *devm_platform_ioremap_resource(struct platform_device *p,int n){(void)p;(void)n;return &storage;}
static void *devm_reset_control_get_optional_exclusive(struct device *d,const char *n){(void)d;(void)n;return &storage;}
static int of_irq_get(struct device_node *n,int i){(void)n;return i?(wake_irq_error?wake_irq_error:2):1;}
static void *devm_clk_get(struct device *d,const char *n){(void)d;(void)n;return &storage;}
static int clk_prepare_enable(void *c){(void)c;if(clock_error)return clock_error;clock_on++;return 0;}
static void clk_disable_unprepare(void *c){(void)c;assert(irq_active==0);clock_off++;assert(clock_off<=clock_on);}
#define dev_err(...) ((void)0)
#define dev_dbg(...) ((void)0)
static int dev_err_probe(struct device *d,int e,const char *s){(void)d;(void)s;return e;}
static void dev_set_drvdata(struct device *d,void *p){d->data=p;}
static void mutex_init(int *p){*p=0;}
static void init_completion(int *p){*p=0;}
static int of_property_read_u32(struct device_node *n,const char *s,int *v){(void)n;(void)s;(void)v;property_reads++;return -EINVAL;}
static int of_property_read_u8_index(struct device_node *n,const char *s,int i,u8 *v){(void)n;(void)s;(void)i;property_reads++;*v=0;return 0;}
static int of_property_read_u16_index(struct device_node *n,const char *s,int i,u16 *v){(void)n;(void)s;(void)i;*v=0;return 0;}
static void *devm_kcalloc(struct device *d,size_t n,size_t size,int f){(void)d;(void)f;assert(n<=8 && size==sizeof(ports[0]));return ports;}
static void set_bit(unsigned b,unsigned long *p){*p|=1UL<<b;}
static int devm_request_threaded_irq(struct device *d,int irq,void *primary,int handler,int flags,const char *n,void *c)
{(void)d;(void)primary;(void)handler;(void)flags;(void)n;(void)c;if(irq==2 && wake_request_error)return wake_request_error;irq_active|=BIT(irq);return 0;}
static void devm_free_irq(struct device *d,int irq,void *c)
{(void)d;(void)c;assert((irq_active&BIT(irq)) && clock_on-clock_off==1);irq_active&=~BIT(irq);}
static int sdw_bus_master_add(struct sdw_bus *b,struct device *d,void *f){(void)b;(void)d;(void)f;adds++;return bus_error;}
static void sdw_bus_master_delete(struct sdw_bus *b){(void)b;assert(irq_active==0);deletes++;}
static void qcom_swrm_init(struct qcom_swrm_ctrl *c){(void)c;init_calls++;}
static int qcom_swrm_register_dais(struct qcom_swrm_ctrl *c){(void)c;return dai_error;}
#define msecs_to_jiffies(n) (n)
#define TIMEOUT_MS 100
#define wait_for_completion_timeout(p,n) ((void)(p),(void)(n))
static void pm_runtime_set_autosuspend_delay(struct device *d,int delay){(void)d;assert(delay==3000);pm_calls++;}
#define PM_STUB(name) static void name(struct device *d){(void)d;pm_calls++;}
PM_STUB(pm_runtime_use_autosuspend)
PM_STUB(pm_runtime_mark_last_busy)
PM_STUB(pm_runtime_set_active)
PM_STUB(pm_runtime_enable)
C
awk '/^static int qcom_swrm_get_port_config\(/ || /^static int qcom_swrm_probe\(/ {emit=1}
 emit {print} emit && /^}/ {emit=0}' "$kernel/drivers/soundwire/qcom.c" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
static void clear(void) {
 memset(&storage,0,sizeof(storage));memset(ports,0,sizeof(ports));
 clock_error=read_error=read_address=wake_irq_error=wake_request_error=0;
 bus_error=dai_error=clock_on=clock_off=reads=property_reads=init_calls=adds=deletes=pm_calls=irq_active=0;allocation_fails=false;
}
int main(void) {
 struct device_node node={0};struct platform_device p={.dev.of_node=&node};
 const int errors[]={-EPROBE_DEFER,-EIO,-ENOMEM};
 for(unsigned i=0;i<sizeof(errors)/sizeof(errors[0]);i++) {
  clear();clock_error=errors[i];assert(qcom_swrm_probe(&p)==errors[i]);
  assert(clock_on==0 && clock_off==0 && reads==0 && adds==0 && init_calls==0 && pm_calls==0);
  const int registers[]={SWRM_COMP_PARAMS,SWRM_MCP_STATUS,SWRM_COMP_HW_VERSION,SWRM_COMP_MASTER_ID};
  for(unsigned r=0;r<sizeof(registers)/sizeof(registers[0]);r++) {
   clear();read_error=errors[i];read_address=registers[r];assert(qcom_swrm_probe(&p)==errors[i]);
   assert(clock_on==1 && clock_off==1 && adds==0 && init_calls==0 && pm_calls==0);
   if(r==0)assert(property_reads==0);
  }
  clear();wake_request_error=errors[i];assert(qcom_swrm_probe(&p)==errors[i]);
  assert(clock_on==1 && clock_off==1 && adds==0 && init_calls==0 && pm_calls==0);
 }
 clear();wake_irq_error=-EPROBE_DEFER;assert(qcom_swrm_probe(&p)==-EPROBE_DEFER);
 assert(clock_on==1 && clock_off==1 && adds==0 && init_calls==0 && pm_calls==0);
 clear();bus_error=-EIO;assert(qcom_swrm_probe(&p)==-EIO);
 assert(clock_on==1 && clock_off==1 && adds==1 && deletes==0 && init_calls==0 && pm_calls==0);
 clear();dai_error=-EIO;assert(qcom_swrm_probe(&p)==-EIO);
 assert(clock_on==1 && clock_off==1 && adds==1 && deletes==1 && init_calls==1 && pm_calls==0);
 clear();allocation_fails=true;assert(qcom_swrm_probe(&p)==-ENOMEM);assert(reads==0 && clock_on==0);
 clear();assert(qcom_swrm_probe(&p)==0);
 assert(clock_on==1 && clock_off==0 && adds==1 && deletes==0 && init_calls==1 && pm_calls==5);
 assert(storage.num_din_ports==2 && storage.num_dout_ports==2 && storage.nports==4);
 clear();wake_irq_error=-ENXIO;assert(qcom_swrm_probe(&p)==0);assert(clock_on==1 && clock_off==0 && pm_calls==5);
 puts("Actual SoundWire probe: failed clock blocks reads; failed identity/port reads and wake supplier errors unwind; host only.");
}
C
${CC:-cc} -std=gnu11 -Wall -Wextra -Werror -fsanitize=address,undefined \
    -fno-omit-frame-pointer "$work/check.c" -o "$work/check"
"$work/check"
