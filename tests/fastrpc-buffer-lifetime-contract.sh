#!/usr/bin/env bash
# Actual coherent-buffer and dma-buf callbacks; all DMA/device operations mocked.
set -Eeuo pipefail
source_file=${1:?Pass the prepared fastrpc.c}
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
cat > "$work/check.cpp" <<'CPP'
#include <cassert>
#include <cerrno>
#include <cstdint>
#include <cstddef>
#include <type_traits>
#include <initializer_list>
using dma_addr_t=uint64_t; using u64=uint64_t;
#define GFP_KERNEL 0
#define GENMASK_ULL(h,l) ((UINT64_MAX>>(63-(h))) & (UINT64_MAX<<(l)))
struct device { int refs=1; };
struct mutex { bool active=false; };
struct list_head {};
struct sg_table { bool live=false; };
struct fastrpc_buf;
struct fastrpc_dma_buf_attachment;
struct dma_buf { fastrpc_buf *priv; void *resv=nullptr; };
struct dma_buf_attachment { device *dev; fastrpc_dma_buf_attachment *priv=nullptr; };
struct vm_area_struct { uintptr_t vm_start=0x1000,vm_end=0x2000; };
struct fastrpc_soc_data { unsigned int sid_pos; };
struct fastrpc_channel_ctx { const fastrpc_soc_data *soc_data; };
struct fastrpc_session_ctx { device *dev; unsigned int sid; };
struct fastrpc_user { fastrpc_channel_ctx *cctx; fastrpc_session_ctx *sctx; };
struct fastrpc_dma_buf_attachment { device *dev; sg_table sgt; list_head node; };
static unsigned int allocations, frees, kz_calls, kz_fail, active_locks, dma_calls, sg_calls, mmap_calls;
static bool dma_failure;
static int sg_error,mmap_error;
static dma_addr_t raw_handle;
static void *dma_memory;
template<class T> T *zero_alloc() { ++kz_calls; if (kz_calls==kz_fail) return nullptr; ++allocations; return new T{}; }
#define kzalloc_obj(x) zero_alloc<std::remove_reference_t<decltype(x)>>()
template<class T> void kfree(T *p) { assert(p); ++frees; delete p; }
[[maybe_unused]] static device *get_device(device *dev) { assert(dev && dev->refs>0); ++dev->refs; return dev; }
static void put_device(device *dev) { assert(dev && dev->refs>0); --dev->refs; }
static void INIT_LIST_HEAD(list_head *) {}
static void mutex_init(mutex *m) { assert(!m->active); m->active=true; ++active_locks; }
static void mutex_destroy(mutex *m) { assert(m->active && active_locks); m->active=false; --active_locks; }
static void mutex_lock(mutex *m) { assert(m->active); }
static void mutex_unlock(mutex *m) { assert(m->active); }
static void list_add(list_head *,list_head *) {}
static void list_del(list_head *) {}
template<class... T> void dev_err(device *,const char *,T...) {}
static void *dma_alloc_coherent(device *dev,u64 size,dma_addr_t *handle,int flags) {
    assert(dev->refs>0 && size==4096 && flags==0); ++dma_calls;
    if (dma_failure) return nullptr;
    assert(!dma_memory); *handle=raw_handle; dma_memory=new unsigned char[size]; return dma_memory;
}
static void dma_free_coherent(device *dev,u64 size,void *memory,dma_addr_t handle) {
    assert(dev->refs>0 && size==4096 && memory==dma_memory && handle==raw_handle);
    delete[] static_cast<unsigned char *>(memory); dma_memory=nullptr;
}
static int dma_get_sgtable(device *dev,sg_table *sg,void *memory,dma_addr_t handle,u64 size) {
    assert(dev->refs>0 && memory==dma_memory && handle==raw_handle && size==4096); ++sg_calls;
    if (sg_error) return sg_error;
    sg->live=true; return 0;
}
static void sg_free_table(sg_table *sg) { assert(sg->live); sg->live=false; }
static void dma_resv_assert_held(void *) {}
static int dma_mmap_coherent(device *dev,vm_area_struct *,void *memory,dma_addr_t handle,size_t size) {
    assert(dev->refs>0 && memory==dma_memory && handle==raw_handle && size==4096); ++mmap_calls; return mmap_error;
}
CPP
awk '/^struct fastrpc_buf \{/ {emit=1} emit {print} emit && /^};/ {emit=0}' "$source_file" >> "$work/check.cpp"
awk '/^static (inline dma_addr_t fastrpc_ipa_to_dma_addr|inline u64 fastrpc_sid_offset|void fastrpc_buf_free|int __fastrpc_buf_alloc|int fastrpc_buf_alloc|int fastrpc_dma_buf_attach|void fastrpc_dma_buf_detatch|int fastrpc_mmap)\(/ {emit=1} emit {print} emit && /^}/ {emit=0}' "$source_file" >> "$work/check.cpp"
cat >> "$work/check.cpp" <<'CPP'
static void reset() {
    assert(!dma_memory && allocations==frees && !active_locks);
    allocations=frees=kz_calls=kz_fail=dma_calls=sg_calls=mmap_calls=0;
    dma_failure=false; sg_error=mmap_error=0;
}
int main() {
    for (unsigned int sid_pos : {32U,56U}) {
        for (unsigned int sid : {0U,3U}) {
            reset(); device dev; fastrpc_soc_data soc{sid_pos};
            auto *channel=new fastrpc_channel_ctx{&soc};
            auto *session=new fastrpc_session_ctx{&dev,sid};
            auto *user=new fastrpc_user{channel,session};
            raw_handle=sid_pos==32?0x12345000:0xabc012345000;
            fastrpc_buf *buf=nullptr;
            assert(fastrpc_buf_alloc(user,&dev,4096,&buf)==0 && buf && dma_calls==1);
            assert(buf->dma_addr==raw_handle+((u64)sid<<sid_pos));
            // A dma-buf fd remains usable after closing its creating FastRPC fd.
            delete user; delete session; delete channel;
            dma_buf dmabuf{buf}; dma_buf_attachment attachment{&dev}; vm_area_struct vma;
            assert(fastrpc_dma_buf_attach(&dmabuf,&attachment)==0 && sg_calls==1);
            assert(fastrpc_mmap(&dmabuf,&vma)==0 && mmap_calls==1);
            mmap_error=-EIO;
            assert(fastrpc_mmap(&dmabuf,&vma)==-EIO && mmap_calls==2);
            fastrpc_dma_buf_detatch(&dmabuf,&attachment);
            // The buffer also owns the reference needed by its final DMA free.
            assert(dev.refs==2); put_device(&dev); assert(dev.refs==1);
            fastrpc_buf_free(buf); assert(!dev.refs); reset();
        }
    }
    for (int fault : {1,2,3,4}) {
        reset(); device dev; fastrpc_soc_data soc{32}; fastrpc_channel_ctx channel{&soc};
        fastrpc_session_ctx session{&dev,1}; fastrpc_user user{&channel,&session};
        fastrpc_buf *buf=nullptr; raw_handle=0x12345000;
        if (fault==1) kz_fail=1;
        if (fault==2) dma_failure=true;
        int ret=fastrpc_buf_alloc(&user,&dev,4096,&buf);
        if (fault<=2) { assert(ret==-ENOMEM && !buf && dev.refs==1); reset(); continue; }
        assert(ret==0 && dev.refs==2);
        dma_buf dmabuf{buf}; dma_buf_attachment attachment{&dev};
        if (fault==3) kz_fail=kz_calls+1;
        if (fault==4) sg_error=-ENOMEM;
        assert(fastrpc_dma_buf_attach(&dmabuf,&attachment)==(fault==3?-ENOMEM:-EINVAL));
        assert(!attachment.priv); fastrpc_buf_free(buf); assert(dev.refs==1); reset();
    }
}
CPP
flags=(-std=c++20 -O2 -Wall -Wextra -Werror)
if [[ ${SANITIZE:-0} == 1 ]]; then
    flags+=(-O1 -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer)
fi
"${CXX:-g++}" "${flags[@]}" "$work/check.cpp" -o "$work/check"
"$work/check"
printf 'Actual FastRPC buffers: creator close, 32/56-bit SID encoding, DMA handles, device refs and allocation/attach/mmap errors passed\n'
