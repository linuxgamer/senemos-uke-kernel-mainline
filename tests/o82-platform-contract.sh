#!/usr/bin/env bash
# COPR-only tests of actual resource admission functions; fake providers, no MMIO.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'find "$work" -depth -delete' EXIT
sed -n '/^int dpu_o82_platform_init(/,/^}/p; /^int dpu_o82_platform_suspend(/,/^}/p' \
    "$root/src/display/dpu_o82_platform.c" > "$work/functions.h"
cat > "$work/test.c" <<'C'
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define __iomem
#define GFP_KERNEL 0
#define IORESOURCE_MEM 0x200
#define IS_ERR(p) ((uintptr_t)(p)>=(uintptr_t)-4095)
#define PTR_ERR(p) ((intptr_t)(p))
#define READ_ONCE(x) (x)
struct device { void *of_node; };
struct platform_device { struct device dev; };
struct resource { uint64_t start,end; };
struct dpu_o82_regdma { void *regs; bool busy,power_held; struct dpu_kms *kms_owner; };
struct dpu_kms { struct platform_device *pdev; struct dpu_o82_regdma *o82_regdma; };
static struct {
 bool board,soc,node,no_mdp,no_dma,no_memory;
 int map_error,color_error;
 unsigned int lookups,allocations,maps,inits;
 struct resource mdp,dma;
 struct dpu_o82_regdma allocation;
} fixture;
static bool of_machine_is_compatible(const char *name)
{ return !strcmp(name,"xiaomi,uke")?fixture.board:!strcmp(name,"qcom,sm7675")&&fixture.soc; }
static bool of_device_is_compatible(const void *node,const char *name)
{ return node&&fixture.node&&!strcmp(name,"qcom,sm7675-dpu"); }
static struct resource *platform_get_resource_byname(struct platform_device *p,int flags,const char *name)
{
 assert(p&&flags==IORESOURCE_MEM);fixture.lookups++;
 if(!strcmp(name,"mdp"))return fixture.no_mdp?NULL:&fixture.mdp;
 assert(!strcmp(name,"regdma"));return fixture.no_dma?NULL:&fixture.dma;
}
static void *devm_kzalloc(struct device *dev,size_t size,int flags)
{ assert(dev&&size==sizeof(struct dpu_o82_regdma)&&flags==GFP_KERNEL);fixture.allocations++;return fixture.no_memory?NULL:&fixture.allocation; }
static void *devm_ioremap_resource(struct device *dev,struct resource *r)
{ assert(dev&&r==&fixture.dma);fixture.maps++;return fixture.map_error?(void*)(intptr_t)fixture.map_error:(void*)0x12340000; }
static void dpu_o82_regdma_init(struct dpu_o82_regdma *dma,void *regs)
{ assert(dma==&fixture.allocation&&regs==(void*)0x12340000);dma->regs=regs;fixture.inits++; }
static bool dpu_o82_regdma_can_unmap(struct dpu_o82_regdma *dma) { return !dma->busy; }
static int dpu_o82_upload_release(struct dpu_o82_regdma *dma)
{ assert(dma->kms_owner);return dma->busy?-EBUSY:0; }
static int dpu_o82_color_init(struct dpu_kms *kms)
{ assert(kms->o82_regdma&&kms->o82_regdma->kms_owner==kms);return fixture.color_error; }
#include "functions.h"
static void reset(struct dpu_kms *kms)
{
 memset(&fixture,0,sizeof(fixture));kms->o82_regdma=NULL;
 fixture.board=fixture.soc=fixture.node=true;
 fixture.mdp=(struct resource){0xae01000,0xae8ffff};
 fixture.dma=(struct resource){0xaf80000,0xaf86fff};
}
int main(void)
{
 struct platform_device device={.dev={.of_node=&fixture}};
 struct dpu_kms kms={.pdev=&device};
 for(unsigned int i=0;i<3;i++) {
  reset(&kms);
  if(i==0)fixture.board=false;
  if(i==1)fixture.soc=false;
  if(i==2)fixture.node=false;
  assert(!dpu_o82_platform_init(&kms)&&!kms.o82_regdma&&!fixture.lookups&&!fixture.maps);
 }
 for(unsigned int i=0;i<4;i++) {
  reset(&kms);
  if(i==0)fixture.mdp.start++;
  if(i==1)fixture.mdp.end++;
  if(i==2)fixture.dma.start++;
  if(i==3)fixture.dma.end++;
  assert(dpu_o82_platform_init(&kms)==-EINVAL&&!kms.o82_regdma&&!fixture.allocations&&!fixture.maps);
 }
 reset(&kms);fixture.no_mdp=true;assert(dpu_o82_platform_init(&kms)==-ENODEV&&!fixture.maps);
 reset(&kms);fixture.no_dma=true;assert(dpu_o82_platform_init(&kms)==-ENODEV&&!fixture.maps);
 reset(&kms);fixture.no_memory=true;assert(dpu_o82_platform_init(&kms)==-ENOMEM&&!kms.o82_regdma&&!fixture.maps);
 reset(&kms);fixture.map_error=-EBUSY;assert(dpu_o82_platform_init(&kms)==-EBUSY&&!kms.o82_regdma&&!fixture.inits);
 reset(&kms);fixture.color_error=-EBADMSG;assert(dpu_o82_platform_init(&kms)==-EBADMSG&&kms.o82_regdma&&fixture.inits==1);
 reset(&kms);assert(!dpu_o82_platform_init(&kms)&&kms.o82_regdma==&fixture.allocation&&fixture.inits==1);
 assert(fixture.allocation.kms_owner==&kms);
 assert(dpu_o82_platform_init(&kms)==-EALREADY&&fixture.inits==1&&fixture.maps==1);
 assert(!dpu_o82_platform_suspend(&kms));
 fixture.allocation.busy=true;assert(dpu_o82_platform_suspend(&kms)==-EBUSY);
 fixture.allocation.busy=false;assert(!dpu_o82_platform_suspend(&kms));
 fixture.allocation.power_held=true;assert(dpu_o82_platform_suspend(&kms)==-EBUSY);
 fixture.allocation.power_held=false;
 kms.o82_regdma=NULL;assert(!dpu_o82_platform_suspend(&kms));
 puts("Actual O82 platform: exact separate resources, pre-map foreign/range rejection, allocation/map failures, publish-on-success and suspend ownership refusal passed; fake providers only");
}
C
for compiler in gcc clang; do
    "$compiler" -std=gnu11 -O1 -g -Wall -Wextra -Werror \
        -fsanitize=address,undefined -fno-omit-frame-pointer "$work/test.c" -o "$work/test"
    ASAN_OPTIONS=detect_leaks=1 UBSAN_OPTIONS=halt_on_error=1 "$work/test"
done
