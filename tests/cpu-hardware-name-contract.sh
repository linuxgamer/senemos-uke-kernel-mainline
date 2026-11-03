#!/usr/bin/env bash
# Host-only compilation of the actual patched ARM64 cpuinfo formatter.
set -Eeuo pipefail
[[ $# == 1 && -f $1 ]]
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
awk '/^static int c_show\(/{copy=1} /^static void \*c_start\(/{copy=0} copy' "$1" > "$work/show.inc"
grep -Fq 'Hardware\t: Qualcomm Snapdragon 7+ Gen 3' "$work/show.inc"
cat > "$work/test.c" <<'C'
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
typedef uint32_t u32;
struct seq_file {int index;char text[4096];size_t used;};
struct cpuinfo_arm64 {u32 reg_midr;};
static struct {int personality;} task;
#define current (&task)
#define PER_LINUX32 8
#define personality(p) (p)
#define COMPAT_ELF_PLATFORM "v8l"
#define MIDR_REVISION(v) ((v)&15)
#define MIDR_IMPLEMENTOR(v) (((v)>>24)&255)
#define MIDR_VARIANT(v) (((v)>>20)&15)
#define MIDR_PARTNUM(v) (((v)>>4)&4095)
#define ARRAY_SIZE(a) (sizeof(a)/sizeof((a)[0]))
#define HZ 100
static unsigned long loops_per_jiffy=100000;
static const char* hwcap_str[]={"fp","asimd"};
static bool uke,sm7675;
static bool cpu_have_feature(int j){return j>=0;}
static bool of_machine_is_compatible(const char* name){
 if(!strcmp(name,"xiaomi,uke"))return uke;
 assert(!strcmp(name,"qcom,sm7675"));return sm7675;
}
static void seq_printf(struct seq_file* m,const char* format,...){
 va_list args;va_start(args,format);
 int n=vsnprintf(m->text+m->used,sizeof(m->text)-m->used,format,args);va_end(args);
 assert(n>=0&&(size_t)n<sizeof(m->text)-m->used);m->used+=(size_t)n;
}
static void seq_puts(struct seq_file* m,const char* text){seq_printf(m,"%s",text);}
#include "show.inc"
int main(void){
 const char field[]="Hardware\t: Qualcomm Snapdragon 7+ Gen 3\n";
 for(int compat=0;compat<2;++compat)for(int cpu=0;cpu<=7;cpu+=7){
  task.personality=compat?PER_LINUX32:0;
  struct cpuinfo_arm64 info={.reg_midr=0x410fd800};
  struct seq_file base={.index=cpu};uke=false;sm7675=false;assert(!c_show(&base,&info));
  for(int board=0;board<2;++board)for(int soc=0;soc<2;++soc){
   struct seq_file out={.index=cpu};uke=board;sm7675=soc;assert(!c_show(&out,&info));
   char* extra=strstr(out.text,field);assert((extra!=NULL)==(board&&soc));
   if(extra)memmove(extra,extra+strlen(field),strlen(extra+strlen(field))+1);
   char expected[4096];strcpy(expected,base.text);
   if(board&&soc){
    const char model[]="model name\t: Qualcomm Snapdragon 7+ Gen 3\n";
    char* product=strstr(out.text,model);assert(product);
    memmove(product,product+strlen(model),strlen(product+strlen(model))+1);
    char* old=strstr(expected,"model name\t:");
    if(old){char* end=strchr(old,'\n');assert(end);memmove(old,end+1,strlen(end+1)+1);}
   }
   assert(!strcmp(out.text,expected));
  }
 }
 puts("Actual cpuinfo formatter: Uke/SM7675 gate, other boards, compat and unchanged core fields passed.");
}
C
cc -std=gnu11 -O2 -Wall -Wextra -Werror -Wno-sign-compare "$work/test.c" -o "$work/test"
"$work/test"
