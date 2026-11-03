// SPDX-License-Identifier: GPL-2.0-only
// The exact kernel parser, without filesystem or bootloader operations.
#include <cassert>
#include <cstring>
#include <string>
#include <vector>
#define UKE_INIT
#include "../src/boot/uke-root-selector.h"

static constexpr char base[] = "rdinit=/usr/lib/systemd/systemd root=PARTLABEL=linux rw rootfstype=ext4,f2fs,xfs,btrfs panic=0 console=tty0";
static void check(const std::string &args, int expected, const char *initial = base, const char *suffix = "") {
    char buffer[2048];
    std::strcpy(buffer, initial);
    assert(uke_select_root(buffer, sizeof(buffer), args.c_str(), args.size() + 1) == expected);
    auto wanted = std::string(initial);
    if (expected >= 0) wanted.replace(wanted.find("rootfstype=ext4,f2fs,xfs,btrfs"), std::strlen("rootfstype=ext4,f2fs,xfs,btrfs"), expected == 1 ? "rootfstype=ext4,f2fs,xfs,btrfs" : "rootfstype=ext4");
    if (expected == 1) {
        wanted.replace(wanted.find("root=PARTLABEL=linux"), std::strlen("root=PARTLABEL=linux"), "root=PARTLABEL=userdata");
        wanted.replace(wanted.find("panic=0"), std::strlen("panic=0"), "panic=10");
    }
    wanted += suffix;
    assert(buffer == wanted);
}
int main() {
    check("", 0);
    check("root=/dev/invalid init=/unsafe androidboot.slot_suffix=_a", 0, base, " androidboot.slot_suffix=_a");
    check("senemos.root=linux", 0);
    check("senemos.root=userdata", 1);
    const char *reset=" senemos.boot_reset=1 gunyah_wdt.boot_enabled=1 watchdog.open_timeout=180 systemd.watchdog_sec=30";
    check("senemos.root=userdata senemos.boot_reset=1", 1, base, reset);
    check("senemos.boot_reset=1 senemos.root=userdata", 1, base, reset);
    for(const auto *args:{"senemos.boot_reset=1", "senemos.root=linux senemos.boot_reset=1",
                         "senemos.root=userdata senemos.boot_reset=0", "senemos.root=userdata senemos.boot_reset=2",
                         "senemos.root=userdata senemos.boot_reset=1 senemos.boot_reset=1"})check(args,-1);
    for(const auto *argument:{"senemos.boot_reset=1", "gunyah_wdt.boot_enabled=0", "watchdog.open_timeout=0", "systemd.watchdog_sec=0"}) {
        const auto modified=std::string(base)+" "+argument;
        check("senemos.root=userdata senemos.boot_reset=1",-1,modified.c_str());
    }
    {
        const char args[]="senemos.root=userdata senemos.boot_reset=1";
        const auto wanted=std::string("rdinit=/usr/lib/systemd/systemd root=PARTLABEL=userdata rw rootfstype=ext4,f2fs,xfs,btrfs panic=10 console=tty0")+reset;
        std::vector<char> exact(wanted.size()+1);std::strcpy(exact.data(),base);
        assert(uke_select_root(exact.data(),exact.size()-1,args,sizeof(args))==-1);
        assert(!std::strcmp(exact.data(),base));
        assert(uke_select_root(exact.data(),exact.size(),args,sizeof(args))==1);
        assert(exact.data()==wanted);
    }
    check("\tsenemos.root=userdata\nandroidboot.slot_suffix=_b root=/dev/invalid", 1, base, " androidboot.slot_suffix=_b");
    check("senemos.root=userdata msm.o82_vrr_test_min_hz=30 androidboot.slot_suffix=_a", 1, base,
          " androidboot.slot_suffix=_a msm.o82_vrr_test_min_hz=30");
    check("senemos.root=userdata msm.o82_vrr_test_min_hz=0", 1, base, " msm.o82_vrr_test_min_hz=0");
    for (const auto *args : {"androidboot.slot_suffix=", "androidboot.slot_suffix=_c", "androidboot.slot_suffix=_a/",
                            "androidboot.slot_suffix=_a androidboot.slot_suffix=_a", "androidboot.slot_suffix=_a androidboot.slot_suffix=_b",
                            "msm.o82_vrr_test_min_hz=30", "senemos.root=linux msm.o82_vrr_test_min_hz=30",
                            "senemos.root=userdata msm.o82_vrr_test_min_hz=31", "senemos.root=userdata msm.o82_vrr_test_min_hz=",
                            "senemos.root=userdata msm.o82_vrr_test_min_hz=30 msm.o82_vrr_test_min_hz=0"}) check(args, -1);
    check("senemos.root=userdata", -1, "root=PARTLABEL=linux androidboot.slot_suffix=_a");
    check("senemos.root=userdata", -1, "root=PARTLABEL=linux msm.o82_vrr_test_min_hz=30");
    check("xsenemos.root=userdata senemos.root.extra=userdata", 0);
    for (const auto *args : {"senemos.root=", "senemos.root=system", "senemos.root=userdata/", "senemos.root=\"userdata\"",
                            "senemos.root=linux senemos.root=userdata", "senemos.root=userdata senemos.root=userdata"}) check(args, -1);
    check("senemos.root=userdata", -1, "root=PARTLABEL=linux root=PARTLABEL=linux");
    check("senemos.root=userdata", -1, "root=UUID=invalid");
    check("senemos.root=userdata", -1, "console=tty0");
    check("senemos.root=userdata", -1, "root=PARTLABEL=linux");
    for (const auto *initial : {"root=PARTLABEL=linux rootfstype=ext4,f2fs,xfs,btrfs", "root=PARTLABEL=linux panic=0",
                               "root=PARTLABEL=linux rootfstype=ext4,f2fs,xfs,btrfs rootfstype=f2fs panic=0",
                               "root=PARTLABEL=linux rootfstype=f2fs panic=0",
                               "root=PARTLABEL=linux rootfstype=ext4,f2fs,xfs,btrfs panic=10",
                               "root=PARTLABEL=linux rootfstype=ext4,f2fs,xfs,btrfs panic=0 panic=0"}) check("senemos.root=userdata", -1, initial);
    // All token orders share the same bounds and profile rules.
    for (const auto *initial : {"rootfstype=ext4,f2fs,xfs,btrfs panic=0 root=PARTLABEL=linux",
                               "rootfstype=ext4,f2fs,xfs,btrfs root=PARTLABEL=linux panic=0",
                               "panic=0 rootfstype=ext4,f2fs,xfs,btrfs root=PARTLABEL=linux",
                               "panic=0 root=PARTLABEL=linux rootfstype=ext4,f2fs,xfs,btrfs",
                               "root=PARTLABEL=linux panic=0 rootfstype=ext4,f2fs,xfs,btrfs"}) {
        check("senemos.root=userdata", 1, initial);
        check("senemos.root=linux", 0, initial);
    }
    const char args[] = "senemos.root=userdata";
    char bounded[sizeof(base) + 4]; std::strcpy(bounded, base);
    assert(uke_select_root(bounded, sizeof(base) - 1, args, sizeof(args)) == -1);
    assert(!std::strcmp(bounded, base));
    assert(uke_select_root(bounded, sizeof(bounded), args, sizeof(args)) == 1);
    const char slot_args[] = "senemos.root=userdata androidboot.slot_suffix=_b";
    const std::string wanted = std::string(bounded) + " androidboot.slot_suffix=_b";
    std::vector<char> short_line(wanted.size() + 1);
    std::strcpy(short_line.data(), base);
    assert(uke_select_root(short_line.data(), short_line.size() - 1, slot_args, sizeof(slot_args)) == -1);
    assert(!std::strcmp(short_line.data(), base));
    assert(uke_select_root(short_line.data(), short_line.size(), slot_args, sizeof(slot_args)) == 1);
    assert(short_line.data() == wanted);
    char unterminated[32]; std::memset(unterminated, 'X', sizeof(unterminated));
    assert(uke_select_root(unterminated, sizeof(unterminated), args, sizeof(args)) == -1);
    char buffer[2048]; std::strcpy(buffer, base);
    const char embedded[] = "senemos.root=linux\0senemos.root=userdata";
    assert(uke_select_root(buffer, sizeof(buffer), embedded, sizeof(embedded)) == -1);
    assert(uke_select_root(buffer, sizeof(buffer), args, sizeof(args) - 1) == -1);
    assert(uke_select_root(buffer, sizeof(buffer), nullptr, 1) == -1);
    assert(uke_select_root(buffer, sizeof(buffer), args, 8193) == -1);
    assert(!std::strcmp(buffer, base));
    assert(uke_select_root(buffer, sizeof(buffer), nullptr, 0) == 0);
    assert(std::string(buffer).find("rootfstype=ext4 ") != std::string::npos);
}
