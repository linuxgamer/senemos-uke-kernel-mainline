#!/usr/bin/env bash
# Actual MDT admission functions with host-only SCM and segment-loader ledgers.
set -Eeuo pipefail
source_file=${1:?Pass the prepared mdt_loader.c}
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
cat > "$work/check.cpp" <<'CPP'
#include <cassert>
#include <cerrno>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iterator>
#include <limits>
#include <vector>
#include <linux/elf.h>
#include <sys/types.h>
using phys_addr_t=uint64_t;
#define PHYS_ADDR_MAX UINT64_MAX
#define __iomem
#define __force
#define SZ_4K 4096U
#define BIT(n) (1U<<(n))
#define QCOM_MDT_TYPE_MASK (7U<<24)
#define QCOM_MDT_TYPE_HASH (2U<<24)
#define QCOM_MDT_RELOCATABLE BIT(27)
#define ALIGN(x,a) (((x)+(decltype(x))((a)-1)) & ~(decltype(x))((a)-1))
#define IS_ERR(p) ((uintptr_t)(p)>=(uintptr_t)-4095)
#define PTR_ERR(p) ((int)(intptr_t)(p))
struct firmware { size_t size; const unsigned char *data; };
struct device {};
struct qcom_pas_context { device *dev; int pas_id; phys_addr_t mem_phys; size_t mem_size; };
static unsigned int metadata_reads, metadata_live, init_calls, setup_calls, segment_calls;
static unsigned int map_calls, unmap_calls;
static bool map_failure;
static unsigned char mapped_memory;
static void *qcom_pas_ctx_map(qcom_pas_context *) { ++map_calls; return map_failure ? nullptr : &mapped_memory; }
static void iounmap(void *memory) { assert(memory==&mapped_memory); ++unmap_calls; }
static int metadata_error, init_error, setup_error, segment_error;
static phys_addr_t setup_phys, setup_size;
static size_t size_add(size_t a,size_t b) { return b>SIZE_MAX-a?SIZE_MAX:a+b; }
static size_t size_mul(size_t a,size_t b) { return b && a>SIZE_MAX/b?SIZE_MAX:a*b; }
template<class... T> void dev_err(device *,const char *,T...) {}
static void *qcom_mdt_read_metadata(const firmware *,size_t *length,const char *,device *) {
    ++metadata_reads;
    if (metadata_error) return (void *)(intptr_t)metadata_error;
    *length=16; ++metadata_live; return std::malloc(*length);
}
static void kfree(void *p) { assert(p && metadata_live==1); --metadata_live; std::free(p); }
static int qcom_pas_init_image(int,const void *,size_t,qcom_pas_context *) {
    ++init_calls; return init_error;
}
static int qcom_pas_mem_setup(int,phys_addr_t phys,phys_addr_t size) {
    ++setup_calls; setup_phys=phys; setup_size=size; return setup_error;
}
static int qcom_mdt_load_no_init(device *,const firmware *,const char *,void *,phys_addr_t,size_t,phys_addr_t *) {
    ++segment_calls; return segment_error;
}
CPP
awk '/^(static bool mdt_(header_valid|phdr_loadable)|ssize_t qcom_mdt_get_size|static int __qcom_mdt_pas_init|int qcom_mdt_(load|pas_load))\(/ {emit=1} emit {print} emit && /^}/ {emit=0}' "$source_file" >> "$work/check.cpp"
cat >> "$work/check.cpp" <<'CPP'
struct image {
    elf32_hdr hdr{};
    elf32_phdr ph[3]{};
    image() {
        std::memcpy(hdr.e_ident,ELFMAG,SELFMAG);
        hdr.e_ident[EI_CLASS]=ELFCLASS32; hdr.e_ident[EI_DATA]=ELFDATA2LSB;
        hdr.e_ident[EI_VERSION]=EV_CURRENT; hdr.e_ehsize=sizeof(hdr);
        hdr.e_phoff=sizeof(hdr); hdr.e_phentsize=sizeof(ph[0]); hdr.e_phnum=3;
        ph[0].p_type=PT_LOAD; ph[0].p_flags=QCOM_MDT_RELOCATABLE;
        ph[0].p_paddr=0x9e300000; ph[0].p_memsz=0x2000; ph[0].p_filesz=0x100;
        ph[1].p_type=PT_LOAD; ph[1].p_flags=QCOM_MDT_TYPE_HASH;
        ph[1].p_paddr=0xffffffff; ph[1].p_memsz=0xffffffff;
    }
    firmware fw() const { return {sizeof(*this),(const unsigned char *)this}; }
};
static void reset() {
    assert(!metadata_live);
    metadata_reads=init_calls=setup_calls=segment_calls=0;
    metadata_error=init_error=setup_error=segment_error=0; setup_phys=setup_size=0;
    map_calls=unmap_calls=0; map_failure=false;
}
static void untouched() { assert(!metadata_reads && !metadata_live && !init_calls && !setup_calls && !segment_calls && !map_calls && !unmap_calls); }
int main(int argc,char **argv) {
    device dev; unsigned char memory{};
    qcom_pas_context ctx{&dev,18,0x99900000,0x2000};
    image im; firmware fw=im.fw();
    // An oversize image must be refused before even the metadata/SCM steps.
    im.ph[0].p_memsz=0x3000;
    assert(qcom_mdt_pas_load(&ctx,&fw,"cdsp.mdt",nullptr)==-EINVAL); untouched();
    assert(qcom_mdt_load(&dev,&fw,"cdsp.mdt",18,&memory,ctx.mem_phys,ctx.mem_size,nullptr)==-EINVAL); untouched();
    im=image{}; fw=im.fw();
    for (int bad=0;bad<20;++bad) {
        if (bad==8) continue; // PAS now maps its own context; legacy NULL is checked separately.
        image invalid=im; firmware bad_fw=invalid.fw(); auto bad_ctx=ctx; void *region=&memory;
        switch (bad) {
        case 0: bad_fw.size=sizeof(elf32_hdr)-1; break;
        case 1: invalid.hdr.e_phoff=UINT32_MAX; break;
        case 2: invalid.hdr.e_phnum=UINT16_MAX; break;
        case 3: invalid.ph[0].p_filesz=invalid.ph[0].p_memsz+1; break;
        case 4: invalid.ph[0].p_memsz=0; break;
        case 5: bad_ctx.mem_size=0; break;
        case 6: bad_ctx.mem_phys=0; break;
        case 7: bad_ctx.mem_phys=UINT64_MAX-0xfff; break;
        case 8: region=nullptr; break;
        case 9: bad_fw.data=nullptr; break;
        case 10: invalid.hdr.e_phentsize=1; break;
        case 11: invalid.hdr.e_shnum=UINT16_MAX; invalid.hdr.e_shentsize=sizeof(elf32_shdr); break;
        case 12: invalid.hdr.e_ident[EI_CLASS]=ELFCLASS64; break;
        case 13: invalid.hdr.e_ident[EI_DATA]=ELFDATA2MSB; break;
        case 14: invalid.hdr.e_ident[EI_VERSION]=EV_NONE; break;
        case 15: invalid.hdr.e_ehsize=sizeof(elf32_hdr)-1; break;
        case 16: invalid.hdr.e_phoff=0; break;
        case 17: invalid.hdr.e_phoff=sizeof(elf32_hdr)+1; break;
        case 18: invalid.hdr.e_shnum=1; invalid.hdr.e_shentsize=sizeof(elf32_shdr); invalid.hdr.e_shoff=0; break;
        case 19: invalid.hdr.e_shnum=1; invalid.hdr.e_shentsize=sizeof(elf32_shdr); invalid.hdr.e_shoff=sizeof(elf32_hdr)+1; break;
        }
        assert(qcom_mdt_pas_load(&bad_ctx,&bad_fw,"cdsp.mdt",nullptr)==-EINVAL); untouched();
        assert(qcom_mdt_load(&dev,&bad_fw,"cdsp.mdt",18,region,bad_ctx.mem_phys,bad_ctx.mem_size,nullptr)==-EINVAL); untouched();
    }
    assert(qcom_mdt_load(&dev,&fw,"cdsp.mdt",18,nullptr,ctx.mem_phys,ctx.mem_size,nullptr)==-EINVAL); untouched();
    assert(qcom_mdt_pas_load(nullptr,&fw,"cdsp.mdt",nullptr)==-EINVAL); untouched();
    assert(qcom_mdt_pas_load(&ctx,nullptr,"cdsp.mdt",nullptr)==-EINVAL); untouched();
    for (bool pas : {false,true}) {
        reset();
        auto load=[&]() { return pas?qcom_mdt_pas_load(&ctx,&fw,"cdsp.mdt",nullptr):qcom_mdt_load(&dev,&fw,"cdsp.mdt",18,&memory,ctx.mem_phys,ctx.mem_size,nullptr); };
        assert(load()==0 && metadata_reads==1 && init_calls==1 && setup_calls==1 && segment_calls==1);
        assert(setup_phys==ctx.mem_phys && setup_size==ctx.mem_size && !metadata_live);
        reset(); metadata_error=-ENOENT;
        assert(load()==-ENOENT && metadata_reads==1 && !init_calls && !setup_calls && !segment_calls && !metadata_live);
        reset(); init_error=-EACCES;
        assert(load()==-EACCES && init_calls==1 && !setup_calls && !segment_calls && !metadata_live);
        reset(); setup_error=-EBUSY;
        assert(load()==-EBUSY && init_calls==1 && setup_calls==1 && !segment_calls && !metadata_live);
        reset(); segment_error=-ENODATA;
        assert(load()==-ENODATA && segment_calls==1 && !metadata_live);
    }
    reset(); map_failure=true;
    assert(qcom_mdt_pas_load(&ctx,&fw,"cdsp.mdt",nullptr)==-ENOMEM);
    assert(init_calls==1 && setup_calls==1 && map_calls==1 && !unmap_calls && !segment_calls);
    // Absolute addresses must fit the actual carveout, not merely its length.
    reset(); im.ph[0].p_flags=0; im.ph[0].p_paddr=ctx.mem_phys-1;
    assert(qcom_mdt_pas_load(&ctx,&fw,"cdsp.mdt",nullptr)==-EINVAL); untouched();
    im.ph[0].p_paddr=ctx.mem_phys+1;
    assert(qcom_mdt_pas_load(&ctx,&fw,"cdsp.mdt",nullptr)==-EINVAL); untouched();
    im.ph[0].p_paddr=ctx.mem_phys; im.ph[0].p_memsz=0x1fff;
    assert(qcom_mdt_pas_load(&ctx,&fw,"cdsp.mdt",nullptr)==0 && !setup_calls && segment_calls==1);
    // Relocation setup includes page rounding and must remain within the carveout.
    reset(); im=image{}; im.ph[0].p_memsz=0x1001; ctx.mem_size=0x1001;
    assert(qcom_mdt_pas_load(&ctx,&fw,"cdsp.mdt",nullptr)==-EINVAL); untouched();
    ctx.mem_size=0x2000;
    assert(qcom_mdt_pas_load(&ctx,&fw,"cdsp.mdt",nullptr)==0 && setup_size==0x2000);
    // Adding ELF32 address/length fields must not wrap before 64-bit promotion.
    reset(); im.ph[0].p_paddr=0xfffff000; im.ph[0].p_memsz=0x2000;
    assert(qcom_mdt_get_size(&fw)==0x2000);
    assert(qcom_mdt_pas_load(&ctx,&fw,"cdsp.mdt",nullptr)==0 && setup_size==0x2000);
    // A zero-fill LOAD, holes, an unordered minimum and ignored hash entries.
    reset(); im=image{}; im.ph[0].p_paddr+=0x1000; im.ph[0].p_filesz=0;
    im.ph[2]=im.ph[0]; im.ph[2].p_paddr-=0x1000; im.ph[2].p_memsz=0x1000;
    ctx.mem_size=0x3000;
    assert(qcom_mdt_get_size(&fw)==0x3000);
    assert(qcom_mdt_pas_load(&ctx,&fw,"cdsp.mdt",nullptr)==0 && setup_size==0x3000);
    for (int i=1;i<argc;++i) {
        reset(); std::ifstream input(argv[i],std::ios::binary); assert(input.good());
        std::vector<unsigned char> bytes{std::istreambuf_iterator<char>(input),{}};
        firmware actual{bytes.size(),bytes.data()};
        const bool dtb=i==2; ctx.mem_phys=dtb?0x9ad00000:0x99900000; ctx.mem_size=dtb?0x80000:0x1400000;
        assert(qcom_mdt_get_size(&actual)==(dtb?0x10000:0x1400000));
        assert(qcom_mdt_pas_load(&ctx,&actual,"cdsp.mdt",nullptr)==0 && setup_size<=ctx.mem_size);
    }
}
CPP
flags=(-std=c++20 -O2 -Wall -Wextra -Werror)
if [[ ${SANITIZE:-0} == 1 ]]; then
    flags+=(-O1 -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer)
fi
"${CXX:-g++}" "${flags[@]}" "$work/check.cpp" -o "$work/check"
"$work/check" "${@:2}"
printf 'Actual MDT admission: pre-SCM refusals, relative/absolute bounds, wrap and error propagation passed (%s supplied headers)\n' "$(( $# - 1 ))"
