// SPDX-License-Identifier: MIT
// Synthetic ioctl tests; these do not run a guest or establish EL2 support.
#include <cassert>
#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <cstdarg>
#include <fcntl.h>
#include <initializer_list>
#include <linux/kvm.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

static long test_page = 4096;
static bool bad_api = false, bad_result = false;
alignas(65536) static unsigned char guest_memory[65536];
static kvm_run run_area{};
static int test_open(const char *name, int flags, ...) {
    assert(std::strcmp(name, "/dev/kvm") == 0);
    assert(flags == (O_RDWR | O_CLOEXEC));
    return 10;
}
static long test_sysconf(int name) {
    assert(name == _SC_PAGESIZE);
    return test_page;
}
static void *test_mmap(void *, std::size_t length, int, int flags, int fd, off_t) {
    if (flags & MAP_ANONYMOUS) {
        assert(fd == -1 && length == static_cast<std::size_t>(test_page));
        return guest_memory;
    }
    assert(fd == 12 && length == 4096);
    return &run_area;
}
static unsigned test_alarm(unsigned seconds) {
    assert(seconds == 0 || seconds == 10);
    return 0;
}
static int test_ioctl(int fd, unsigned long request, ...) {
    va_list arguments;
    va_start(arguments, request);
    int result = 0;
    switch (request) {
    case KVM_GET_API_VERSION:
        assert(fd == 10);
        if (bad_api) { errno = EACCES; result = -1; }
        else result = KVM_API_VERSION;
        break;
    case KVM_CHECK_EXTENSION: result = 1; break;
    case KVM_CREATE_VM: result = 11; break;
    case KVM_CREATE_VCPU: result = 12; break;
    case KVM_GET_VCPU_MMAP_SIZE: result = 4096; break;
    case KVM_SET_USER_MEMORY_REGION: {
        const auto *region = va_arg(arguments, kvm_userspace_memory_region *);
        assert(fd == 11 && region->guest_phys_addr == 0x100000);
        assert(region->memory_size == static_cast<std::uint64_t>(test_page));
        assert(region->userspace_addr % static_cast<std::uint64_t>(test_page) == 0);
        break;
    }
    case KVM_ARM_PREFERRED_TARGET:
    case KVM_ARM_VCPU_INIT:
    case KVM_SET_ONE_REG: break;
    case KVM_RUN:
        assert(fd == 12);
        run_area.exit_reason = KVM_EXIT_MMIO;
        run_area.mmio.phys_addr = bad_result ? 0x300000 : 0x200000;
        run_area.mmio.is_write = 1;
        run_area.mmio.len = 4;
        {
            const std::uint32_t value = 0x554b4532;
            std::memcpy(run_area.mmio.data, &value, sizeof(value));
        }
        break;
    default: assert(false);
    }
    va_end(arguments);
    return result;
}

#define main probe_main
#define open test_open
#define sysconf test_sysconf
#define mmap test_mmap
#define ioctl test_ioctl
#define alarm test_alarm
#include "../src/kvm/probe.cpp"
#undef main
#undef open
#undef sysconf
#undef mmap
#undef ioctl
#undef alarm

int main() {
    for (long page : {4096L, 16384L, 65536L}) {
        test_page = page;
        assert(probe_main(1, nullptr) == 0);
    }
    test_page = 8192;
    assert(probe_main(1, nullptr) == 3 && errno == EINVAL);
    test_page = 4096;
    bad_api = true;
    assert(probe_main(1, nullptr) == 3 && errno == EACCES);
    bad_api = false;
    bad_result = true;
    assert(probe_main(1, nullptr) == 3 && errno == EPROTO);
    assert(probe_main(2, nullptr) == 64);
    std::puts("Synthetic KVM ABI: three page sizes and four refusal paths passed");
}
