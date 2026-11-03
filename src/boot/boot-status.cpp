// SPDX-License-Identifier: MIT
// Read-only prerequisite inspection. This never installs or selects a boot entry.
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <chrono>
#include <thread>
namespace fs = std::filesystem;
namespace {
bool selected_kernel(const std::string& input) {
    const auto release = input.size() > 4 && input.compare(input.size() - 4, 4, "-kvm") == 0 ? input.substr(0, input.size() - 4) : input;
    const auto dash = release.find('-');
    if (release.size() < 128 && (release.rfind("7.2.", 0) == 0 || release.rfind("7.3.", 0) == 0) && dash > 4 && dash != std::string::npos) {
        const auto patch = release.substr(4, dash - 4);
        const auto revision = release.substr(dash + 1);
        if (!revision.empty() && ((release.rfind("7.3.", 0) == 0 && patch == "0") || patch.front() != '0') && revision.front() != '0' &&
            patch.find_first_not_of("0123456789") == std::string::npos &&
            revision.find_first_not_of("0123456789") == std::string::npos) return true;
    }
    for (const std::string version : {"7.2.9", "7.2.10"}) {
        if (release == version + "-senemos-uke") return true;
        const auto prefix = version + "-senemos.";
        if (release.rfind(prefix, 0) != 0) continue;
        const auto revision = release.substr(prefix.size());
        return !revision.empty() && release.size() < 128 &&
            revision.front() != '.' && revision.back() != '.' &&
            revision.find("..") == std::string::npos &&
            revision.find_first_not_of("0123456789.") == std::string::npos;
    }
    return false;
}
std::string read(const fs::path& path) {
    std::ifstream stream(path, std::ios::binary);
    if (!stream) return {};
    std::string result;
    char byte{};
    while (result.size() < 65536 && stream.get(byte)) result += byte;
    if (stream.get(byte)) throw std::runtime_error("Inspection input exceeds its size limit");
    return result;
}
bool compatible(const std::string& value, const std::string& wanted) {
    std::size_t begin = 0;
    while (begin < value.size()) {
        const auto end = value.find('\0', begin);
        if (end == std::string::npos) return false;
        if (value.substr(begin, end - begin) == wanted) return true;
        begin = end + 1;
    }
    return false;
}
bool present(const fs::path& root, const char* path) {
    return fs::is_directory(root / path);
}
}
int main(int argc, char** argv) {
    try {
        fs::path root = "/";
        bool cdc = false, require_tty = false, identity = false;
        unsigned wait_seconds = 0;
        if (argc == 2 && std::string(argv[1]) == "--help") {
            std::cout << "Usage: uke-boot-status [--root EXTRACTED_ROOT] [--identity | --cdc] [--require-tty] [--wait SECONDS]\n"
                         "Read-only Uke EFI/kernel/root command-line inspection.\n"
                         "Exit 0: all prerequisites observed; 2: prerequisites missing; 1: input error.\n";
            return 0;
        }
        for (int i = 1; i < argc; ++i) {
            const std::string option = argv[i];
            if (option == "--root" && i + 1 < argc) root = argv[++i];
            else if (option == "--cdc") cdc = true;
            else if (option == "--identity") identity = true;
            else if (option == "--require-tty") require_tty = true;
            else if (option == "--wait" && i + 1 < argc) {
                const std::string value = argv[++i];
                if (value.empty() || value.size() > 2 || value.find_first_not_of("0123456789") != std::string::npos)
                    throw std::runtime_error("Invalid wait");
                wait_seconds = std::stoul(value);
                if (wait_seconds > 30) throw std::runtime_error("Wait exceeds limit");
            } else throw std::runtime_error("Invalid arguments; use --help");
        }
        if (!cdc && (require_tty || wait_seconds)) throw std::runtime_error("CDC mode required");
        if (cdc && identity) throw std::runtime_error("Choose one inspection mode");
        if (!fs::is_directory(root)) throw std::runtime_error("Inspection root is missing");
        const auto dt = read(root / "sys/firmware/devicetree/base/compatible");
        auto release = read(root / "proc/sys/kernel/osrelease");
        if (!release.empty() && release.back() == '\n') release.pop_back();
        const auto cmdline = read(root / "proc/cmdline");
        const bool efi = present(root, "sys/firmware/efi");
        const bool uke = compatible(dt, "xiaomi,uke") && compatible(dt, "qcom,sm7675");
        const bool kernel = selected_kernel(release);
        auto boolean = [](bool value) { return value ? "true" : "false"; };
        if (identity) {
            std::cout << "{\"schema_version\":1,\"scope\":\"read-only-kernel-device-identity\",\"uke_compatible\":"
                      << boolean(uke) << ",\"selected_kernel_release\":" << boolean(kernel)
                      << ",\"hardware_acceptance_granted\":false}\n";
            return uke && kernel ? 0 : 2;
        }
        if (cdc) {
            const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(wait_seconds);
            unsigned controllers = 0;
            bool tty = false;
            do {
                controllers = 0;
                const auto udc = root / "sys/class/udc";
                if (fs::is_directory(udc)) {
                    for (const auto& entry : fs::directory_iterator(udc)) {
                        if (entry.is_directory()) ++controllers;
                        if (controllers > 16) throw std::runtime_error("UDC limit exceeded");
                    }
                }
                tty = fs::is_character_file(root / "dev/ttyGS0");
                if (!uke || !kernel || (controllers == 1 && (!require_tty || tty))) break;
                if (std::chrono::steady_clock::now() >= deadline) break;
                std::this_thread::sleep_for(std::chrono::milliseconds(200));
            } while (true);
            std::cout << "{\"schema_version\":1,\"scope\":\"read-only-cdc-prerequisites\","
                      << "\"uke_compatible\":" << boolean(uke)
                      << ",\"selected_kernel_release\":" << boolean(kernel)
                      << ",\"single_udc_present\":" << boolean(controllers == 1)
                      << ",\"tty_gs0_present\":" << boolean(tty)
                      << ",\"usb_enumeration_tested\":false,\"hardware_acceptance_granted\":false}\n";
            return uke && kernel && controllers == 1 && (!require_tty || tty) ? 0 : 2;
        }
        bool root_selected = false;
        std::size_t begin = 0;
        while (begin < cmdline.size()) {
            const auto end = cmdline.find_first_of(" \t\r\n", begin);
            const auto argument = cmdline.substr(begin, end - begin);
            if (argument == "root=LABEL=UKE_LINUX" || argument == "root=PARTLABEL=linux" ||
                argument == "root=PARTLABEL=uke_linux" || argument == "root=PARTLABEL=userdata") root_selected = true;
            else if (argument.rfind("root=", 0) == 0) root_selected = false;
            if (end == std::string::npos) break;
            begin = end + 1;
        }
        std::cout << "{\"schema_version\":1,\"scope\":\"read-only-current-environment\","
                  << "\"efi_present\":" << boolean(efi)
                  << ",\"uke_compatible\":" << boolean(uke)
                  << ",\"selected_kernel_release\":" << boolean(kernel)
                  << ",\"uke_root_command_line\":" << boolean(root_selected)
                  << ",\"storage_verified\":false,\"hardware_acceptance_granted\":false}\n";
        return efi && uke && kernel && root_selected ? 0 : 2;
    } catch (const std::exception&) {
        // Never print captured device strings, private host paths or identifiers.
        std::cerr << "Uke boot inspection failed; check the input root and --help\n";
        return 1;
    }
}
