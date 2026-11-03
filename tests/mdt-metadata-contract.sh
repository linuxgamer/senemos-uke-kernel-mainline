#!/usr/bin/env bash
# Actual Linux-C metadata parser; optional OEM headers stay read-only on the host.
set -Eeuo pipefail
source_file=${1:?Pass prepared mdt_loader.c}
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <linux/elf.h>
#define GFP_KERNEL 0
#define ERR_PTR(e) ((void *)(intptr_t)(e))
#define IS_ERR(p) ((uintptr_t)(p)>=(uintptr_t)-4095)
#define PTR_ERR(p) ((int)(intptr_t)(p))
#define QCOM_MDT_TYPE_MASK (7U<<24)
#define QCOM_MDT_TYPE_HASH (2U<<24)
#define dev_err(...) ((void)0)
struct firmware { size_t size; const unsigned char *data; };
struct device { int unused; };
static size_t alloc_size, segment_size;
static unsigned int allocations, segments;
static int segment_error;
static bool allocation_failure;
static void *kmalloc(size_t size,int flags) { (void)flags; allocations++; alloc_size=size; return allocation_failure||size>0x100000?NULL:malloc(size); }
static void kfree(void *p) { free(p); }
static size_t size_add(size_t a,size_t b) { return b>SIZE_MAX-a?SIZE_MAX:a+b; }
static size_t size_mul(size_t a,size_t b) { return b && a>SIZE_MAX/b?SIZE_MAX:a*b; }
static ssize_t mdt_load_split_segment(void *data,const struct elf32_phdr *ph,unsigned int n,const char *name,struct device *dev) {
    (void)name; (void)dev; segments++; segment_size=ph[n].p_filesz;
    if(segment_error) return segment_error;
    memset(data,0x7c,segment_size); return 0;
}
C
awk '/^(static bool mdt_header_valid|void \*qcom_mdt_read_metadata)\(/ {emit=1} emit {print} emit && /^}/ {emit=0}' "$source_file" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
struct image {
    struct elf32_hdr header;
    struct elf32_phdr ph[3];
    unsigned char hash[8];
};
static struct image make_image(void) {
    struct image im={0};
    memcpy(im.header.e_ident,ELFMAG,SELFMAG);
    im.header.e_ident[EI_CLASS]=ELFCLASS32; im.header.e_ident[EI_DATA]=ELFDATA2LSB;
    im.header.e_ident[EI_VERSION]=EV_CURRENT; im.header.e_ehsize=sizeof(im.header);
    im.header.e_phoff=sizeof(im.header); im.header.e_phnum=3; im.header.e_phentsize=sizeof(im.ph[0]);
    im.ph[0].p_filesz=sizeof(im.header)+sizeof(im.ph);
    im.ph[1].p_type=PT_LOAD; im.ph[1].p_flags=QCOM_MDT_TYPE_HASH;
    im.ph[1].p_offset=0x10000; im.ph[1].p_filesz=sizeof(im.hash);
    for(unsigned int i=0;i<sizeof(im.hash);i++) im.hash[i]=i+1;
    return im;
}
static void reset(void) { allocations=segments=0; alloc_size=segment_size=0; allocation_failure=false; segment_error=0; }
int main(int argc,char **argv) {
    struct device dev={0}; struct image im=make_image();
    struct firmware fw={sizeof(im),(const unsigned char *)&im}; size_t size=0;
    // Refuse a forged header size before allocation or copying.
    im.ph[0].p_filesz=fw.size+1;
    void *data=qcom_mdt_read_metadata(&fw,&size,"cdsp.mdt",&dev);
    assert(IS_ERR(data) && PTR_ERR(data)==-EINVAL && !allocations && !segments);
    for(int bad=0;bad<13;bad++) {
        reset(); im=make_image();
        switch(bad) {
        case 0: im.ph[0].p_filesz=0; break;
        case 1: im.ph[0].p_filesz=sizeof(struct elf32_hdr); break;
        case 2: im.ph[1].p_filesz=0; break;
        case 3: im.ph[1].p_flags=0; break;
        case 4: im.ph[0].p_type=PT_LOAD; break;
        case 5: im.header.e_ident[EI_CLASS]=ELFCLASS64; break;
        case 6: im.header.e_ident[EI_DATA]=ELFDATA2MSB; break;
        case 7: im.header.e_ident[EI_VERSION]=EV_NONE; break;
        case 8: im.header.e_ehsize=sizeof(struct elf32_hdr)-1; break;
        case 9: im.header.e_phoff=0; break;
        case 10: im.header.e_phoff=sizeof(struct elf32_hdr)+1; break;
        case 11: im.header.e_shnum=1; im.header.e_shentsize=sizeof(struct elf32_shdr); im.header.e_shoff=0; break;
        case 12: im.header.e_shnum=1; im.header.e_shentsize=sizeof(struct elf32_shdr); im.header.e_shoff=sizeof(struct elf32_hdr)+1; break;
        }
        data=qcom_mdt_read_metadata(&fw,&size,"cdsp.mdt",&dev);
        assert(IS_ERR(data) && PTR_ERR(data)==-EINVAL && !allocations && !segments);
    }
    reset(); im=make_image();
    data=qcom_mdt_read_metadata(&fw,&size,"cdsp.mdt",&dev);
    assert(!IS_ERR(data) && allocations==1 && !segments && size==sizeof(im) && alloc_size==size);
    assert(!memcmp(data,&im,im.ph[0].p_filesz));
    assert(!memcmp((unsigned char *)data+im.ph[0].p_filesz,im.hash,sizeof(im.hash))); kfree(data);
    // Complete images can store hashes in-file; split images can use an external segment.
    im.ph[1].p_offset=im.ph[0].p_filesz; im.ph[1].p_filesz=4;
    reset(); data=qcom_mdt_read_metadata(&fw,&size,"cdsp.mbn",&dev);
    assert(!IS_ERR(data) && !segments && size==im.ph[0].p_filesz+4);
    assert(!memcmp((unsigned char *)data+im.ph[0].p_filesz,im.hash,4)); kfree(data);
    im.ph[1].p_offset=UINT32_MAX;
    reset(); data=qcom_mdt_read_metadata(&fw,&size,"cdsp.mdt",&dev);
    assert(!IS_ERR(data) && segments==1 && segment_size==4); kfree(data);
    reset(); segment_error=-ENOENT; data=qcom_mdt_read_metadata(&fw,&size,"cdsp.mdt",&dev);
    assert(IS_ERR(data) && PTR_ERR(data)==-ENOENT && segments==1);
    reset(); allocation_failure=true; data=qcom_mdt_read_metadata(&fw,&size,"cdsp.mdt",&dev);
    assert(IS_ERR(data) && PTR_ERR(data)==-ENOMEM && !segments);
    for(int i=1;i<argc;i++) {
        reset(); FILE *input=fopen(argv[i],"rb"); assert(input);
        assert(fseek(input,0,SEEK_END)==0); long bytes=ftell(input); assert(bytes>0);
        rewind(input); unsigned char *buffer=malloc((size_t)bytes); assert(buffer);
        assert(fread(buffer,1,(size_t)bytes,input)==(size_t)bytes); fclose(input);
        struct firmware actual={(size_t)bytes,buffer};
        data=qcom_mdt_read_metadata(&actual,&size,"cdsp.mdt",&dev);
        assert(!IS_ERR(data) && size<=actual.size && !segments); kfree(data); free(buffer);
    }
    puts("Actual MDT metadata: header/table/hash bounds, ELF format, allocation/segment errors and retained headers passed; host only");
    return 0;
}
C
"${CC:-cc}" -std=gnu11 -O1 -g -Wall -Wextra -Werror \
    -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer \
    "$work/check.c" -o "$work/check"
"$work/check" "${@:2}"
