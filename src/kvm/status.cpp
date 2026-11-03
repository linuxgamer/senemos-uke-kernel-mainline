// SPDX-License-Identifier: MIT
#include <cerrno>
#include <cstdio>
#include <fcntl.h>
#include <fstream>
#include <iostream>
#include <iterator>
#include <linux/kvm.h>
#include <string>
#include <sys/ioctl.h>
#include <sys/utsname.h>
#include <sys/wait.h>
#include <unistd.h>

static std::string read(const std::string &path) {
    std::ifstream input(path);
    return {std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>()};
}
static void quoted(const std::string &text) {
    std::cout << '"';
    for (unsigned char c : text) {
        if (c == '"' || c == '\\') std::cout << '\\' << c;
        else if (c < 0x20) {
            constexpr char hex[] = "0123456789abcdef";
            std::cout << "\\u00" << hex[c >> 4] << hex[c & 15];
        } else std::cout << c;
    }
    std::cout << '"';
}
int main(int argc, char **) {
    if (argc != 1) {
        std::fputs("Usage: uke-el2-status (read-only; never runs a guest)\n", stderr);
        return 64;
    }
    utsname identity{};
    if (uname(&identity) < 0) return 3;
    const std::string release = identity.release;
    auto config = read("/usr/lib/modules/" + release + "/config");
    if (config.empty()) config = read("/boot/config-" + release);
    std::string logs;
    bool journal_available = false;
    if (FILE *journal = popen("journalctl -k -b --no-pager -o cat 2>/dev/null", "r")) {
        char line[4096];
        while (std::fgets(line, sizeof(line), journal)) {
            const std::string row = line;
            if (row.find("All CPU(s) started at EL") != std::string::npos ||
                row.find("HYP mode not available") != std::string::npos ||
                row.find("kvm [") != std::string::npos) logs += row;
        }
        const int status = pclose(journal);
        journal_available = status >= 0 && WIFEXITED(status) && WEXITSTATUS(status) == 0;
    }
    const bool el1 = logs.find("All CPU(s) started at EL1") != std::string::npos;
    const bool el2 = logs.find("All CPU(s) started at EL2") != std::string::npos;
    const char *entry = el1 && el2 ? "conflicting" : el2 ? "EL2" : el1 ? "EL1" : "unknown";
    const int kvm = open("/dev/kvm", O_RDWR | O_CLOEXEC);
    const int open_error = kvm < 0 ? errno : 0;
    const int api = kvm < 0 ? -1 : ioctl(kvm, KVM_GET_API_VERSION, 0);
    const int api_error = kvm >= 0 && api < 0 ? errno : 0;
    if (kvm >= 0) close(kvm);
    const auto enabled = [&](const char *flag) {
        return config.empty() ? "null" : config.find(std::string(flag) + "=y\n") != std::string::npos ? "true" : "false";
    };
    std::cout << "{\"kernel_release\":"; quoted(release);
    std::cout << ",\"cmdline\":"; quoted(read("/proc/cmdline"));
    std::cout << ",\"cpu_present\":"; quoted(read("/sys/devices/system/cpu/present"));
    std::cout << ",\"cpu_online\":"; quoted(read("/sys/devices/system/cpu/online"));
    std::cout << ",\"boot_entry_el\":"; quoted(entry);
    std::cout << ",\"journal_available\":" << (journal_available ? "true" : "false")
              << ",\"kvm_open_errno\":" << open_error << ",\"kvm_api_version\":" << api
              << ",\"kvm_api_errno\":" << api_error << ",\"config_kvm\":" << enabled("CONFIG_KVM")
              << ",\"config_el2_require\":" << enabled("CONFIG_QCOM_UKE_EL2_ENTRY")
              << ",\"config_firmware_exit\":" << enabled("CONFIG_QCOM_UKE_GUNYAH_EXIT")
              << ",\"config_binder\":" << enabled("CONFIG_ANDROID_BINDER_IPC")
              << ",\"config_binderfs\":" << enabled("CONFIG_ANDROID_BINDERFS")
              << ",\"guest_status\":\"not-run\",\"waydroid_status\":\"not-run\",\"boot_evidence\":";
    quoted(logs);
    std::cout << "}\n";
    return std::cout ? 0 : 3;
}
