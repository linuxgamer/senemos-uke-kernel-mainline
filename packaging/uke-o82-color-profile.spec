Name: uke-o82-color-profile
Version: 0.1.0
Release: 1%{?dist}
Summary: Generate a private O82 OEM P3 ICC mapping for original KDE
License: MIT
URL: https://github.com/MCC45TR/senemos-uke-kernel-mainline
Source0: o82-color-profile.cpp
Source1: O82-COLOR-PROFILE.md
Source2: LICENSE
ExclusiveArch: aarch64
BuildRequires: clang gcc-c++ compiler-rt pkgconf-pkg-config
BuildRequires: pkgconfig(json-c) pkgconfig(lcms2) pkgconfig(openssl)

%description
Read an exact, hash-verified O82 factory QDCM profile and generate a new private
ICC mapping from its P3 inverse gamma, gamut and output gamma tables. Original
KWin performs color conversion in its existing ICC shader path. The generator
does not access hardware, modify the backlight, install a desktop profile or
redistribute factory tables. Optical calibration and native HDR10 acceptance
remain separate from OEM-derived P3 mapping and the compositor's existing EDR.

%prep
cp %{SOURCE0} .
cp %{SOURCE1} .
cp %{SOURCE2} .

%build
clang++ -std=c++20 %{optflags} -UNDEBUG -Wall -Wextra -Werror \
    o82-color-profile.cpp $(pkg-config --cflags --libs json-c lcms2 openssl) \
    %{build_ldflags} -o uke-o82-color-profile

%install
install -Dpm755 uke-o82-color-profile %{buildroot}%{_bindir}/uke-o82-color-profile

%check
./uke-o82-color-profile --self-test
clang++ -std=c++20 -O1 -g -UNDEBUG -Wall -Wextra -Werror \
    -fsanitize=address,undefined -fno-omit-frame-pointer \
    o82-color-profile.cpp $(pkg-config --cflags --libs json-c lcms2 openssl) \
    -o color-profile-sanitized
./color-profile-sanitized --self-test

%files
%license LICENSE
%doc O82-COLOR-PROFILE.md
%{_bindir}/uke-o82-color-profile

%changelog
* Sun Nov 01 2026 MCC45TR <75160848+MCC45TR@users.noreply.github.com> - 0.1.0-1
- Generate local OEM P3 ICC mappings with pinned inputs and bounded color data.
