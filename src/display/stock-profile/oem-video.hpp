// SPDX-License-Identifier: MIT
#pragma once
// Android LP on-disk format: AOSP system/core fs_mgr/liblp/metadata_format.h,
// commit a3b721a32242006b59cb12bd62c9133632af3a2d (Apache-2.0 specification).
// Format constants/layout are used here; no Android firmware bytes are shipped.
#include <linux/loop.h>
#include <poll.h>
#include <sys/random.h>
#include <sys/syscall.h>
#include <chrono>
#include <limits>
namespace uke_video {
struct Extent {uint64_t offset,size;};
static inline uint32_t u32(const Bytes &b,size_t p) {
    need(p<=b.size() && b.size()-p>=4,"LP field exceeds its buffer");
    uint32_t v=0;for(unsigned i=0;i<4;++i)v|=uint32_t(b[p+i])<<(8*i);return v;
}
static inline uint64_t u64(const Bytes &b,size_t p) {return u32(b,p)|(uint64_t(u32(b,p+4))<<32);}
static inline std::string hexbytes(const Bytes &b,size_t p,size_t n) {
    need(p<=b.size() && n<=b.size()-p,"LP checksum exceeds its buffer");
    static constexpr char digits[]="0123456789abcdef";std::string out;
    for(size_t i=0;i<n;++i){out+=digits[b[p+i]>>4];out+=digits[b[p+i]&15];}return out;
}
static inline Bytes range(int fd,uint64_t offset,size_t size,uint64_t limit) {
    need(size && size<=1024*1024 && offset<=limit && size<=limit-offset &&
         offset<=uint64_t(INT64_MAX)-size,"LP read exceeds the physical super partition");
    Bytes out(size);size_t done=0;
    while(done<size) {
        const auto n=pread(fd,out.data()+done,size-done,off_t(offset+done));
        if(n<0 && errno==EINTR)continue;
        need(n>0,"Incomplete LP metadata read");done+=size_t(n);
    }
    return out;
}
static inline std::string name(const Bytes &b,size_t p,size_t width) {
    need(p<=b.size() && width<=b.size()-p,"LP name exceeds its table");
    const auto end=std::find(b.begin()+p,b.begin()+p+width,0);
    need(end!=b.begin()+p+width,"Unterminated LP name");
    const std::string value(b.begin()+p,end);need(token(value),"Unsafe LP name");return value;
}
struct Table {uint32_t offset,count,width;};
static inline std::map<std::string,Extent> partitions(int fd,uint64_t limit) {
    const auto geometry=range(fd,4096,4096,limit),mirror=range(fd,8192,4096,limit);
    need(geometry==mirror && u32(geometry,0)==0x616c4467 && u32(geometry,4)==52,"LP geometry copies/version differ");
    auto g=Bytes(geometry.begin(),geometry.begin()+52);std::fill(g.begin()+8,g.begin()+40,0);
    need(digest(g)==hexbytes(geometry,8,32),"LP geometry checksum differs");
    const auto maximum=u32(geometry,40),slots=u32(geometry,44),block=u32(geometry,48);
    need(maximum>=4096 && maximum<=1024*1024 && maximum%4096==0 && slots>=1 && slots<=4 &&
         block>=512 && block<=65536 && !(block&(block-1)),"Unsupported LP geometry bounds");
    const uint64_t backup=12288+uint64_t(maximum)*slots;
    const auto data=range(fd,12288,maximum,limit),copy=range(fd,backup,maximum,limit);
    const auto header=u32(data,8),size=u32(data,44);
    need(u32(data,0)==0x414c5030 && (u32(data,4)&65535)==10 && (u32(data,4)>>16)<=2 &&
         (header==128||header==256) && header<=maximum && size<=maximum-header && size>0,
         "Unsupported or oversized LP metadata header");
    need(std::equal(data.begin(),data.begin()+header+size,copy.begin()),"LP metadata primary/backup differ");
    auto h=Bytes(data.begin(),data.begin()+header);std::fill(h.begin()+12,h.begin()+44,0);
    need(digest(h)==hexbytes(data,12,32) && digest(Bytes(data.begin()+header,data.begin()+header+size))==hexbytes(data,48,32),
         "LP metadata header/table checksum differs");
    if(header==256)need(!(u32(data,128)&~uint32_t(1)),"LP overlay/unknown state is not admitted");
    const Bytes tables(data.begin()+header,data.begin()+header+size);
    std::array<Table,4> desc{};std::vector<std::pair<uint64_t,uint64_t>> spans;
    constexpr std::array<uint32_t,4> widths{52,24,48,64};
    for(size_t i=0;i<desc.size();++i) {
        const auto p=80+i*12;desc[i]={u32(data,p),u32(data,p+4),u32(data,p+8)};
        const auto &t=desc[i];const uint64_t bytes=uint64_t(t.count)*t.width;
        need(t.width==widths[i] && t.count>0 && t.count<=4096 && t.offset<=size && bytes<=size-t.offset,"LP descriptor bounds differ");
        spans.emplace_back(t.offset,t.offset+bytes);
    }
    std::sort(spans.begin(),spans.end());
    for(size_t i=1;i<spans.size();++i)need(spans[i-1].second<=spans[i].first,"LP tables overlap");
    need(desc[3].count==1,"Only the measured single-super layout is supported");
    const auto device=desc[3].offset;const auto first=u64(tables,device),bytes=u64(tables,device+16);
    need(name(tables,device+24,36)=="super" && !u32(tables,device+60) && bytes==limit && bytes%512==0 &&
         first>=(backup+uint64_t(maximum)*slots+511)/512 && first<bytes/512,"LP physical device identity/bounds differ");
    std::set<std::string> seen;std::map<std::string,Extent> out;
    for(uint32_t i=0;i<desc[0].count;++i) {
        const auto p=desc[0].offset+size_t(i)*52;const auto label=name(tables,p,36);
        need(seen.insert(label).second,"Duplicate LP partition name");
        if(label!="odm_a" && label!="vendor_a")continue;
        const auto attributes=u32(tables,p+36),index=u32(tables,p+40),count=u32(tables,p+44),group=u32(tables,p+48);
        need(attributes==1 && count==1 && index<desc[1].count && group<desc[2].count,
             "OEM partition is not one read-only linear extent");
        const auto e=desc[1].offset+size_t(index)*24;const auto sectors=u64(tables,e),start=u64(tables,e+12);
        need(u32(tables,e+8)==0 && u32(tables,e+20)==0 && sectors && start>=first && start<bytes/512 &&
             sectors<=bytes/512-start,"OEM extent source/type/bounds differ");
        out.emplace(label,Extent{start*512,sectors*512});
    }
    need(!out.empty(),"No admitted ODM/vendor partition found");return out;
}
static inline Bytes capture(const std::vector<std::string> &args,size_t maximum=8*1024*1024) {
    need(!args.empty(),"Missing read-only helper command");int descriptors[2];
    need(!pipe2(descriptors,O_CLOEXEC|O_NONBLOCK),"Cannot open bounded helper output");
    Fd reader(descriptors[0]),writer(descriptors[1]);const auto child=fork();need(child>=0,"Cannot fork read-only helper");
    if(!child) {
        int null=open("/dev/null",O_RDONLY|O_CLOEXEC);
        if(null<0 || dup2(null,STDIN_FILENO)<0 || dup2(writer.value,STDOUT_FILENO)<0 ||
           fcntl(STDOUT_FILENO,F_SETFL,0)<0)_exit(127);
        close(null);close(reader.value);close(writer.value);
        std::vector<char*> argv;for(const auto &arg:args)argv.push_back(const_cast<char*>(arg.c_str()));argv.push_back(nullptr);
        char locale[]="LC_ALL=C",path[]="PATH=/usr/sbin:/usr/bin:/sbin:/bin";char *env[]={locale,path,nullptr};
        execve(argv[0],argv.data(),env);_exit(127);
    }
    close(writer.value);writer.value=-1;Bytes result;bool eof=false,child_done=false;int status=0;
    const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(15);
    try {
        while(!eof) {
            need(std::chrono::steady_clock::now()<deadline,"Read-only firmware helper timed out");
            pollfd ready{reader.value,POLLIN|POLLHUP,0};const auto event=poll(&ready,1,100);
            if(event<0 && errno==EINTR)continue;
            need(event>=0,"Cannot poll read-only helper");
            std::array<unsigned char,16384> buffer{};
            for(;;) {
                const auto n=read(reader.value,buffer.data(),buffer.size());
                if(n<0 && (errno==EAGAIN||errno==EINTR))break;
                need(n>=0,"Cannot read firmware helper output");
                if(!n){eof=true;break;}
                need(result.size()+size_t(n)<=maximum,"Firmware helper output exceeds bounds");
                result.insert(result.end(),buffer.begin(),buffer.begin()+n);
            }
        }
        for(;;) {
            const auto reaped=waitpid(child,&status,WNOHANG);
            if(reaped==child){child_done=true;break;}
            need(reaped>=0 || errno==EINTR,"Cannot reap read-only helper");
            need(std::chrono::steady_clock::now()<deadline,"Read-only helper did not exit");
            (void)poll(nullptr,0,20);
        }
        need(WIFEXITED(status) && WEXITSTATUS(status)==0,"Read-only helper failed");
    } catch(...) {
        if(!child_done){kill(child,SIGKILL);while(waitpid(child,&status,0)<0 && errno==EINTR){}}
        throw;
    }
    return result;
}
#ifndef UKE_KERNEL_UPDATE_TEST
static inline std::pair<Fd,std::string> readonly_loop(int source,const Extent &extent) {
    if(access("/dev/loop-control",F_OK)<0)(void)capture({"/usr/sbin/modprobe","loop"},4096);
    Fd control(open("/dev/loop-control",O_RDWR|O_CLOEXEC|O_NOFOLLOW));
    for(unsigned retry=0;retry<8;++retry) {
        const int index=ioctl(control.value,LOOP_CTL_GET_FREE);need(index>=0 && index<1048576,"Cannot allocate read-only loop device");
        const auto path="/dev/loop"+std::to_string(index);Fd loop(open(path.c_str(),O_RDWR|O_CLOEXEC|O_NOFOLLOW));
        struct stat st{};need(!fstat(loop.value,&st) && S_ISBLK(st.st_mode) && st.st_rdev==makedev(7,index),"Loop device identity differs");
        loop_config config{};config.fd=source;config.info.lo_offset=extent.offset;config.info.lo_sizelimit=extent.size;
        config.info.lo_flags=LO_FLAGS_READ_ONLY|LO_FLAGS_AUTOCLEAR;
        if(ioctl(loop.value,LOOP_CONFIGURE,&config)<0){need(errno==EBUSY,"Cannot configure read-only OEM view");continue;}
        loop_info64 actual{};need(!ioctl(loop.value,LOOP_GET_STATUS64,&actual) && actual.lo_offset==extent.offset &&
            actual.lo_sizelimit==extent.size && (actual.lo_flags&(LO_FLAGS_READ_ONLY|LO_FLAGS_AUTOCLEAR))==(LO_FLAGS_READ_ONLY|LO_FLAGS_AUTOCLEAR),
            "OEM view is not the requested read-only autoclear loop");
        return {std::move(loop),path};
    }
    throw std::runtime_error("Read-only loop allocation stayed busy");
}
#endif
static inline bool admitted(const Bytes &bytes) {
    if(bytes.size()!=2331336)return false;
    const auto hash=digest(bytes);
    if(hash!="2ad782a1eace4556f13178c82480e672bb2063818f438864f45067347ccdeb2a" &&
       hash!="3a4cac666ed1cd1ab5cb55f975dc724fd3e10603713b382f390484c37548d231")return false;
    need(bytes[0]==0x7f && bytes[1]=='E' && bytes[2]=='L' && bytes[3]=='F' && bytes[4]==1 && bytes[5]==1 &&
         (u32(bytes,16)>>16)==94 && u32(bytes,28)<=bytes.size()-22*32 && (u32(bytes,40)>>16)==32 &&
         (u32(bytes,44)&65535)==22,"Admitted firmware ELF layout differs");
    uint64_t low=UINT64_MAX,high=0;const auto ph=u32(bytes,28);
    for(unsigned i=0;i<22;++i) {
        const auto p=ph+i*32;const auto flags=u32(bytes,p+24),memory=u32(bytes,p+20);
        if(u32(bytes,p)!=1 || !memory || (flags&0x07000000)==0x02000000)continue;
        const auto offset=u32(bytes,p+4),file_size=u32(bytes,p+16);const uint64_t address=u32(bytes,p+12);
        need(offset<=bytes.size() && file_size<=bytes.size()-offset && file_size<=memory,"Firmware segment bounds differ");
        low=std::min(low,address&~uint64_t(4095));high=std::max(high,(address+memory+4095)&~uint64_t(4095));
    }
    need(low<high && high-low==0x800000,"Firmware exceeds the qualified video memory span");return true;
}
static inline void publish(const fs::path &destination,const Bytes &bytes) {
    need(!bytes.empty() && bytes.size()<=8*1024*1024,"Firmware publication size exceeds bounds");
    auto parent=directory(destination.parent_path(),true);
    if(fs::exists(destination) || fs::is_symlink(destination)) {
        need(file(destination)==bytes,"Existing versioned firmware differs; it was not overwritten");return;
    }
    uint64_t random=0;need(getrandom(&random,sizeof(random),0)==ssize_t(sizeof(random)),"Cannot allocate firmware staging name");
    const auto temporary=".uke-video-"+std::to_string(random);
    Fd out(openat(parent.value,temporary.c_str(),O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600));
    struct Cleanup {int dir;std::string name;~Cleanup(){unlinkat(dir,name.c_str(),0);}} cleanup{parent.value,temporary};
    size_t done=0;
    while(done<bytes.size()) {
        const auto n=write(out.value,bytes.data()+done,bytes.size()-done);if(n<0 && errno==EINTR)continue;
        need(n>0,"Cannot stage versioned firmware");done+=size_t(n);
    }
    need(!fchmod(out.value,0644) && !fsync(out.value),"Cannot sync versioned firmware");
    if(syscall(SYS_renameat2,parent.value,temporary.c_str(),parent.value,destination.filename().c_str(),RENAME_NOREPLACE)<0)
        need(errno==EEXIST && file(destination)==bytes,"Cannot publish firmware without replacing another file");
    need(!fsync(parent.value) && file(destination)==bytes,"Versioned firmware readback differs");
}
#ifndef UKE_KERNEL_UPDATE_TEST
static inline Bytes load_local(const std::pair<std::string,dev_t> &super) {
    // Fedora's merged /usr/sbin is a symlink. Descriptor ancestry is checked
    // on the real /usr/bin path, as for the updater's other trusted inputs.
    trusted("/usr/bin/debugfs");
    Fd source(open(("/dev/"+super.first).c_str(),O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK));
    struct stat st{};uint64_t size=0;
    need(!fstat(source.value,&st) && S_ISBLK(st.st_mode) && st.st_rdev==super.second && !ioctl(source.value,BLKGETSIZE64,&size),
         "Cannot verify the read-only physical super descriptor");
    const auto inputs=partitions(source.value,size);
    for(const auto &label:{"odm_a","vendor_a"}) {
        const auto found=inputs.find(label);if(found==inputs.end())continue;
        auto [loop,path]=readonly_loop(source.value,found->second);
        const auto bytes=capture({"/usr/bin/debugfs","-R","cat /firmware/vpu30_2v.mbn",path});
        if(!admitted(bytes))continue;
        return bytes;
    }
    throw std::runtime_error("No hash-admitted local video firmware found; no firmware was installed");
}
static inline void import_firmware(const std::string &release,const std::string &running,const std::pair<std::string,dev_t> &super) {
    need(token(release),"Invalid versioned firmware release");
    const auto destination=fs::path("/usr/lib/firmware")/release/"qcom/uke/vpu30_2v.mbn";
    if(fs::exists(destination) || fs::is_symlink(destination)) {
        need(admitted(file(destination)),"Existing versioned firmware is not admitted");
        std::cout<<"Versioned device-local video firmware already verified\n";return;
    }
    need(release!=running,"Firmware import is confined to a non-running kernel release");
    const auto bytes=load_local(super);publish(destination,bytes);
    std::cout<<"Imported hash-admitted device-local video firmware for "<<release<<"; no current-kernel firmware or source partition changed\n";
}
#endif
} // namespace uke_video
