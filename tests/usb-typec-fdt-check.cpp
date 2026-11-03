// SPDX-License-Identifier: GPL-2.0-only
// Host regular-file fixture for the actual full Type-C and native FDT transforms.
#include <libfdt.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <cerrno>
#include <cstring>
#include <cstdint>
#include <iostream>
#include <map>
#include <set>
#include <stdexcept>
#include <string>
#include <vector>
#include <dt-bindings/clock/qcom,gcc-cliffs.h>
#include <dt-bindings/clock/qcom,sm8550-dispcc.h>
#include <dt-bindings/clock/qcom,rpmh.h>
#include <dt-bindings/clock/qcom,tcsrcc-pineapple.h>
#include <dt-bindings/phy/phy-qcom-qmp.h>
extern "C" int uke_abl_transform(void *, size_t, const void *, size_t, void *, size_t, void *, size_t);
extern "C" int uke_typec_native_fixture(void *, void *, size_t);
using Bytes = std::vector<unsigned char>;
constexpr size_t capacity = 2 * 1024 * 1024;
static const std::string usb = "/soc/ssusb@a600000";
static const std::string mdss = "/soc/display-subsystem@ae00000";
static const std::string dp = mdss + "/displayport-controller@af54000";
static const std::string connector = "/pmic-glink/connector@0";
static void need(bool value, const std::string &reason) { if (!value) throw std::runtime_error(reason); }
static Bytes read_blob(const char *path) {
    const int fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    need(fd >= 0, "Cannot open regular FDT input");
    struct stat st {};
    if (fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_size < 40 || st.st_size > static_cast<off_t>(capacity)) {
        close(fd); throw std::runtime_error("Invalid bounded regular FDT input");
    }
    Bytes data(static_cast<size_t>(st.st_size));
    size_t done = 0;
    while (done < data.size()) {
        const auto count = read(fd, data.data() + done, data.size() - done);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { close(fd); throw std::runtime_error("Short FDT read"); }
        done += static_cast<size_t>(count);
    }
    need(close(fd) == 0, "FDT input close failed");
    need(fdt_check_full(data.data(), data.size()) == 0, "Malformed FDT input");
    return data;
}
static int node(const Bytes &dt, const std::string &path) {
    const int n = fdt_path_offset(dt.data(), path.c_str());
    need(n >= 0, "Required node missing: " + path); return n;
}
static std::string path_of(const Bytes &dt, int n) {
    char path[4096]; need(fdt_get_path(dt.data(), n, path, sizeof(path)) == 0, "Invalid phandle target path"); return path;
}
static Bytes prop(const Bytes &dt, int n, const char *name) {
    int size = 0; const auto *p = static_cast<const unsigned char *>(fdt_getprop(dt.data(), n, name, &size));
    need(p && size >= 0, "Required property missing: " + path_of(dt, n) + "/" + name);
    return Bytes(p, p + size);
}
static bool has(const Bytes &dt, const std::string &path, const char *name) {
    int size = 0; const auto *p = fdt_getprop(dt.data(), node(dt, path), name, &size);
    return p && size >= 0;
}
static std::vector<uint32_t> cells(const Bytes &dt, int n, const char *name) {
    const auto data = prop(dt, n, name); need(data.size() % 4 == 0, "Unaligned cell property");
    std::vector<uint32_t> result;
    for (size_t i = 0; i < data.size(); i += 4) {
        fdt32_t cell; std::memcpy(&cell, data.data() + i, 4); result.push_back(fdt32_to_cpu(cell));
    }
    return result;
}
static std::vector<uint32_t> cells(const Bytes &dt, const std::string &path, const char *name) {
    return cells(dt, node(dt, path), name);
}
static void exact(const Bytes &dt, const std::string &path, const char *name, std::initializer_list<uint32_t> expected) {
    need(cells(dt, path, name) == std::vector<uint32_t>(expected), "Cell contract differs: " + path + "/" + name);
}
static void text(const Bytes &dt, const std::string &path, const char *name, const std::string &expected) {
    const auto data = prop(dt, node(dt, path), name);
    need(data.size() == expected.size() + 1 && data.back() == 0 &&
         std::memcmp(data.data(), expected.c_str(), data.size()) == 0, "Text contract differs: " + path + "/" + name);
}
static void strings(const Bytes &dt, const std::string &path, const char *name, std::initializer_list<const char *> expected) {
    Bytes wanted;
    for (const auto *s : expected) wanted.insert(wanted.end(), s, s + std::strlen(s) + 1);
    need(prop(dt, node(dt, path), name) == wanted, "String-list contract differs: " + path + "/" + name);
}
static uint32_t handle(const Bytes &dt, const std::string &path) {
    const auto value = fdt_get_phandle(dt.data(), node(dt, path)); need(value && value != UINT32_MAX, "Missing valid phandle"); return value;
}
static std::string symbol(const Bytes &dt, const char *name) {
    const auto data = prop(dt, node(dt, "/__symbols__"), name);
    need(!data.empty() && data.back() == 0, "Malformed symbol path");
    const std::string path(reinterpret_cast<const char *>(data.data()));
    node(dt, path); return path;
}
static void compatible(const Bytes &dt, const std::string &path, const char *value) {
    need(fdt_node_check_compatible(dt.data(), node(dt, path), value) == 0, "Compatible differs: " + path);
}
static void endpoint(const Bytes &dt, const std::string &a, const std::string &b) {
    exact(dt, a, "remote-endpoint", {handle(dt, b)}); exact(dt, b, "remote-endpoint", {handle(dt, a)});
}
static void enabled(const Bytes &dt, const std::string &path) {
    if (has(dt, path, "status")) {
        const auto value = prop(dt, node(dt, path), "status");
        need(value == Bytes{'o','k',0} || value == Bytes{'o','k','a','y',0}, "Provider disabled: " + path);
    }
}
static void preserve(const Bytes &before, const Bytes &after, const std::string &path, bool recurse) {
    const int a = node(before, path), b = node(after, path); int p;
    fdt_for_each_property_offset(p, before.data(), a) {
        const char *name = nullptr; int size;
        need(fdt_getprop_by_offset(before.data(), p, &name, &size) != nullptr && name, "Invalid preserved property");
        need(prop(before, a, name) == prop(after, b, name), "Preserved property changed: " + path + "/" + name);
    }
    if (recurse) {
        int child; fdt_for_each_subnode(child, before.data(), a)
            preserve(before, after, path + "/" + fdt_get_name(before.data(), child, nullptr), true);
    }
}
// Compare common internal-display properties without assuming overlay phandle numbering.
static std::string canonical(const Bytes &dt, int n, const char *name) {
    const std::string key(name);
    if (key == "phandle" || key == "linux,phandle") return path_of(dt, n);
    std::string arg_count;
    if (key == "clocks" || key == "assigned-clocks" || key == "assigned-clock-parents") arg_count = "#clock-cells";
    else if (key == "phys") arg_count = "#phy-cells";
    else if (key == "resets") arg_count = "#reset-cells";
    else if (key == "power-domains") arg_count = "#power-domain-cells";
    else if (key == "gpios" || key.ends_with("-gpios")) arg_count = "#gpio-cells";
    const bool single = key.ends_with("-supply") || key == "remote-endpoint" || key == "backlight" ||
                        key == "interrupt-parent" || key == "operating-points-v2";
    if (arg_count.empty() && !single) {
        const auto data = prop(dt, n, name); return std::string(data.begin(), data.end());
    }
    const auto values = cells(dt, n, name); std::string result;
    for (size_t i = 0; i < values.size();) {
        const auto ph = values[i++];
        if (!ph) { result += "<null>;"; continue; }
        const int target = fdt_node_offset_by_phandle(dt.data(), ph); need(target >= 0, "Dangling internal display phandle");
        result += path_of(dt, target) + ":";
        uint32_t count = 0;
        if (!arg_count.empty()) {
            const auto counts = cells(dt, target, arg_count.c_str()); need(counts.size() == 1, "Invalid provider argument count"); count = counts[0];
        }
        need(count <= values.size() - i, "Truncated provider arguments");
        while (count--) result += std::to_string(values[i++]) + ",";
        result += ";";
    }
    return result;
}
static void same_display(const Bytes &baseline, const Bytes &full, const std::string &path) {
    const int a = node(baseline, path), b = node(full, path);
    std::set<std::string> pa, pb, ca, cb; int p, child;
    const auto properties = [&](const Bytes &dt, int n, std::set<std::string> &names) {
        fdt_for_each_property_offset(p, dt.data(), n) {
            const char *name = nullptr; int length;
            need(fdt_getprop_by_offset(dt.data(), p, &name, &length) != nullptr && name, "Malformed display property"); names.insert(name);
        }
    };
    properties(baseline, a, pa); properties(full, b, pb); need(pa == pb, "Internal display property set changed: " + path);
    for (const auto &name : pa)
        need(canonical(baseline, a, name.c_str()) == canonical(full, b, name.c_str()), "Internal display differs: " + path + "/" + name);
    fdt_for_each_subnode(child, baseline.data(), a) ca.insert(fdt_get_name(baseline.data(), child, nullptr));
    fdt_for_each_subnode(child, full.data(), b) cb.insert(fdt_get_name(full.data(), child, nullptr));
    need(ca == cb, "Internal display child set changed: " + path);
    for (const auto &name : ca) same_display(baseline, full, path + "/" + name);
}
static void check_graph(const Bytes &dt) {
    need(fdt_check_full(dt.data(), dt.size()) == 0, "Invalid output FDT");
    compatible(dt, "/", "xiaomi,uke"); text(dt, "/chosen", "senemos,usb-profile", "typec-v1");
    const auto qmp = symbol(dt, "usb_qmp_dp_phy"), hs = symbol(dt, "eusb2_phy0"), wcd = symbol(dt, "wcd_usbss");
    const auto gcc = symbol(dt, "gcc"), pdc = symbol(dt, "pdc"), gic = symbol(dt, "intc");
    const auto tcsr = symbol(dt, "tcsrcc"), dispcc = symbol(dt, "dispcc"), gdsc = symbol(dt, "gcc_usb3_phy_gdsc");
    const auto g = handle(dt, gcc), q = handle(dt, qmp), d = handle(dt, dispcc);
    for (const auto &path : {usb, qmp, hs, wcd, gcc, pdc, gic, tcsr, dispcc, gdsc, mdss, dp}) enabled(dt, path);
    compatible(dt, usb, "qcom,sm7675-dwc3-typec"); exact(dt, usb, "reg", {0xa600000,0x100000});
    text(dt, usb, "dr_mode", "otg"); text(dt, usb, "maximum-speed", "super-speed");
    text(dt, usb, "role-switch-default-mode", "peripheral"); text(dt, usb, "usb-psy-name", "qcom-battmgr-usb");
    need(has(dt, usb, "usb-role-switch") && has(dt, usb, "wakeup-source"), "Missing role/wake capability");
    for (const char *key : {"usb-phy", "extcon", "interrupts", "qcom,select-utmi-as-pipe-clk"}) need(!has(dt, usb, key), "Legacy USB property retained");
    need(fdt_path_offset(dt.data(), (usb + "/port").c_str()) == -FDT_ERR_NOTFOUND, "Inherited USB single port retained");
    exact(dt, usb, "phys", {handle(dt,hs),q,QMP_USB43DP_USB3_PHY}); strings(dt,usb,"phy-names",{"usb2-phy","usb3-phy"});
    exact(dt,usb,"iommus",{handle(dt,symbol(dt,"apps_smmu")),0x40,0});
    exact(dt,symbol(dt,"mc_virt"),"#interconnect-cells",{2});
    exact(dt,symbol(dt,"gem_noc"),"#interconnect-cells",{2});
    exact(dt,usb,"interconnects",{handle(dt,symbol(dt,"aggre1_noc")),49,handle(dt,symbol(dt,"mc_virt")),512,0,
        handle(dt,symbol(dt,"gem_noc")),2,0,handle(dt,symbol(dt,"cnoc_cfg")),547});
    const auto core_gdsc=symbol(dt,"gcc_usb30_prim_gdsc");
    exact(dt,usb,"gdsc-supply",{handle(dt,core_gdsc)}); compatible(dt,core_gdsc,"qcom,sm7675-usb-gdsc");
    exact(dt,core_gdsc,"reg",{0x139004,8}); exact(dt,core_gdsc,"qcom,clock-controller",{g});
    exact(dt,gic,"#interrupt-cells",{3}); exact(dt,pdc,"#interrupt-cells",{2});
    exact(dt,usb,"interrupts-extended",{handle(dt,gic),0,133,4,handle(dt,gic),0,130,4,handle(dt,pdc),14,1,handle(dt,pdc),15,1,handle(dt,pdc),17,4});
    strings(dt,usb,"interrupt-names",{"dwc_usb3","pwr_event","dp_hs_phy_irq","dm_hs_phy_irq","ss_phy_irq"});
    text(dt,usb+"/dwc3@a600000","status","disabled");
    compatible(dt,hs,"qcom,sm7675-eusb2-typec"); exact(dt,hs,"#phy-cells",{0});
    exact(dt,hs,"reg",{0x88e3000,0x154,0x88e2000,4,0xc278000,4});
    exact(dt,hs,"vdd-supply",{handle(dt,symbol(dt,"L2B"))}); exact(dt,hs,"vdda12-supply",{handle(dt,symbol(dt,"L4B"))});
    const auto repeater=cells(dt,hs,"usb-repeater"); need(repeater.size()==1,"Invalid legacy repeater reference");
    const int repeater_node=fdt_node_offset_by_phandle(dt.data(),repeater[0]); need(repeater_node>=0,"Missing repeater provider");
    const auto repeater_path=path_of(dt,repeater_node); enabled(dt,repeater_path); compatible(dt,repeater_path,"qcom,pmic-eusb2-repeater");
    need(has(dt,repeater_path,"qcom,param-override-seq") && has(dt,repeater_path,"qcom,param-override-seq-host"),"Exact device/host repeater tuning missing");
    compatible(dt,qmp,"qcom,sm7675-qmp-usb3-dp-phy"); exact(dt,qmp,"reg",{0x88e8000,0x3000});
    exact(dt,qmp,"#phy-cells",{1}); exact(dt,qmp,"#clock-cells",{1});
    need(has(dt,qmp,"orientation-switch") && has(dt,qmp,"mode-switch"),"QMP switches missing");
    exact(dt,qmp,"clocks",{g,GCC_USB3_PRIM_PHY_AUX_CLK,handle(dt,tcsr),TCSR_USB3_CLKREF_EN,g,GCC_USB3_PRIM_PHY_COM_AUX_CLK,g,GCC_USB3_PRIM_PHY_PIPE_CLK});
    strings(dt,qmp,"clock-names",{"aux","ref","com_aux","usb3_pipe"});
    exact(dt,qmp,"resets",{g,GCC_USB3_PHY_PRIM_BCR,g,GCC_USB3_DP_PHY_PRIM_BCR}); strings(dt,qmp,"reset-names",{"phy","common"});
    exact(dt,qmp,"vdda-phy-supply",{handle(dt,symbol(dt,"L3B"))}); exact(dt,qmp,"vdda-pll-supply",{handle(dt,symbol(dt,"L4B"))});
    exact(dt,qmp,"vdda-usb-supply",{handle(dt,symbol(dt,"L2B"))}); exact(dt,qmp,"gdsc-supply",{handle(dt,gdsc)});
    compatible(dt,gdsc,"qcom,sm7675-usb-phy-gdsc"); exact(dt,gdsc,"reg",{0x150018,8}); exact(dt,gdsc,"qcom,clock-controller",{g});
    const auto ufs = handle(dt,symbol(dt,"ufsphy_mem"));
    exact(dt,gcc,"clocks",{handle(dt,symbol(dt,"rpmhcc")),RPMH_CXO_CLK,handle(dt,symbol(dt,"pcie_0_pipe_clk")),handle(dt,symbol(dt,"sleep_clk")),ufs,0,ufs,1,ufs,2,q,QMP_USB43DP_USB3_PIPE_CLK});
    compatible(dt,wcd,"xiaomi,uke-wcd939x-typec"); exact(dt,wcd,"reset-gpios",{handle(dt,symbol(dt,"tlmm")),119,1});
    strings(dt,wcd,"pinctrl-names",{"default","sleep"}); need(has(dt,wcd,"mode-switch") && has(dt,wcd,"orientation-switch"),"WCD switches missing");
    compatible(dt,"/pmic-glink","xiaomi,uke-typec-pmic-glink"); compatible(dt,connector,"usb-c-connector");
    exact(dt,connector,"reg",{0}); text(dt,connector,"data-role","dual"); text(dt,connector,"power-role","dual");
    int child, count=0; fdt_for_each_subnode(child,dt.data(),node(dt,"/pmic-glink")) ++count;
    need(count==1,"Unexpected upstream GLINK child");
    for (const char *old : {"/soc/qcom,pmic_glink","/soc/qcom,pmic_glink_log","/soc/qcom,pmic_glink/qcom,ucsi/connector","/soc/slim@6C40000"}) text(dt,old,"status","disabled");
    endpoint(dt,usb+"/ports/port@0/endpoint",connector+"/ports/port@0/endpoint");
    endpoint(dt,usb+"/ports/port@1/endpoint",qmp+"/ports/port@1/endpoint");
    endpoint(dt,qmp+"/ports/port@0/endpoint",connector+"/ports/port@1/endpoint");
    endpoint(dt,wcd+"/port/endpoint",connector+"/ports/port@2/endpoint");
    compatible(dt,dp,"qcom,sm7675-dp"); exact(dt,dp,"reg",{0xaf54000,0x104,0xaf54200,0xc0,0xaf55000,0x770,0xaf56000,0x9c,0xaf57000,0x9c});
    exact(dt,dp,"interrupt-parent",{handle(dt,mdss)}); exact(dt,dp,"interrupts",{12});
    exact(dt,dp,"phys",{q,QMP_USB43DP_DP_PHY}); strings(dt,dp,"phy-names",{"dp"});
    exact(dt,dp,"clocks",{d,DISP_CC_MDSS_AHB_CLK,d,DISP_CC_MDSS_DPTX0_AUX_CLK,d,DISP_CC_MDSS_DPTX0_LINK_CLK,d,DISP_CC_MDSS_DPTX0_LINK_INTF_CLK,d,DISP_CC_MDSS_DPTX0_PIXEL0_CLK,d,DISP_CC_MDSS_DPTX0_PIXEL1_CLK});
    strings(dt,dp,"clock-names",{"core_iface","core_aux","ctrl_link","ctrl_link_iface","stream_pixel","stream_1_pixel"});
    exact(dt,dp,"assigned-clock-parents",{q,QMP_USB43DP_DP_LINK_CLK,q,QMP_USB43DP_DP_VCO_DIV_CLK,q,QMP_USB43DP_DP_VCO_DIV_CLK});
    const auto display_clocks=cells(dt,dispcc,"clocks");
    // Decode provider argument counts; do not assume uniform clock tuple widths.
    bool link=false,vco=false;
    for (size_t i=0;i<display_clocks.size();) {
        const auto ph=display_clocks[i++]; if(!ph) continue;
        const int provider=fdt_node_offset_by_phandle(dt.data(),ph); need(provider>=0,"Dangling DISPCC clock provider");
        const auto nargs=cells(dt,provider,"#clock-cells"); need(nargs.size()==1 && nargs[0]<=display_clocks.size()-i,"Invalid DISPCC clock args");
        if(ph==q && nargs[0]==1) { link|=display_clocks[i]==QMP_USB43DP_DP_LINK_CLK; vco|=display_clocks[i]==QMP_USB43DP_DP_VCO_DIV_CLK; }
        i+=nargs[0];
    }
    need(link && vco,"DISPCC DP clock inputs remain placeholders");
    endpoint(dt,dp+"/ports/port@0/endpoint",mdss+"/display-controller@ae01000/ports/port@2/endpoint");
    endpoint(dt,dp+"/ports/port@1/endpoint",qmp+"/ports/port@2/endpoint"); exact(dt,dp+"/ports/port@1/endpoint","data-lanes",{0,1,2,3});
    const auto opp_ref=cells(dt,dp,"operating-points-v2"); need(opp_ref.size()==1,"Invalid DP OPP reference");
    const int opps=fdt_node_offset_by_phandle(dt.data(),opp_ref[0]); need(opps>=0,"Missing DP OPP table");
    std::set<uint64_t> rates;
    fdt_for_each_subnode(child,dt.data(),opps) { const auto hz=cells(dt,child,"opp-hz"); need(hz.size()==2,"Invalid DP OPP rate"); rates.insert((uint64_t(hz[0])<<32)|hz[1]); }
    need(rates==std::set<uint64_t>{162000000,270000000,540000000},"DP source rate ceiling differs");
    text(dt,symbol(dt,"sde_dp"),"status","disabled");
}
static Bytes native(const Bytes &adapted, Bytes overlay) {
    Bytes dt(capacity); need(fdt_open_into(adapted.data(),dt.data(),dt.size())==0,"Cannot restore native FDT capacity");
    const int ret=uke_typec_native_fixture(dt.data(),overlay.data(),overlay.size());
    need(ret==0,"Actual native transform rejected input: "+std::to_string(ret)); return dt;
}
static void write_new(const char *path, const Bytes &dt) {
    const int fd=open(path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600); need(fd>=0,"Output must be new");
    const size_t size=fdt_totalsize(dt.data()); size_t done=0;
    while(done<size) { const auto n=write(fd,dt.data()+done,size-done); if(n<0 && errno==EINTR) continue;
        if(n<=0) {close(fd); throw std::runtime_error("Short output write");} done+=static_cast<size_t>(n); }
    const int flush=fsync(fd), closed=close(fd); need(!flush && !closed,"Output flush failed");
}
int main(int argc,char **argv) {
    try {
        need(argc==7,"Usage: usb-typec-fdt-check OEM_ABL UFS USB DISPLAY BASELINE_DISPLAY NEW_OUTPUT");
        auto input=read_blob(argv[1]); const auto saved=input;
        const auto ufs=read_blob(argv[2]), usb_overlay=read_blob(argv[3]), display=read_blob(argv[4]), baseline_overlay=read_blob(argv[5]);
        auto u=ufs, s=usb_overlay; Bytes adapted(capacity);
        const int ret=uke_abl_transform(adapted.data(),adapted.size(),input.data(),input.size(),u.data(),u.size(),s.data(),s.size());
        need(input==saved,"Actual base transform modified input"); need(ret==1,"Actual base transform rejected full profile: "+std::to_string(ret));
        const auto full=native(adapted,display), baseline=native(adapted,baseline_overlay);
        need(fdt_path_offset(baseline.data(),dp.c_str())==-FDT_ERR_NOTFOUND,"Comparison baseline unexpectedly includes native DP");
        need(input==saved,"Original OEM/ABL input changed"); check_graph(full);
        int child, memories=0; fdt_for_each_subnode(child,input.data(),0) {
            const std::string name=fdt_get_name(input.data(),child,nullptr);
            if(name=="memory" || name.starts_with("memory@")) {preserve(input,full,"/"+name,true); ++memories;}
        }
        need(memories>0,"No input memory nodes"); preserve(input,full,"/reserved-memory",true);
        need(fdt_num_mem_rsv(input.data())==fdt_num_mem_rsv(full.data()),"Reserve-map count changed");
        for(int i=0;i<fdt_num_mem_rsv(input.data());i++) {uint64_t a,as,b,bs;
            need(!fdt_get_mem_rsv(input.data(),i,&a,&as) && !fdt_get_mem_rsv(full.data(),i,&b,&bs) && a==b && as==bs,"Reserve map changed");}
        need(prop(input,node(input,"/chosen"),"bootargs")==prop(full,node(full,"/chosen"),"bootargs"),"Panel selector/boot arguments changed");
        const auto fb=prop(adapted,node(adapted,"/chosen"),"stdout-path"); need(!fb.empty() && fb.back()==0,"Invalid adapted framebuffer path");
        need(prop(full,node(full,"/chosen"),"stdout-path")==fb,"Early framebuffer stdout changed");
        const std::string framebuffer(reinterpret_cast<const char *>(fb.data()));
        text(full,framebuffer,"status","okay");
        need(!has(full,framebuffer,"backlight"),"Early framebuffer owns native backlight");
        for(const char *name : {"compatible","reg","width","height","stride","format","panel"})
            need(prop(adapted,node(adapted,framebuffer),name)==prop(full,node(full,framebuffer),name),"Early framebuffer metadata changed");
        need(has(full,"/reserved-memory/splash_region","no-map"),"Splash reservation lost no-map");
        for(const char *name : {"dsi@ae94000","dsi@ae96000","phy@ae95000","phy@ae97000"}) same_display(baseline,full,mdss+"/"+name);
        for(const char *name : {"port@0","port@1"}) same_display(baseline,full,mdss+"/display-controller@ae01000/ports/"+name);
        for(const char *name : {"vddio-supply","vsp-supply","vsn-supply","backlight","reset-gpios"})
            need(canonical(baseline,node(baseline,mdss+"/dsi@ae94000/panel@0"),name)==canonical(full,node(full,mdss+"/dsi@ae94000/panel@0"),name),"Panel supply/reset differs");
        need(has(full,mdss+"/dsi@ae94000/panel@0","xiaomi,oem-refresh-modes"),"Internal seven-mode profile missing");
        // Deliberately corrupt private RESULT copies: checker negatives, not runtime admission claims.
        for(int fault=0;fault<4;fault++) {
            auto bad=full; need(!fdt_open_into(bad.data(),bad.data(),bad.size()),"Cannot expand private negative result"); int rc=0;
            if(fault==0) rc=fdt_delprop(bad.data(),node(bad,usb),"phys");
            if(fault==1) rc=fdt_setprop_u32(bad.data(),node(bad,dp+"/ports/port@1/endpoint"),"remote-endpoint",0xdeadbeef);
            if(fault==2) rc=fdt_setprop_u32(bad.data(),node(bad,symbol(bad,"usb_qmp_dp_phy")),"vdda-phy-supply",0xdeadbeef);
            if(fault==3) rc=fdt_setprop_string(bad.data(),node(bad,usb),"maximum-speed","super-speed-plus");
            need(!rc,"Cannot construct negative result mutation"); bool rejected=false; try {check_graph(bad);} catch(const std::exception &) {rejected=true;}
            need(rejected,"Broken full-profile result escaped checker");
        }
        // Execute the actual transform's known malformed-input refusal boundaries.
        for(int fault=0;fault<3;fault++) {
            auto bad=input, bad_u=ufs, bad_s=usb_overlay; Bytes scratch(capacity);
            if(fault==0) {const fdt32_t board[]={cpu_to_fdt32(9),cpu_to_fdt32(0)};
                need(!fdt_setprop(bad.data(),0,"qcom,board-id",board,sizeof(board)),"Cannot construct wrong-board input");}
            if(fault==1) {const fdt32_t reg[]={cpu_to_fdt32(0x1d84000),cpu_to_fdt32(0x1000)};
                need(!fdt_setprop(bad.data(),node(bad,"/soc/ufshc@1d84000"),"reg",reg,sizeof(reg)),"Cannot construct wrong-UFS input");}
            if(fault==2) bad_s.resize(40);
            const auto original=bad;
            const int rejected=uke_abl_transform(scratch.data(),scratch.size(),bad.data(),bad.size(),bad_u.data(),bad_u.size(),bad_s.data(),bad_s.size());
            need(rejected<0 && bad==original,"Actual transform malformed-input boundary failed");
        }
        write_new(argv[6],full);
        std::cout<<"Actual full Type-C/native FDT transform and graph passed; RAM/reservations/internal DSI preserved; host-only evidence\n";
        return 0;
    } catch(const std::exception &e) {std::cerr<<e.what()<<'\n'; return 1;}
}
