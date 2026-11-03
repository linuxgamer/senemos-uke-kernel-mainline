#!/usr/bin/env bash
# Run the real receive worker with lock-checked shared and private packet lists.
set -euo pipefail
kernel=${1:?Pass prepared kernel tree}
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
struct list_head{struct list_head *next,*prev;};
#define LIST_HEAD(name) struct list_head name={&name,&name}
#define container_of(p,t,m) ((t*)((char*)(p)-offsetof(t,m)))
struct work_struct{int unused;};
struct packet_router{struct work_struct rx_work;struct list_head rx_list;int rx_lock,type;};
struct apr_rx_buf{struct list_head node;int id;};
static struct packet_router router;
static struct list_head *shared=&router.rx_list;
static void require_lock(struct list_head *p){if(p==shared && !router.rx_lock)fprintf(stderr,"APR shared RX list accessed without rx_lock\n");assert(p!=shared || router.rx_lock);}
static bool list_empty(struct list_head *p){require_lock(p);return p->next==p;}
static void list_add_tail(struct list_head *n,struct list_head *h){require_lock(h);n->prev=h->prev;n->next=h;h->prev->next=n;h->prev=n;}
static void list_del(struct list_head *n){n->prev->next=n->next;n->next->prev=n->prev;}
static void list_splice_init(struct list_head *from,struct list_head *to){
 require_lock(from);if(!list_empty(from)){to->next=from->next;to->prev=from->prev;to->next->prev=to;to->prev->next=to;from->next=from->prev=from;}
}
#define list_entry(p,t,m) container_of(p,t,m)
#define list_for_each_entry_safe(p,n,h,m) \
 for(require_lock(h),p=list_entry((h)->next,__typeof__(*p),m),n=list_entry(p->m.next,__typeof__(*p),m);&p->m!=(h);p=n,n=list_entry(n->m.next,__typeof__(*n),m))
#define spin_lock_irqsave(p,f) (assert(!*(p)),*(p)=1,(f)=0)
#define spin_unlock_irqrestore(p,f) ((void)(f),assert(*(p)),*(p)=0)
#define PR_TYPE_APR 0
#define PR_TYPE_GPR 1
static int delivered[8],count,freed;
static struct apr_rx_buf injected;
static void receive(struct packet_router *apr,struct apr_rx_buf *b){
 assert(!apr->rx_lock);delivered[count++]=b->id;
 if(b->id==1){unsigned long flags;spin_lock_irqsave(&apr->rx_lock,flags);list_add_tail(&injected.node,&apr->rx_list);spin_unlock_irqrestore(&apr->rx_lock,flags);}
}
static void apr_do_rx_callback(struct packet_router *p,struct apr_rx_buf *b){receive(p,b);}
static void gpr_do_rx_callback(struct packet_router *p,struct apr_rx_buf *b){receive(p,b);}
#define kfree(p) ((void)(p),++freed)
C
awk '/^static void apr_rxwq\(/ {emit=1} emit {print} emit && /^}/ {emit=0}' "$kernel/drivers/soc/qcom/apr.c" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
int main(void){
 (void)list_splice_init;
 for(int type=0;type<3;type++){
  router=(struct packet_router){.type=type};router.rx_list.next=router.rx_list.prev=&router.rx_list;count=freed=0;
  struct apr_rx_buf first={.id=1},second={.id=2};injected=(struct apr_rx_buf){.id=3};
  unsigned long flags;spin_lock_irqsave(&router.rx_lock,flags);list_add_tail(&first.node,&router.rx_list);list_add_tail(&second.node,&router.rx_list);spin_unlock_irqrestore(&router.rx_lock,flags);
  apr_rxwq(&router.rx_work);assert(!router.rx_lock && freed==2);
  if(type<2){assert(count==2 && delivered[0]==1 && delivered[1]==2);apr_rxwq(&router.rx_work);assert(count==3 && delivered[2]==3 && freed==3);}
  else assert(count==0);
  apr_rxwq(&router.rx_work);assert(!router.rx_lock);
  spin_lock_irqsave(&router.rx_lock,flags);assert(list_empty(&router.rx_list));spin_unlock_irqrestore(&router.rx_lock,flags);
 }
}
C
${CC:-cc} -std=gnu11 -Wall -Wextra -Werror -fsanitize=address,undefined -fno-omit-frame-pointer "$work/check.c" -o "$work/check"
"$work/check"
printf 'APR actual-source RX queue lock ownership, append-during-dispatch, ordering and release fixtures passed.\n'
