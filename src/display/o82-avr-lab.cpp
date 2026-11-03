// SPDX-License-Identifier: MIT
// Run on an unused VT with the bounded kernel experiment explicitly enabled.
#include <xf86drm.h>
#include <xf86drmMode.h>
#include <drm_fourcc.h>
#include <cassert>
#include <cerrno>
#include <csignal>
#include <cstdint>
#include <cstring>
#include <fcntl.h>
#include <fstream>
#include <iostream>
#include <poll.h>
#include <stdexcept>
#include <string>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

static volatile sig_atomic_t stopped;
static void stop(int) { stopped = 1; }
static uint64_t now() {
    timespec t{};
    if (clock_gettime(CLOCK_MONOTONIC, &t)) throw std::runtime_error("clock_gettime");
    return uint64_t(t.tv_sec) * 1000000000 + t.tv_nsec;
}
static uint64_t interval(unsigned frame, bool wide) {
    if (wide) {
        constexpr unsigned rates[] = {144,120,90,60,50,48,30,30,48,50,60,90,120,144};
        if (frame < 336) return 1000000000ULL / rates[frame / 24];
        return 7100000ULL + (frame * 7919U % 25000) * 1000ULL;
    }
    constexpr uint64_t ns[] = {8340000, 8400000, 8360000, 8380000, 8350000, 8390000};
    return ns[frame % 6];
}
static bool exact_base(const drmModeModeInfo &m, bool wide) {
    const bool horizontal = wide ?
        m.clock == 1097712 && m.hsync_start == 3236 && m.hsync_end == 3268 && m.htotal == 3300 :
        m.clock == 967428 && m.hsync_start == 3426 && m.hsync_end == 3458 && m.htotal == 3490;
    return horizontal && m.hdisplay == 3200 && m.vdisplay == 2136 &&
        m.vsync_start == 2162 && m.vsync_end == 2164 && m.vtotal == 2310 &&
        !m.flags && !m.hskew && !m.vscan;
}
static void check(int result, const char *operation) {
    if (result < 0) throw std::runtime_error(std::string(operation) + ": " +
        strerror(result == -1 ? errno : -result));
}
static uint32_t property(int fd, uint32_t object, uint32_t type, const char *name) {
    auto *list = drmModeObjectGetProperties(fd, object, type);
    if (!list) throw std::runtime_error("get properties");
    uint32_t id = 0;
    for (uint32_t i = 0; i < list->count_props; ++i) {
        auto *p = drmModeGetProperty(fd, list->props[i]);
        if (p && !strcmp(p->name, name)) id = p->prop_id;
        drmModeFreeProperty(p);
    }
    drmModeFreeObjectProperties(list);
    if (!id) throw std::runtime_error(std::string("missing property: ") + name);
    return id;
}
struct Request {
    int fd;
    drmModeAtomicReq *req = drmModeAtomicAlloc();
    explicit Request(int device) : fd(device) { if (!req) throw std::bad_alloc(); }
    ~Request() { drmModeAtomicFree(req); }
    void add(uint32_t object, uint32_t type, const char *name, uint64_t value) {
        check(drmModeAtomicAddProperty(req, object, property(fd, object, type, name), value), name);
    }
    void commit(uint32_t flags = 0, void *data = nullptr) {
        check(drmModeAtomicCommit(fd, req, flags, data), "atomic commit");
    }
};
struct Buffer {
    int fd;
    drm_mode_create_dumb dumb{};
    uint32_t fb = 0;
    void *map = MAP_FAILED;
    explicit Buffer(int device) : fd(device) {
        dumb.width = 3200; dumb.height = 2136; dumb.bpp = 32;
        check(drmIoctl(fd, DRM_IOCTL_MODE_CREATE_DUMB, &dumb), "create dumb");
        try {
            uint32_t handles[4] = {dumb.handle}, pitches[4] = {dumb.pitch}, offsets[4] = {};
            check(drmModeAddFB2(fd, 3200, 2136, DRM_FORMAT_XRGB8888, handles, pitches, offsets, &fb, 0), "add fb");
            drm_mode_map_dumb mapping{}; mapping.handle = dumb.handle;
            check(drmIoctl(fd, DRM_IOCTL_MODE_MAP_DUMB, &mapping), "map dumb");
            map = mmap(nullptr, dumb.size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, mapping.offset);
            if (map == MAP_FAILED) throw std::runtime_error("mmap");
            memset(map, 0x50, dumb.size);
        } catch (...) { clear(); throw; }
    }
    void clear() {
        if (map != MAP_FAILED) { munmap(map, dumb.size); map = MAP_FAILED; }
        if (fb) { drmModeRmFB(fd, fb); fb = 0; }
        if (dumb.handle) {
            drm_mode_destroy_dumb destroy{}; destroy.handle = dumb.handle;
            drmIoctl(fd, DRM_IOCTL_MODE_DESTROY_DUMB, &destroy); dumb.handle = 0;
        }
    }
    ~Buffer() { clear(); }
    void draw(unsigned frame) {
        // The same binary frame ID on each half permits external cadence comparison.
        for (unsigned y = 64; y < 192; ++y) {
            auto *row = reinterpret_cast<uint32_t *>(static_cast<char *>(map) + y * dumb.pitch);
            for (unsigned half = 0; half < 2; ++half)
                for (unsigned x = 0; x < 1600; ++x)
                    row[half * 1600 + x] = (frame & (1U << (x / 100))) ? 0xffffff : 0;
        }
    }
};
struct Event {
    bool done = false;
    unsigned sequence = 0;
    uint64_t ns = 0;
};
static void flip(int, unsigned sequence, unsigned sec, unsigned usec, void *data) {
    auto &event = *static_cast<Event *>(data);
    event = {true, sequence, uint64_t(sec) * 1000000000 + uint64_t(usec) * 1000};
}
static void snapshot(const char *phase) {
    std::ifstream status("/sys/kernel/debug/dri/1/encoder-0/status");
    std::cerr << phase << '\n' << status.rdbuf() << '\n';
}
static int run(int fd, bool avr) {
    std::ifstream parameter("/sys/module/msm/parameters/o82_vrr_test_min_hz");
    unsigned minimum = 0;
    if (!(parameter >> minimum) || (minimum != 119 && minimum != 30))
        throw std::runtime_error("O82 experiment parameter 119 or 30 required");
    const bool wide = minimum == 30;
    check(drmSetClientCap(fd, DRM_CLIENT_CAP_UNIVERSAL_PLANES, 1), "universal planes");
    check(drmSetClientCap(fd, DRM_CLIENT_CAP_ATOMIC, 1), "atomic capability");
    check(drmSetMaster(fd), "DRM master (switch to an unused VT)");
    auto *resources = drmModeGetResources(fd);
    if (!resources) throw std::runtime_error("KMS resources");
    uint32_t connector = 0, crtc = 0, plane = 0;
    unsigned crtc_index = 0;
    drmModeModeInfo mode{}, rejected_mode{};
    for (int i = 0; i < resources->count_connectors; ++i) {
        auto *c = drmModeGetConnector(fd, resources->connectors[i]);
        if (c && c->connection == DRM_MODE_CONNECTED && c->connector_type == DRM_MODE_CONNECTOR_DSI)
            for (int j = 0; j < c->count_modes; ++j) {
                if (exact_base(c->modes[j], wide)) { connector = c->connector_id; mode = c->modes[j]; }
                if (c->modes[j].clock == 804988 && c->modes[j].vtotal == 2310)
                    rejected_mode = c->modes[j];
            }
        drmModeFreeConnector(c);
    }
    if (resources->count_crtcs == 1) crtc = resources->crtcs[0];
    drmModeFreeResources(resources);
    if (!connector || !crtc || !rejected_mode.clock)
        throw std::runtime_error("exact O82 modes / single CRTC required");
    if (wide) { rejected_mode = mode; ++rejected_mode.clock; }
    auto *planes = drmModeGetPlaneResources(fd);
    if (!planes) throw std::runtime_error("plane resources");
    for (uint32_t i = 0; i < planes->count_planes; ++i) {
        auto *p = drmModeGetPlane(fd, planes->planes[i]);
        if (p && (p->possible_crtcs & (1U << crtc_index))) {
            auto *props = drmModeObjectGetProperties(fd, p->plane_id, DRM_MODE_OBJECT_PLANE);
            const auto type = property(fd, p->plane_id, DRM_MODE_OBJECT_PLANE, "type");
            if (props) {
                for (uint32_t j = 0; j < props->count_props; ++j)
                    if (props->props[j] == type && props->prop_values[j] == DRM_PLANE_TYPE_PRIMARY)
                        plane = p->plane_id;
                drmModeFreeObjectProperties(props);
            }
        }
        drmModeFreePlane(p);
    }
    drmModeFreePlaneResources(planes);
    if (!plane) throw std::runtime_error("primary plane");
    Buffer buffers[] = {Buffer(fd), Buffer(fd)};
    uint32_t blob = 0;
    check(drmModeCreatePropertyBlob(fd, &mode, sizeof(mode), &blob), "mode blob");
    bool active = false;
    const auto cleanup = [&] {
        if (active) {
            Request off(fd);
            off.add(crtc, DRM_MODE_OBJECT_CRTC, "VRR_ENABLED", 0);
            off.add(plane, DRM_MODE_OBJECT_PLANE, "FB_ID", 0);
            off.add(plane, DRM_MODE_OBJECT_PLANE, "CRTC_ID", 0);
            off.add(connector, DRM_MODE_OBJECT_CONNECTOR, "CRTC_ID", 0);
            off.add(crtc, DRM_MODE_OBJECT_CRTC, "ACTIVE", 0);
            off.add(crtc, DRM_MODE_OBJECT_CRTC, "MODE_ID", 0);
            off.commit(DRM_MODE_ATOMIC_ALLOW_MODESET);
        }
    };
    try {
        const auto populate = [&](Request &request, uint32_t mode_blob, bool vrr) {
            request.add(connector, DRM_MODE_OBJECT_CONNECTOR, "CRTC_ID", crtc);
            request.add(crtc, DRM_MODE_OBJECT_CRTC, "ACTIVE", 1);
            request.add(crtc, DRM_MODE_OBJECT_CRTC, "MODE_ID", mode_blob);
            request.add(crtc, DRM_MODE_OBJECT_CRTC, "VRR_ENABLED", vrr);
            request.add(plane, DRM_MODE_OBJECT_PLANE, "FB_ID", buffers[0].fb);
            request.add(plane, DRM_MODE_OBJECT_PLANE, "CRTC_ID", crtc);
            for (auto *name : {"SRC_X", "SRC_Y", "CRTC_X", "CRTC_Y"})
                request.add(plane, DRM_MODE_OBJECT_PLANE, name, 0);
            request.add(plane, DRM_MODE_OBJECT_PLANE, "SRC_W", 3200ULL << 16);
            request.add(plane, DRM_MODE_OBJECT_PLANE, "SRC_H", 2136ULL << 16);
            request.add(plane, DRM_MODE_OBJECT_PLANE, "CRTC_W", 3200);
            request.add(plane, DRM_MODE_OBJECT_PLANE, "CRTC_H", 2136);
        };
        Request initial(fd); populate(initial, blob, false);
        initial.commit(DRM_MODE_ATOMIC_TEST_ONLY | DRM_MODE_ATOMIC_ALLOW_MODESET);
        uint32_t rejected_blob = 0;
        check(drmModeCreatePropertyBlob(fd, &rejected_mode, sizeof(rejected_mode), &rejected_blob), "90 Hz blob");
        Request invalid(fd); populate(invalid, rejected_blob, true);
        const int rejected = drmModeAtomicCommit(fd, invalid.req,
            DRM_MODE_ATOMIC_TEST_ONLY | DRM_MODE_ATOMIC_ALLOW_MODESET, nullptr);
        drmModeDestroyPropertyBlob(fd, rejected_blob);
        if (rejected != -EINVAL)
            throw std::runtime_error("unsupported VRR test-only request did not fail with EINVAL");
        std::cerr << (wide ? "Custom clock" : "90 Hz") << " VRR test-only: rejected with EINVAL\n";
        initial.commit(DRM_MODE_ATOMIC_ALLOW_MODESET); active = true;
        std::cout << "phase,frame,requested_interval_ns,submit_ns,drm_event_ns,complete_ns,sequence\n";
        unsigned frame = 0;
        for (unsigned phase = 0; phase < 3 && !stopped; ++phase) {
            Request vrr(fd); vrr.add(crtc, DRM_MODE_OBJECT_CRTC, "VRR_ENABLED", avr && phase == 1);
            vrr.commit();
            uint64_t submitted = now();
            const auto fb_property = property(fd, plane, DRM_MODE_OBJECT_PLANE, "FB_ID");
            for (unsigned i = 0; i < (wide ? 432U : 240U) && !stopped; ++i, ++frame) {
                auto &buffer = buffers[(frame + 1) % 2]; buffer.draw(frame);
                const uint64_t deadline = submitted + interval(i, wide);
                timespec t{time_t(deadline / 1000000000), long(deadline % 1000000000)};
                int slept;
                do { slept = clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &t, nullptr); }
                while (slept == EINTR && !stopped);
                if (slept && slept != EINTR) throw std::runtime_error("clock_nanosleep");
                if (stopped) break;
                Event event;
                Request update(fd);
                check(drmModeAtomicAddProperty(update.req, plane, fb_property, buffer.fb), "FB_ID");
                submitted = now();
                update.commit(DRM_MODE_ATOMIC_NONBLOCK | DRM_MODE_PAGE_FLIP_EVENT, &event);
                drmEventContext context{}; context.version = 2; context.page_flip_handler = flip;
                while (!event.done) {
                    pollfd p{fd, POLLIN, 0};
                    int result = poll(&p, 1, 1000);
                    if (result < 0 && errno == EINTR) continue;
                    if (result <= 0 || !(p.revents & POLLIN)) throw std::runtime_error("page flip timeout");
                    check(drmHandleEvent(fd, &context), "DRM event");
                }
                std::cout << phase << ',' << frame << ',' << interval(i, wide) << ',' << submitted << ','
                    << event.ns << ',' << now() << ',' << event.sequence << '\n';
                if (i == 60) snapshot(avr && phase == 1 ? "avr-on" : "fixed");
                if (phase == 1 && i == 119) {
                    timespec pause{0, 250000000}; nanosleep(&pause, nullptr);
                    snapshot("avr-pause-250ms"); submitted = now();
                }
            }
        }
        cleanup(); active = false; snapshot("disabled");
        drmModeDestroyPropertyBlob(fd, blob);
    } catch (...) {
        try { cleanup(); } catch (const std::exception &e) { std::cerr << "cleanup: " << e.what() << '\n'; }
        drmModeDestroyPropertyBlob(fd, blob); throw;
    }
    return 0;
}
int main(int argc, char **argv) {
    if (argc == 2 && !strcmp(argv[1], "--self-test")) {
        drmModeModeInfo m{};
        m.clock=967428; m.hdisplay=3200; m.hsync_start=3426; m.hsync_end=3458; m.htotal=3490;
        m.vdisplay=2136; m.vsync_start=2162; m.vsync_end=2164; m.vtotal=2310;
        assert(exact_base(m,false)); m.flags=DRM_MODE_FLAG_INTERLACE; assert(!exact_base(m,false));
        m.flags=0; ++m.htotal; assert(!exact_base(m,false));
        m.htotal=3300; m.hsync_start=3236; m.hsync_end=3268; m.clock=1097712;
        assert(exact_base(m,true)); assert(!exact_base(m,false));
        for (unsigned i=0; i<12; ++i) {
            assert(interval(i,false)*120 >= 1000000000ULL);
            assert(interval(i,false)*119 <= 1000000000ULL);
            assert(interval(i,false)==interval(i+6,false));
        }
        for (unsigned i=0; i<432; ++i)
            assert(interval(i,true)>=6944444 && interval(i,true)<=33333333);
        std::cout << "O82 lab mode guard and bounded schedule passed\n"; return 0;
    }
    if ((argc != 2 && argc != 3) || strcmp(argv[1], "--run") ||
        (argc == 3 && strcmp(argv[2], "fixed"))) {
        std::cerr << "Usage: o82-avr-lab --self-test|--run [fixed] (unused VT; exact O82 experiment)\n"; return 2;
    }
    signal(SIGINT, stop); signal(SIGTERM, stop);
    const int fd = open("/dev/dri/by-path/platform-ae01000.display-controller-card", O_RDWR | O_CLOEXEC);
    if (fd < 0) { perror("KMS device"); return 1; }
    int result = 1;
    try { result = run(fd, argc == 2); }
    catch (const std::exception &e) { std::cerr << e.what() << '\n'; }
    close(fd); return result;
}
