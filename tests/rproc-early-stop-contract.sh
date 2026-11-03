#!/usr/bin/env bash
# Actual remoteproc core stop ordering with host-only subdevice/DMA ledgers.
set -Eeuo pipefail
source_file=${1:?Pass prepared remoteproc_core.c}
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
cat > "$work/check.cpp" <<'CPP'
#include <cassert>
#include <cerrno>
#include <cstdio>
#define RPROC_RUNNING 2
#define RPROC_OFFLINE 0
struct device {};
struct rproc;
struct rproc_ops { int (*stop)(rproc *)=nullptr; int (*prepare_stop)(rproc *)=nullptr; };
struct model { int prepare_error=0,table_error=0,stop_error=0; unsigned int prepares=0,stops=0,sub_stops=0,tables=0,sub_unprepares=0; bool quiesced=false,removed_before_quiesce=false,expect_early=true,crashed=false; };
struct rproc { device dev; const rproc_ops *ops; model *test; int state=RPROC_RUNNING; const char *name="fixture"; bool boot_cleanup_pending=false; };
template<class... T> void dev_err(device *,const char *,T...) {}
template<class... T> void dev_info(device *,const char *,T...) {}
static int early(rproc *r) { auto &m=*r->test; m.prepares++; if(m.prepare_error) return m.prepare_error; m.quiesced=true; return 0; }
static int stop(rproc *r) { auto &m=*r->test; m.stops++; return m.stop_error; }
static void rproc_stop_subdevices(rproc *r,bool crashed) { auto &m=*r->test; m.sub_stops++; m.crashed=crashed; m.removed_before_quiesce |= m.expect_early && !m.quiesced; }
static int rproc_reset_rsc_table_on_stop(rproc *r) { r->test->tables++; return r->test->table_error; }
static void rproc_unprepare_subdevices(rproc *r) { r->test->sub_unprepares++; }
CPP
awk '/^static int rproc_stop\(.*\)$/ {emit=1} emit {print} emit && /^}/ {emit=0}' "$source_file" >> "$work/check.cpp"
cat >> "$work/check.cpp" <<'CPP'
int main() {
    rproc_ops ops{stop,early}; model m; rproc r{{},&ops,&m};
    m.prepare_error=-EACCES;
    assert(rproc_stop(&r,false)==-EACCES);
    assert(m.prepares==1 && !m.sub_stops && !m.tables && !m.stops && !m.sub_unprepares && r.state==RPROC_RUNNING);
    m.prepare_error=0; assert(rproc_stop(&r,false)==0);
    assert(m.prepares==2 && m.quiesced && m.sub_stops==1 && !m.removed_before_quiesce && m.stops==1 && m.sub_unprepares==1 && r.state==RPROC_OFFLINE);
    m=model{}; r.state=RPROC_RUNNING; m.table_error=-EBUSY;
    assert(rproc_stop(&r,true)==-EBUSY && m.crashed && m.quiesced && m.sub_stops==1 && !m.stops && !m.sub_unprepares && r.state==RPROC_RUNNING);
    m.table_error=0; assert(rproc_stop(&r,true)==0 && !m.removed_before_quiesce && m.stops==1 && m.sub_unprepares==1);
    m=model{}; r.state=RPROC_RUNNING; m.stop_error=-EIO;
    assert(rproc_stop(&r,false)==-EIO && !m.sub_unprepares && r.state==RPROC_RUNNING);
    m.stop_error=0; assert(rproc_stop(&r,false)==0 && !m.removed_before_quiesce && m.sub_unprepares==1);
    m=model{}; r.state=RPROC_RUNNING; ops.prepare_stop=nullptr; m.expect_early=false;
    assert(rproc_stop(&r,false)==0 && !m.prepares && m.sub_stops==1 && m.stops==1 && r.state==RPROC_OFFLINE);
    m=model{}; r.state=RPROC_RUNNING; ops.stop=nullptr; ops.prepare_stop=early;
    assert(rproc_stop(&r,false)==-EINVAL && !m.prepares && !m.sub_stops);
    puts("Actual remoteproc stop: early failure retains clients/table/resources; retry/crash/later errors and legacy ordering passed; host only");
}
CPP
"${CXX:-g++}" -std=c++20 -O1 -g -Wall -Wextra -Werror \
    -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer \
    "$work/check.cpp" -o "$work/check"
"$work/check"
