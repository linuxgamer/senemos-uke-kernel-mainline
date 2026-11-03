// SPDX-License-Identifier: MIT
// AArch64-only, dependency-free perf smoke test; Linux v7.3 asm-generic UAPI.
// Kept outside the target RPM payload. No firmware policy or storage writes.
#ifndef __aarch64__
#error This diagnostic uses the AArch64 Linux syscall ABI.
#endif
using u32 = __UINT32_TYPE__;
using u64 = __UINT64_TYPE__;
static_assert(sizeof(long) == 8);
struct PerfAttrV0 {
    u32 type, size;
    u64 config, sample_period, sample_type, read_format, flags;
    u32 wakeup, bp_type;
    u64 config1;
};
static_assert(sizeof(PerfAttrV0) == 64);

static long call(long number, long a = 0, long b = 0, long c = 0,
                 long d = 0, long e = 0, long f = 0)
{
    register long x8 asm("x8") = number;
    register long x0 asm("x0") = a;
    register long x1 asm("x1") = b;
    register long x2 asm("x2") = c;
    register long x3 asm("x3") = d;
    register long x4 asm("x4") = e;
    register long x5 asm("x5") = f;
    asm volatile("svc 0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3), "r"(x4), "r"(x5) : "memory", "cc");
    return x0;
}
static void text(const char *s)
{
    unsigned n = 0;
    while (s[n]) ++n;
    call(64, 1, reinterpret_cast<long>(s), n);
}
static void number(u64 value)
{
    char buf[21];
    unsigned n = 21;
    do { buf[--n] = '0' + value % 10; value /= 10; } while (value);
    call(64, 1, reinterpret_cast<long>(buf + n), 21 - n);
}
static int error(const char *stage, long result)
{
    text(stage); text(" errno="); number(result < 0 ? -result : 0); text("\n");
    return 2;
}
struct Events {
    long fd[8];
    Events() { for (auto &f : fd) f = -1; }
    ~Events() { for (auto f : fd) if (f >= 0) call(57, f); }
};
static int run()
{
    const char *path = "/sys/bus/event_source/devices/sm7675_llcc/type";
    long fd = call(56, -100, reinterpret_cast<long>(path));
    if (fd < 0) return error("type_open", fd);
    char buf[16];
    long n = call(63, fd, reinterpret_cast<long>(buf), sizeof(buf));
    call(57, fd);
    if (n < 2 || n > 11 || buf[n - 1] != '\n') return error("type_read", n);
    u64 type = 0;
    for (long i = 0; i < n - 1; ++i) {
        if (buf[i] < '0' || buf[i] > '9') return error("type_format", 0);
        type = type * 10 + buf[i] - '0';
    }
    if (!type || type > 0xffffffffULL) return error("type_range", 0);
    Events events;
    PerfAttrV0 attr{};
    attr.type = type; attr.size = sizeof(attr); attr.config = 0x1000;
    attr.flags = 1 | 4; // disabled, pinned; all exclude flags remain zero.
    for (unsigned cpu = 0; cpu < 8; ++cpu) {
        events.fd[cpu] = call(241, reinterpret_cast<long>(&attr), -1, cpu, -1, 8);
        if (events.fd[cpu] < 0) return error("event_open", events.fd[cpu]);
        long r = call(29, events.fd[cpu], 0x2400); // PERF_EVENT_IOC_ENABLE.
        if (r < 0) return error("event_enable", r);
    }
    static volatile u64 data[2 * 1024 * 1024];
    u64 before[8], after[8];
    for (unsigned cpu = 0; cpu < 8; ++cpu)
        if (call(63, events.fd[cpu], reinterpret_cast<long>(&before[cpu]), 8) != 8)
            return error("initial_count", 0);
    for (unsigned cpu = 0; cpu < 8; ++cpu) {
        u64 mask = 1ULL << cpu;
        long r = call(122, 0, sizeof(mask), reinterpret_cast<long>(&mask));
        if (r < 0) return error("affinity", r);
        for (unsigned pass = 0; pass < 2; ++pass)
            for (unsigned i = 0; i < sizeof(data) / sizeof(data[0]); i += 8)
                data[i] = data[i] + i + cpu + pass;
    }
    u64 total = 0;
    for (unsigned cpu = 0; cpu < 8; ++cpu) {
        if (call(29, events.fd[cpu], 0x2401) < 0) return error("event_disable", 0);
        if (call(63, events.fd[cpu], reinterpret_cast<long>(&after[cpu]), 8) != 8 ||
            after[cpu] < before[cpu] || (after[cpu] & 7)) return error("count_contract", 0);
        text("cpu="); number(cpu); text(" scaled_delta="); number(after[cpu] - before[cpu]); text("\n");
        total += after[cpu] - before[cpu];
    }
    struct { long seconds, ns; } delay{0, 100000000};
    if (call(101, reinterpret_cast<long>(&delay)) < 0) return error("pause", 0);
    for (unsigned cpu = 0; cpu < 8; ++cpu) {
        u64 stopped;
        if (call(63, events.fd[cpu], reinterpret_cast<long>(&stopped), 8) != 8 || stopped != after[cpu])
            return error("stopped_count", 0);
    }
    if (!total) return error("no_counts", 0);
    text("PASS: scaled counts and stopped-count retention; units, mapping and wrap remain unqualified\n");
    return 0;
}
extern "C" [[noreturn]] void _start()
{
    int result = run();
    call(93, result);
    __builtin_unreachable();
}
