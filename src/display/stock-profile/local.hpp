// SPDX-License-Identifier: MIT
// Narrow descriptor helpers reused from the Uke boot updater at a96607f.
#pragma once
#include <openssl/evp.h>
#include <algorithm>
#include <array>
#include <cerrno>
#include <cstring>
#include <filesystem>
#include <fcntl.h>
#include <iostream>
#include <linux/fs.h>
#include <map>
#include <memory>
#include <set>
#include <stdexcept>
#include <string>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <sys/utsname.h>
#include <sys/wait.h>
#include <signal.h>
#include <unistd.h>
#include <vector>
namespace fs=std::filesystem;
using Bytes=std::vector<unsigned char>;
static inline void need(bool ok,const std::string &why) {if(!ok)throw std::runtime_error(why);}
struct Fd {
    int value;
    explicit Fd(int fd):value(fd){need(fd>=0,std::strerror(errno));}
    ~Fd(){if(value>=0)close(value);}
    Fd(const Fd&)=delete;Fd& operator=(const Fd&)=delete;
    Fd(Fd&& o)noexcept:value(o.value){o.value=-1;}
    Fd& operator=(Fd&& o)noexcept{if(this!=&o){if(value>=0)close(value);value=o.value;o.value=-1;}return *this;}
};
static inline bool token(const std::string &s) {
    return !s.empty()&&s.size()<128&&s.front()!='.'&&
        s.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._+-")==std::string::npos;
}
static inline bool below(const fs::path &path,const fs::path &parent) {
    if(!path.is_absolute()||!parent.is_absolute()||path.lexically_normal()!=path||parent.lexically_normal()!=parent)
        return false;
    auto child=path.begin();
    for(const auto &part:parent){if(child==path.end()||*child!=part)return false;++child;}
    return child!=path.end();
}
static inline void trusted_fd(int fd,bool dir=false) {
    struct stat st{};
#ifdef UKE_LOCAL_FW_TEST
    const auto owner=geteuid();
#else
    const uid_t owner=0;
#endif
    need(!fstat(fd,&st)&&(dir?S_ISDIR(st.st_mode):S_ISREG(st.st_mode))&&st.st_uid==owner&&
         !(st.st_mode&0022)&&(dir||st.st_nlink==1),"Protected root-owned descriptor required");
}
static inline Fd directory(const fs::path &path,bool create=false) {
    need(path.is_absolute()&&path.lexically_normal()==path,"Absolute normalized directory required");
    Fd dir(open("/",O_RDONLY|O_DIRECTORY|O_CLOEXEC));fs::path walked="/";
    for(const auto &part:path.relative_path()) {
        need(part!="."&&part!=".."&&!part.empty(),"Unsafe directory component");
        if(create&&mkdirat(dir.value,part.c_str(),0700)<0)need(errno==EEXIST,"Cannot create firmware directory");
        Fd next(openat(dir.value,part.c_str(),O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC));walked/=part;
#ifdef UKE_LOCAL_FW_TEST
        if(walked!="/tmp")trusted_fd(next.value,true);
#else
        trusted_fd(next.value,true);
#endif
        dir=std::move(next);
    }
    return dir;
}
static inline Bytes read_fd(int fd,uint64_t size,uint64_t offset=0) {
    need(size&&size<=32*1024*1024&&offset<=uint64_t(INT64_MAX)-size,"Bounded file read required");
    Bytes out(size);size_t done=0;
    while(done<out.size()) {
        const auto n=pread(fd,out.data()+done,out.size()-done,off_t(offset+done));
        if(n<0&&errno==EINTR)continue;need(n>0,"Incomplete read-only firmware read");done+=size_t(n);
    }
    return out;
}
static inline Bytes file(const fs::path &path) {
    auto parent=directory(path.parent_path());
    Fd fd(openat(parent.value,path.filename().c_str(),O_RDONLY|O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK));
    trusted_fd(fd.value);struct stat st{};need(!fstat(fd.value,&st),"Cannot stat firmware file");
    return read_fd(fd.value,st.st_size);
}
static inline void trusted(const fs::path &path,bool dir=false) {
    if(dir){auto fd=directory(path);}else{auto bytes=file(path);}
}
static inline std::string digest(const Bytes &bytes) {
    std::array<unsigned char,EVP_MAX_MD_SIZE> out{};unsigned n=0;
    need(EVP_Digest(bytes.data(),bytes.size(),out.data(),&n,EVP_sha256(),nullptr)==1&&n==32,"SHA-256 failed");
    static constexpr char digits[]="0123456789abcdef";std::string text;
    for(unsigned i=0;i<n;i++){text+=digits[out[i]>>4];text+=digits[out[i]&15];}return text;
}
#include "oem-video.hpp"
