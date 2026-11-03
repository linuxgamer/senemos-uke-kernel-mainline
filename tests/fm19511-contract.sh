#!/usr/bin/env bash
# Execute the actual transport/configuration/file functions with host I2C mocks.
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
awk '/^struct fm19511 \{/ {copy=1} copy {print} copy && /^};/ {exit}' \
    "$root/src/nfc/fm19511-uke.c" > "$work/struct.inc"
awk '/^static (int|void|ssize_t|__poll_t) fm19511_(read_reg|write_reg|configure|free|open|release|read|write|poll)\(/ {copy=1} copy {print} copy && /^}/ {copy=0}' \
    "$root/src/nfc/fm19511-uke.c" > "$work/functions.inc"
cat > "$work/test.c" <<'C'
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/types.h>
typedef uint8_t u8;
typedef uint16_t u16;
typedef unsigned int __poll_t;
typedef int wait_queue_head_t;
typedef struct { int value; } atomic_t;
typedef struct { int unused; } poll_table;
#define __user
#define ARRAY_SIZE(a) (sizeof(a)/sizeof((a)[0]))
#define FM19511_LIMIT 256
#define container_of(p,t,m) ((t*)((char*)(p)-offsetof(t,m)))
#define dev_warn(...) ((void)0)
struct i2c_client { int dev; };
struct miscdevice { int unused; };
struct mutex { int locked; };
struct kref { unsigned int count; };
struct delayed_work { int unused; };
struct inode { int unused; };
struct file { void *private_data; };
#include "struct.inc"
static u8 memory[65536];
static unsigned int calls, fail_call, corrupt_call, persistent_writes, freed;
static bool short_io, copy_fault, irq_during_read, oversized_read;
static u16 pointer;
static struct fm19511 *active;
static void mutex_lock(struct mutex *m){assert(!m->locked);m->locked=1;}
static void mutex_unlock(struct mutex *m){assert(m->locked);m->locked=0;}
static void kref_get(struct kref *k){assert(k->count);k->count++;}
static void kref_put(struct kref *k,void (*release)(struct kref*)){assert(k->count);if(!--k->count)release(k);}
static void kfree(void *p){assert(p==active);freed++;}
static int atomic_xchg(atomic_t *a,int v){int old=a->value;a->value=v;return old;}
static void atomic_set(atomic_t *a,int v){a->value=v;}
static int atomic_read(atomic_t *a){return a->value;}
static int nonseekable_open(struct inode *i,struct file *f){(void)i;(void)f;return 0;}
static int copy_to_user(void *dst,const void *src,size_t n){if(copy_fault)return 1;memcpy(dst,src,n);return 0;}
static int copy_from_user(void *dst,const void *src,size_t n){return copy_to_user(dst,src,n);}
static void poll_wait(struct file *f,wait_queue_head_t *w,poll_table *p){(void)f;(void)w;(void)p;}
static int i2c_master_send(struct i2c_client *client,const char *data,int size){
 assert(client);calls++;if(calls==fail_call)return short_io?size-1:-EREMOTEIO;
 if(size>=2)pointer=(u16)(((u8)data[0]<<8)|(u8)data[1]);
 if(size==3){if(pointer<0xff00)persistent_writes++;memory[pointer]=data[2];}
 return size;
}
static int i2c_master_recv(struct i2c_client *client,char *data,int size){
 assert(client);calls++;if(calls==fail_call)return short_io?0:-EREMOTEIO;
 for(int i=0;i<size;i++)data[i]=memory[(u16)(pointer+i)];
 if(calls==corrupt_call&&size)data[0]^=1;
 if(irq_during_read)atomic_set(&active->event,1);
 return oversized_read?size+1:size;
}
#include "functions.inc"
static void reset(void){
 memset(memory,0,sizeof memory);memory[0xffe1]=0x11;memory[0xfffa]=0x22;
 memory[0xfffc]=0x33;memory[0xfffd]=0x44;memory[0x01c8]=0xa5;
 calls=fail_call=corrupt_call=persistent_writes=0;
 short_io=copy_fault=irq_during_read=oversized_read=false;
}
static void original_config(void){
 assert(memory[0xffe1]==0x11&&memory[0xfffa]==0x22&&memory[0xfffc]==0x33&&memory[0xfffd]==0x44);
 assert(memory[0x01c8]==0xa5&&!persistent_writes);
}
int main(void){
 struct i2c_client client={0};struct fm19511 tag={.client=&client,.refs={1}};active=&tag;
 reset();assert(!fm19511_configure(&tag));assert(calls==22);
 assert(memory[0xffe1]==9&&memory[0xfffa]==0x3e&&memory[0xfffc]==0xbf&&memory[0xfffd]==2);
 assert(memory[0x01c8]==0xa5&&!persistent_writes);
 for(unsigned int i=1;i<=22;i++)for(unsigned int short_result=0;short_result<2;short_result++){
  reset();fail_call=i;short_io=short_result;assert(fm19511_configure(&tag)<0);original_config();
 }
 for(unsigned int i=13;i<=22;i+=3){reset();corrupt_call=i;assert(fm19511_configure(&tag)==-EIO);original_config();}
 reset();struct file file={&tag.misc};struct inode inode={0};
 assert(!fm19511_open(&inode,&file)&&tag.opened&&tag.refs.count==2);
 struct file second={&tag.misc};assert(fm19511_open(&inode,&second)==-EBUSY&&tag.refs.count==2);
 char data[257]={0};loff_t offset=0;
 assert(!fm19511_read(&file,data,0,&offset)&&!fm19511_write(&file,data,0,&offset)&&!calls);
 assert(fm19511_read(&file,data,sizeof data,&offset)==-EMSGSIZE);
 assert(fm19511_write(&file,data,sizeof data,&offset)==-EMSGSIZE&&!calls);
 copy_fault=true;assert(fm19511_write(&file,data,2,&offset)==-EFAULT&&!calls);
 atomic_set(&tag.event,1);assert(fm19511_read(&file,data,2,&offset)==-EFAULT&&atomic_read(&tag.event));
 copy_fault=false;fail_call=calls+1;
 assert(fm19511_read(&file,data,2,&offset)==-EREMOTEIO&&atomic_read(&tag.event));
 fail_call=0;irq_during_read=true;
 assert(fm19511_read(&file,data,2,&offset)==2&&atomic_read(&tag.event));
 irq_during_read=false;assert(fm19511_read(&file,data,2,&offset)==2&&!atomic_read(&tag.event));
 oversized_read=true;assert(fm19511_read(&file,data,2,&offset)==-EIO);oversized_read=false;
 short_io=true;fail_call=calls+1;assert(fm19511_write(&file,data,2,&offset)==-EIO);
 short_io=false;fail_call=0;assert(fm19511_write(&file,data,2,&offset)==2);
 atomic_set(&tag.event,1);assert(fm19511_poll(&file,NULL)==(EPOLLIN|EPOLLRDNORM));
 tag.fault=-EIO;assert(fm19511_poll(&file,NULL)==EPOLLERR);tag.fault=0;
 tag.client=NULL;kref_put(&tag.refs,fm19511_free);assert(tag.refs.count==1&&!freed);
 assert(fm19511_read(&file,data,2,&offset)==-ENODEV);
 assert(fm19511_write(&file,data,2,&offset)==-ENODEV);
 assert(fm19511_poll(&file,NULL)==(EPOLLERR|EPOLLHUP));
 assert(!fm19511_release(&inode,&file)&&freed==1&&!tag.refs.count);
 puts("FM19511 actual functions: 44 transport faults, 4 readback faults, volatile rollback, bounds, IRQ race and open-file removal lifetime passed; host only.");
}
C
${CC:-cc} ${CFLAGS:-} -std=gnu11 -O2 -Wall -Wextra -Werror -Wno-unused-parameter -Wno-sign-compare \
    -I "$work" "$work/test.c" -o "$work/test"
"$work/test"
