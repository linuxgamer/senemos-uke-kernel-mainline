// SPDX-License-Identifier: MIT
// Offline filesystem expansion only; the partition table is never an output.
#include "userdata-grow.hpp"
#include "offline/io.hpp"
#include <cerrno>
#include <cstring>
#include <filesystem>
#include <fcntl.h>
#include <iostream>
#include <linux/fs.h>
#include <sstream>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <sys/wait.h>
#include <unistd.h>

namespace fs = std::filesystem;
using uke::offline::read;
static void require(bool value, const char *reason) { if (!value) throw std::runtime_error(reason); }
static void run(const char *tool, const char *option, const std::string &device) {
    const auto pid = fork();
    require(pid >= 0, "cannot start filesystem tool");
    if (!pid) {
        const int input = open("/dev/null", O_RDONLY);
        if (input < 0 || dup2(input, STDIN_FILENO) < 0) _exit(126);
        if (option) execl(tool, tool, option, device.c_str(), static_cast<char *>(nullptr));
        else execl(tool, tool, device.c_str(), static_cast<char *>(nullptr));
        _exit(127);
    }
    int status = 0;
    pid_t waited;
    do { waited = waitpid(pid, &status, 0); } while (waited < 0 && errno == EINTR);
    require(waited == pid && WIFEXITED(status) && WEXITSTATUS(status) == 0, "filesystem tool failed; growth stopped");
}
static uke::userdata::Header header(int fd, off_t offset) {
    uke::userdata::Header result{};
    require(pread(fd, result.data(), result.size(), offset) == static_cast<ssize_t>(result.size()), "cannot read F2FS superblock");
    return result;
}
static void unmounted(const std::string &number) {
    std::istringstream lines(read("/proc/self/mountinfo", 1024 * 1024));
    require(!lines.str().empty(), "mount table unavailable");
    std::string line;
    while (std::getline(lines, line)) {
        std::istringstream fields(line);
        std::string id, parent, device;
        require(bool(fields >> id >> parent >> device), "invalid mount table");
        require(device != number, "userdata is mounted; offline growth refused");
    }
}
int main(int argc, char **argv) {
    try {
        require(argc == 2 && geteuid() == 0 && fs::exists("/etc/initrd-release"), "requires the native initrd as root");
        require(uke::offline::compatible(read("/sys/firmware/devicetree/base/compatible")), "foreign board refused");
        unsigned roots = 0;
        std::istringstream arguments(read("/proc/cmdline"));
        for (std::string argument; arguments >> argument; ) if (argument.rfind("root=", 0) == 0) {
            require(argument == "root=PARTLABEL=userdata", "wrong root selector"); ++roots;
        }
        require(roots == 1, "ambiguous root selector");
        const auto device = fs::canonical(argv[1]).string();
        require(device == fs::canonical("/dev/disk/by-partlabel/userdata").string(), "wrong userdata link");
        const int fd = open(device.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
        require(fd >= 0, "cannot open userdata");
        struct stat st{};
        std::uint64_t bytes = 0;
        int readonly = 1;
        require(fstat(fd, &st) == 0 && S_ISBLK(st.st_mode) && ioctl(fd, BLKGETSIZE64, &bytes) == 0 &&
                ioctl(fd, BLKROGET, &readonly) == 0 && !readonly, "userdata is not a writable block device");
        const auto number = std::to_string(major(st.st_rdev)) + ":" + std::to_string(minor(st.st_rdev));
        const auto sys = fs::canonical("/sys/dev/block/" + number);
        const auto path = sys.string();
        require(path.find("/1d84000.ufshc/") != std::string::npos && path.find("/virtual/block/") == std::string::npos &&
                fs::exists(sys / "partition") && fs::is_empty(sys / "holders"), "foreign or held partition refused");
        const auto metadata = "\n" + read((sys / "uevent").string());
        require(metadata.find("\nPARTNAME=userdata\n") != std::string::npos, "partition label mismatch");
        unmounted(number);
        const auto before = header(fd, 1024), copy = header(fd, 5120);
        if (!uke::userdata::needs_growth(before, copy, bytes)) {
            std::cout << "UKE_USERDATA_GROW: filesystem already fills the partition\n"; return 0;
        }
        // Battery RPC needs post-root DSP firmware; the packaged updater checks power before reboot.
        std::cout << "UKE_USERDATA_GROW: checking the unmounted F2FS filesystem\n" << std::flush;
        run("/usr/sbin/fsck.f2fs", "-f", device);
        unmounted(number);
        const auto checked = header(fd, 1024), checked_copy = header(fd, 5120);
        require(checked == before && checked_copy == before, "superblock changed during the preflight check");
        run("/usr/sbin/resize.f2fs", nullptr, device);
        run("/usr/sbin/fsck.f2fs", "-f", device);
        const auto after = header(fd, 1024), after_copy = header(fd, 5120);
        require(!uke::userdata::needs_growth(after, after_copy, bytes), "filesystem did not reach the partition size");
        for (unsigned i = 108; i < before.size(); ++i) require(after[i] == before[i], "filesystem identity changed");
        require(uke::userdata::filesystem_bytes(after, after_copy, bytes) > uke::userdata::filesystem_bytes(before, copy, bytes), "filesystem did not grow");
        require(fsync(fd) == 0, "cannot synchronize filesystem expansion");
        std::cout << "UKE_USERDATA_GROW: verified full-partition expansion with unchanged filesystem identity\n";
        return 0;
    } catch (const std::exception &error) {
        std::cerr << "UKE_USERDATA_GROW_REJECTED: " << error.what() << '\n'; return 255;
    }
}
