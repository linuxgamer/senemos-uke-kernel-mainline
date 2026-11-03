/* SPDX-License-Identifier: GPL-2.0-only */
#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

typedef uint64_t u64;
#define container_of(p, t, m) ((t *)((char *)(p) - offsetof(t, m)))
#define mutex_lock(m) assert(pthread_mutex_lock(m) == 0)
#define mutex_unlock(m) assert(pthread_mutex_unlock(m) == 0)
#define atomic64_read(p) atomic_load(p)
#define atomic64_set(p, v) atomic_store((p), (v))
struct notifier_block {
    int (*notifier_call)(struct notifier_block *, unsigned long, void *);
    struct notifier_block *next;
    unsigned int count;
    u64 latest;
};
struct blocking_notifier_head { pthread_rwlock_t lock; struct notifier_block *head; };
struct drm_panel { const void *funcs; };
static const char o82_funcs, foreign_funcs;
struct dsi { struct { int kobj; } dev; };
struct o82_panel {
    struct drm_panel panel;
    atomic_llong touch_state;
    pthread_mutex_t touch_lock;
    struct blocking_notifier_head touch_notifiers;
    struct dsi *dsi[1];
};
static unsigned int notifications;
static void sysfs_notify(void *kobj, const char *unused, const char *name) { notifications++; }
static int blocking_notifier_chain_register(struct blocking_notifier_head *h, struct notifier_block *nb) {
    assert(pthread_rwlock_wrlock(&h->lock) == 0);
    nb->next = h->head; h->head = nb;
    assert(pthread_rwlock_unlock(&h->lock) == 0);
    return 0;
}
static pthread_mutex_t barrier_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t barrier_cond = PTHREAD_COND_INITIALIZER;
static bool wait_callback, entered, proceed, unregister_entered;
static atomic_bool unregister_done;
static int blocking_notifier_chain_unregister(struct blocking_notifier_head *h, struct notifier_block *nb) {
    assert(pthread_rwlock_wrlock(&h->lock) == 0);
    struct notifier_block **p = &h->head;
    while (*p && *p != nb) p = &(*p)->next;
    assert(*p == nb); *p = nb->next;
    assert(pthread_rwlock_unlock(&h->lock) == 0);
    return 0;
}
static int blocking_notifier_call_chain(struct blocking_notifier_head *h, unsigned long event, void *data) {
    assert(pthread_rwlock_rdlock(&h->lock) == 0);
    for (struct notifier_block *nb = h->head; nb; nb = nb->next) nb->notifier_call(nb, event, data);
    assert(pthread_rwlock_unlock(&h->lock) == 0);
    return 0;
}

#include "panel-production.h"

static struct dsi dsi;
static struct o82_panel panel = {
    .panel.funcs = &o82_funcs,
    .touch_lock = PTHREAD_MUTEX_INITIALIZER,
    .touch_notifiers.lock = PTHREAD_RWLOCK_INITIALIZER,
    .dsi = { &dsi },
};
static int observe(struct notifier_block *nb, unsigned long event, void *data) {
    nb->count++; nb->latest = *(u64 *)data;
    mutex_lock(&barrier_lock);
    if (wait_callback) {
        entered = true;
        assert(pthread_cond_broadcast(&barrier_cond) == 0);
        while (!proceed) assert(pthread_cond_wait(&barrier_cond, &barrier_lock) == 0);
    }
    mutex_unlock(&barrier_lock);
    return 0;
}
static struct notifier_block first = { .notifier_call = observe };
static void *publish(void *unused) { o82_touch_state(&panel, true, false); return NULL; }
static void *unsubscribe(void *unused) {
    mutex_lock(&barrier_lock);
    unregister_entered = true;
    assert(pthread_cond_broadcast(&barrier_cond) == 0);
    mutex_unlock(&barrier_lock);
    uke_o82_touch_unregister(&panel.panel, &first);
    atomic_store(&unregister_done, true);
    return NULL;
}

int main(void) {
    struct notifier_block second = { .notifier_call = observe }, invalid = { 0 };
    struct drm_panel foreign = { .funcs = &foreign_funcs };
    assert(uke_o82_touch_register(NULL, &first) == -EINVAL);
    assert(uke_o82_touch_register(&foreign, &first) == -EINVAL);
    assert(uke_o82_touch_register(&panel.panel, NULL) == -EINVAL);
    assert(uke_o82_touch_register(&panel.panel, &invalid) == -EINVAL);
    assert(uke_o82_touch_register(&panel.panel, &first) == 0);
    assert(first.count == 1 && first.latest == 0);
    o82_touch_state(&panel, false, true);
    assert(first.count == 2 && first.latest == 1);
    assert(uke_o82_touch_register(&panel.panel, &second) == 0);
    assert(second.count == 1 && second.latest == 1);
    o82_touch_state(&panel, true, false);
    assert(first.latest == 2 && second.latest == 2);
    o82_touch_state(&panel, false, true);
    assert(first.latest == 3 && second.latest == 3 && notifications == 3);
    uke_o82_touch_unregister(&panel.panel, &second);
    o82_touch_state(&panel, false, false);
    assert(first.latest == 2 && second.latest == 3);
    wait_callback = true;
    pthread_t writer, remover;
    assert(pthread_create(&writer, NULL, publish, NULL) == 0);
    mutex_lock(&barrier_lock);
    while (!entered) assert(pthread_cond_wait(&barrier_cond, &barrier_lock) == 0);
    mutex_unlock(&barrier_lock);
    assert(pthread_create(&remover, NULL, unsubscribe, NULL) == 0);
    mutex_lock(&barrier_lock);
    while (!unregister_entered) assert(pthread_cond_wait(&barrier_cond, &barrier_lock) == 0);
    assert(!atomic_load(&unregister_done));
    assert(pthread_mutex_trylock(&panel.touch_lock) == EBUSY);
    proceed = true;
    assert(pthread_cond_broadcast(&barrier_cond) == 0);
    mutex_unlock(&barrier_lock);
    assert(pthread_join(writer, NULL) == 0 && pthread_join(remover, NULL) == 0);
    assert(atomic_load(&unregister_done) && first.latest == 4);
    unsigned int count = first.count;
    o82_touch_state(&panel, false, true);
    assert(first.count == count && atomic64_read(&panel.touch_state) == 5);
    puts("Production panel notification: initial snapshot, exact readiness, reset generation and synchronous unsubscribe: PASS");
    return 0;
}
