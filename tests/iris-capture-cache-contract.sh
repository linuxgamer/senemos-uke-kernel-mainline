#!/usr/bin/env bash
# Exercise the actual queue setup; no device or allocator is invoked.
set -Eeuo pipefail
iris=${1:?Pass the prepared Iris directory}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cat > "$work/check.cpp" <<'CPP'
#include <cassert>
#include <cerrno>
#include <linux/videodev2.h>
constexpr int DECODER=0,ENCODER=1,VB2_MEMORY_MMAP=1,VB2_MEMORY_DMABUF=4;
constexpr int IRIS_INST_ERROR=9,IRIS_INST_INIT=1;
struct iris_platform_data {};
static iris_platform_data sm7675_data,legacy_data;
struct iris_core {struct iris_platform_data *iris_platform_data;void *dev=nullptr;};
struct iris_inst;
struct session_ops {int (*session_open)(iris_inst *);};
struct iris_inst {
 iris_core *core;int domain=DECODER,state=0,lock=0;v4l2_format *fmt_src,*fmt_dst;
 bool once_per_session_set=true;session_ops *hfi_session_ops=nullptr;
};
struct vb2_queue {iris_inst *inst;unsigned type,memory;bool non_coherent_mem=false;};
static iris_inst *vb2_get_drv_priv(vb2_queue *q) {return q->inst;}
static void mutex_lock(int *) {} static void mutex_unlock(int *) {}
static int iris_check_session_supported(iris_inst *) {return 0;}
static int iris_inst_change_state(iris_inst *,int) {return 0;}
static void dev_err(void *,const char *) {}
CPP
awk '/^int iris_vb2_queue_setup\(/ {emit=1} emit {print} emit && /^}/ {exit}' "$iris/iris_vb2.c" >> "$work/check.cpp"
cat >> "$work/check.cpp" <<'CPP'
int main() {
 iris_core core{&sm7675_data};v4l2_format src{},dst{};
 src.fmt.pix_mp.num_planes=dst.fmt.pix_mp.num_planes=1;
 src.fmt.pix_mp.plane_fmt[0].sizeimage=dst.fmt.pix_mp.plane_fmt[0].sizeimage=4096;
 iris_inst inst{&core,DECODER,0,0,&src,&dst};
 vb2_queue q{&inst,V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE,VB2_MEMORY_MMAP};
 unsigned count=32,planes=0,size[1]{};
 assert(iris_vb2_queue_setup(&q,&count,&planes,size,nullptr)==0);
 assert(q.non_coherent_mem&&planes==1&&size[0]==4096);
 // The allocator's owner controls imported DMABUF cache policy.
 q.memory=VB2_MEMORY_DMABUF;
 assert(iris_vb2_queue_setup(&q,&count,&planes,size,nullptr)==0&&!q.non_coherent_mem);
 q.memory=VB2_MEMORY_MMAP;q.type=V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
 assert(iris_vb2_queue_setup(&q,&count,&planes,size,nullptr)==0&&!q.non_coherent_mem);
 q.type=V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;inst.domain=ENCODER;
 assert(iris_vb2_queue_setup(&q,&count,&planes,size,nullptr)==0&&!q.non_coherent_mem);
 inst.domain=DECODER;core.iris_platform_data=&legacy_data;
 assert(iris_vb2_queue_setup(&q,&count,&planes,size,nullptr)==0&&!q.non_coherent_mem);
 core.iris_platform_data=&sm7675_data;inst.state=IRIS_INST_ERROR;
 assert(iris_vb2_queue_setup(&q,&count,&planes,size,nullptr)==-EBUSY&&!q.non_coherent_mem);
}
CPP
${CXX:-c++} -std=c++17 -Wall -Wextra -Werror -Wno-unused-parameter "$work/check.cpp" -o "$work/check"
"$work/check"
printf '%s\n' 'PASS: actual SM7675 decoder CAPTURE cache policy and unchanged import/encoder/legacy/error paths'
