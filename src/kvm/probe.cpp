// SPDX-License-Identifier: MIT
#include <csignal>
#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <linux/kvm.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#if defined(__aarch64__)
static void timeout_result(int) {
    constexpr char result[] = "{\"status\":\"timeout\",\"stage\":\"run\",\"guest_ran\":null}\n";
    const auto ignored = write(STDOUT_FILENO, result, sizeof(result) - 1);
    (void)ignored;
    _exit(124);
}
static int failure(const char *stage) {
    const int error = errno;
    std::fprintf(stderr, "%s: %s\n", stage, std::strerror(error));
    std::printf("{\"status\":\"error\",\"stage\":\"%s\",\"errno\":%d}\n", stage, error);
    return 3;
}
#endif

int main(int argc, char **) {
    if (argc != 1) {
        std::fputs("Usage: uke-kvm-probe (no arguments; ephemeral guest, no storage access)\n", stderr);
        return 64;
    }
#if !defined(__aarch64__)
    std::puts("{\"status\":\"unsupported-architecture\",\"guest_ran\":false}");
    return 3;
#else
    const int kvm = open("/dev/kvm", O_RDWR | O_CLOEXEC);
    if (kvm < 0) {
        if (errno != ENOENT && errno != ENODEV) return failure("open-kvm");
        std::puts("{\"status\":\"blocked-no-kvm\",\"guest_ran\":false}");
        return 2;
    }
    const int api = ioctl(kvm, KVM_GET_API_VERSION, 0);
    if (api < 0) return failure("api-version");
    if (api != KVM_API_VERSION) {
        errno = EPROTO;
        return failure("api-version");
    }
    const int vm = ioctl(kvm, KVM_CREATE_VM, 0);
    if (vm < 0) return failure("create-vm");
    const long page_size = sysconf(_SC_PAGESIZE);
    if (page_size != 4096 && page_size != 16384 && page_size != 65536) {
        errno = EINVAL;
        return failure("host-page-size");
    }
    if (ioctl(kvm, KVM_CHECK_EXTENSION, KVM_CAP_USER_MEMORY) <= 0) {
        errno = ENOTSUP;
        return failure("user-memory-capability");
    }
    void *memory = mmap(nullptr, static_cast<std::size_t>(page_size), PROT_READ | PROT_WRITE,
                        MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (memory == MAP_FAILED) return failure("guest-memory");
    // Write UKE2 to an unmapped MMIO address, then stop; no guest devices or disks.
    const std::uint32_t code[] = {
        0xd2a00400, 0x5288a641, 0x72aaa961, 0xb9000001, 0xd503207f, 0x14000000
    };
    std::memcpy(memory, code, sizeof(code));
    __builtin___clear_cache(static_cast<char *>(memory), static_cast<char *>(memory) + sizeof(code));
    kvm_userspace_memory_region region{};
    region.guest_phys_addr = 0x100000;
    region.memory_size = static_cast<std::uint64_t>(page_size);
    region.userspace_addr = reinterpret_cast<std::uintptr_t>(memory);
    if (ioctl(vm, KVM_SET_USER_MEMORY_REGION, &region) < 0) return failure("memory-slot");
    kvm_vcpu_init target{};
    if (ioctl(vm, KVM_ARM_PREFERRED_TARGET, &target) < 0) return failure("preferred-target");
    const int vcpu = ioctl(vm, KVM_CREATE_VCPU, 0);
    if (vcpu < 0) return failure("create-vcpu");
    if (ioctl(vcpu, KVM_ARM_VCPU_INIT, &target) < 0) return failure("vcpu-init");
    std::uint64_t pc = region.guest_phys_addr, pstate = 0x3c5;
    kvm_one_reg reg{};
    reg.id = KVM_REG_ARM64 | KVM_REG_SIZE_U64 | KVM_REG_ARM_CORE |
             KVM_REG_ARM_CORE_REG(regs.pc);
    reg.addr = reinterpret_cast<std::uintptr_t>(&pc);
    if (ioctl(vcpu, KVM_SET_ONE_REG, &reg) < 0) return failure("set-pc");
    reg.id = KVM_REG_ARM64 | KVM_REG_SIZE_U64 | KVM_REG_ARM_CORE |
             KVM_REG_ARM_CORE_REG(regs.pstate);
    reg.addr = reinterpret_cast<std::uintptr_t>(&pstate);
    if (ioctl(vcpu, KVM_SET_ONE_REG, &reg) < 0) return failure("set-pstate");
    const int bytes = ioctl(kvm, KVM_GET_VCPU_MMAP_SIZE, 0);
    if (bytes < 0) return failure("run-size");
    if (bytes < static_cast<int>(sizeof(kvm_run))) {
        errno = EPROTO;
        return failure("run-size");
    }
    auto *run = static_cast<kvm_run *>(mmap(nullptr, bytes, PROT_READ | PROT_WRITE,
                                          MAP_SHARED, vcpu, 0));
    if (run == MAP_FAILED) return failure("run-map");
    struct sigaction action{};
    action.sa_handler = timeout_result;
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGALRM, &action, nullptr) < 0) return failure("timeout-handler");
    alarm(10);
    if (ioctl(vcpu, KVM_RUN, 0) < 0) return failure("run");
    alarm(0);
    std::uint32_t value = 0;
    std::memcpy(&value, run->mmio.data, sizeof(value));
    if (run->exit_reason != KVM_EXIT_MMIO || !run->mmio.is_write ||
        run->mmio.phys_addr != 0x200000 || run->mmio.len != sizeof(value) ||
        value != 0x554b4532) {
        errno = EPROTO;
        return failure("guest-result");
    }
    std::puts("{\"status\":\"kvm-guest-pass\",\"guest_ran\":true,\"api_version\":12}");
    return 0;
#endif
}
