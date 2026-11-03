#!/usr/bin/env bash
# Run the real compressed callback with lock-context checks at native callees.
set -euo pipefail
kernel=${1:?Pass prepared kernel tree}
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
source=$kernel/sound/soc/qcom/qdsp6/q6apm-dai.c
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
struct mutex{bool held;};
typedef struct mutex spinlock_t;
static int atomic_depth;
static struct mutex *acquire_mutex(struct mutex *p){assert(!p->held);p->held=true;return p;}
static struct mutex *acquire_spinlock_irqsave(struct mutex *p){atomic_depth++;return acquire_mutex(p);}
static void cleanup_mutex(struct mutex **p){assert((*p)->held);(*p)->held=false;}
static void cleanup_spinlock_irqsave(struct mutex **p){atomic_depth--;cleanup_mutex(p);}
#define guard(name) struct mutex *guard_instance __attribute__((cleanup(cleanup_##name)))=acquire_##name
struct q6apm_graph{int unused;};
struct snd_compr_stream{bool partial_drain;};
struct q6apm_dai_rtd{
 struct snd_compr_stream *cstream;struct q6apm_graph *graph;
 uint64_t bytes_received,bytes_sent,copied_total;
 uint32_t pcm_count;int state;bool notify_on_drain;
C
awk '/^struct q6apm_dai_rtd \{/ {in_struct=1} in_struct && /^[[:space:]]+(spinlock_t|struct mutex) lock;/ {print} in_struct && /^};/ {in_struct=0}' "$source" >> "$work/check.c"
awk '/^#define APM_WRITE_TOKEN_LEN_SHIFT[[:space:]]/ {print}' "$kernel/sound/soc/qcom/qdsp6/q6apm.h" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
};
enum {APM_CLIENT_EVENT_CMD_EOS_DONE=1,APM_CLIENT_EVENT_DATA_WRITE_DONE=2,APM_LAST_BUFFER_FLAG=1U<<30,Q6APM_STREAM_STOPPED=1,Q6APM_STREAM_RUNNING=2};
static int fragments,drains,writes,eos;static uint32_t sent_bytes,sent_flags;
static void snd_compr_drain_notify(struct snd_compr_stream *s){(void)s;drains++;}
static void snd_compr_fragment_elapsed(struct snd_compr_stream *s){(void)s;fragments++;}
static int q6apm_write_async(struct q6apm_graph *g,uint32_t bytes,uint32_t a,uint32_t b,uint32_t flags){
 (void)g;(void)a;(void)b;
 if(atomic_depth)fprintf(stderr,"Compressed callback calls sleepable q6apm_write_async with IRQs disabled\n");
 assert(!atomic_depth);writes++;sent_bytes=bytes;sent_flags=flags;return 0;
}
static void audioreach_shared_memory_send_eos(struct q6apm_graph *g){(void)g;assert(!atomic_depth);eos++;}
C
awk '/^static void event_handler_compr\(/ {emit=1} emit {print} emit && /^}/ {emit=0}' "$source" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
int main(void){
 (void)acquire_spinlock_irqsave;(void)cleanup_spinlock_irqsave;
 struct snd_compr_stream stream={0};struct q6apm_graph graph={0};struct q6apm_dai_rtd p={.cstream=&stream,.graph=&graph,.pcm_count=4096};
 p.state=Q6APM_STREAM_RUNNING;p.bytes_received=16384;p.bytes_sent=4096;
 event_handler_compr(APM_CLIENT_EVENT_DATA_WRITE_DONE,4096U<<APM_WRITE_TOKEN_LEN_SHIFT,NULL,&p);
 assert(writes==1 && fragments==1 && p.copied_total==4096 && p.bytes_sent==8192 && sent_bytes==4096 && !sent_flags && !p.lock.held && !atomic_depth);
 p.bytes_received=9216;p.notify_on_drain=true;
 event_handler_compr(APM_CLIENT_EVENT_DATA_WRITE_DONE,4096U<<APM_WRITE_TOKEN_LEN_SHIFT,NULL,&p);
 assert(writes==2 && sent_bytes==1024 && eos==1 && sent_flags==0);
 p.state=Q6APM_STREAM_STOPPED;event_handler_compr(APM_CLIENT_EVENT_DATA_WRITE_DONE,1024U<<APM_WRITE_TOKEN_LEN_SHIFT,NULL,&p);assert(writes==2);
 event_handler_compr(APM_CLIENT_EVENT_CMD_EOS_DONE,0,NULL,&p);assert(drains==1 && !p.notify_on_drain);
 p.state=Q6APM_STREAM_RUNNING;event_handler_compr(APM_CLIENT_EVENT_CMD_EOS_DONE,0,NULL,&p);assert(p.state==Q6APM_STREAM_STOPPED);
 assert(!p.lock.held && !atomic_depth);
}
C
${CC:-cc} -std=gnu11 -Wall -Wextra -Werror -Wno-unused-parameter -fsanitize=address,undefined -fno-omit-frame-pointer "$work/check.c" -o "$work/check"
"$work/check"
printf 'Compressed actual-source callback sleepable lock, accounting, drain and EOS fixtures passed.\n'
