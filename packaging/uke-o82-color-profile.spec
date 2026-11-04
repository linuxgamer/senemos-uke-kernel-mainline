Name: uke-o82-color-profile
Version: 0.7.0
Release: 1%{?dist}
Summary: Generate private O82 OEM color mappings and native preset data
License: MIT
URL: https://github.com/MCC45TR/senemos-uke-kernel-mainline
Source0: o82-color-profile.cpp
Source1: O82-COLOR-PROFILE.md
Source2: LICENSE
Source3: uke-o82-hdr-format.h
Source4: o82-hdr-edid-contract.cpp
Source5: o82-regdma.h
# The independent KMS check owns the DMA transport and prepared-kernel fixtures.
# No DMA or kernel transport implementation is installed by this utility.
Source10: o82-color-firmware.h
Source11: dpu_o82_profiles.c
Source12: dpu_o82_profiles.h
Source13: o82-profile-loader-contract.c
Source14: o82-profile-loader-contract.sh
Source15: o82-gamut-grid-contract.cpp
Source16: o82-color-before-grid.cpp
Source17: o82-sixzone-format.h
Source18: o82-sixzone.h
Source19: o82-sixzone-payload-contract.cpp
Source20: o82-sixzone-contract.cpp
Source21: o82-hsic.h
Source22: o82-hsic-format.h
Source23: o82-hsic-payload-contract.cpp
Source24: o82-hsic-contract.cpp
Source25: o82-memory-format.h
Source26: o82-memory-color.h
Source27: o82-memory-payload-contract.cpp
Source28: o82-memory-payload-contract.sh
Source29: dpu_o82_lutbus.c
Source30: dpu_o82_lutbus.h
# GPL fixture sources are not linked into the installed MIT utility.
Source31: GPL-2.0-only.txt
Source32: o82-stock-profile.hpp
Source33: local.hpp
Source34: oem-video.hpp
Source35: o82-stock-profile-contract.cpp
ExclusiveArch: aarch64
BuildRequires: clang gcc-c++ compiler-rt pkgconf-pkg-config
BuildRequires: pkgconfig(json-c) pkgconfig(lcms2) pkgconfig(openssl)
BuildRequires: pkgconfig(libdisplay-info)
Requires: e2fsprogs kmod

%description
Read an exact, hash-verified O82 factory QDCM profile and generate a new private
ICC mapping from its P3 inverse gamma, gamut and output gamma tables. Original
KWin performs color conversion in its existing ICC shader path. The generator
does not modify the backlight, install a desktop profile or
redistribute factory tables. Optical calibration and native HDR10 acceptance
remain separate from OEM-derived P3 mapping and the compositor's existing EDR.
The native-preset preparation command retains each preset's identity and
compiles independent native/BT.2020 and gamma2.2/PQ inputs. Active operations
without a complete implementation remain preserved and explicitly refused;
the file conversion command does not install firmware or advertise new display capabilities.
Private v5 presets carry explicit memory-color and global protection state,
including neutral transitions and protection from disabled regions.
The separate --prepare-kernel command reads the fitted panel's exact stock ODM
profile through a bounded read-only view and prepares private v5 firmware for
an installed, non-running unstable kernel with the required source contract.
It preserves the initial selection and refuses differing existing files.

%prep
cp %{SOURCE0} .
cp %{SOURCE1} .
cp %{SOURCE2} .
cp %{SOURCE3} .
cp %{SOURCE4} .
cp %{SOURCE5} .
cp %{SOURCE10} .
cp %{SOURCE15} .
cp %{SOURCE16} .
cp %{SOURCE17} %{SOURCE18} %{SOURCE19} %{SOURCE20} .
cp %{SOURCE21} %{SOURCE22} %{SOURCE23} %{SOURCE24} .
cp %{SOURCE25} %{SOURCE26} .
cp %{SOURCE31} .
cp %{SOURCE32} %{SOURCE35} .
mkdir -p stock-profile
cp %{SOURCE33} %{SOURCE34} stock-profile/
mkdir -p src/display tests
cp %{SOURCE3} %{SOURCE10} %{SOURCE11} %{SOURCE12} src/display/
cp %{SOURCE17} %{SOURCE22} src/display/
cp %{SOURCE25} src/display/
cp %{SOURCE13} %{SOURCE14} tests/
cp %{SOURCE27} %{SOURCE28} tests/
cp %{SOURCE29} %{SOURCE30} src/display/

%build
g++ -std=c++20 %{optflags} -UNDEBUG -Wall -Wextra -Werror \
    o82-color-profile.cpp $(pkg-config --cflags --libs json-c lcms2 openssl) \
    %{build_ldflags} -o uke-o82-color-profile

%install
install -Dpm755 uke-o82-color-profile %{buildroot}%{_bindir}/uke-o82-color-profile

%check
gcc -std=c11 -Wall -Wextra -Werror -x c -fsyntax-only o82-regdma.h
gcc -std=c11 -Wall -Wextra -Werror -x c -fsyntax-only o82-color-firmware.h
gcc -std=c11 -Wall -Wextra -Werror -x c -fsyntax-only o82-sixzone-format.h
gcc -std=c11 -Wall -Wextra -Werror -x c -fsyntax-only o82-hsic-format.h
./uke-o82-color-profile --self-test
clang++ -std=c++20 -O1 -g -UNDEBUG -Wall -Wextra -Werror \
    -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer \
    o82-color-profile.cpp $(pkg-config --cflags --libs json-c lcms2 openssl) \
    -o color-profile-sanitized
./color-profile-sanitized --self-test
g++ -std=c++20 -O2 -UNDEBUG -Wall -Wextra -Werror -I. \
    -Wl,--wrap=main o82-stock-profile-contract.cpp $(pkg-config --cflags --libs json-c lcms2 openssl) -o stock-profile-contract
./stock-profile-contract
clang++ -std=c++20 -O1 -g -UNDEBUG -Wall -Wextra -Werror -I. \
    -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer \
    -Wl,--wrap=main o82-stock-profile-contract.cpp $(pkg-config --cflags --libs json-c lcms2 openssl) -o stock-profile-sanitized
./stock-profile-sanitized
g++ -std=c++20 -O2 -UNDEBUG -Wall -Wextra -Werror -I. \
    o82-hdr-edid-contract.cpp $(pkg-config --cflags --libs libdisplay-info) -o edid-contract
./edid-contract
bash tests/o82-profile-loader-contract.sh .
bash tests/o82-memory-payload-contract.sh .
g++ -std=c++20 -O2 -UNDEBUG -Wall -Wextra -Werror -I. \
    -Wl,--wrap=main o82-hsic-payload-contract.cpp $(pkg-config --cflags --libs json-c lcms2 openssl) -o hsic-payload
./hsic-payload
clang++ -std=c++20 -O1 -g -UNDEBUG -Wall -Wextra -Werror -I. \
    -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer \
    -Wl,--wrap=main o82-hsic-payload-contract.cpp $(pkg-config --cflags --libs json-c lcms2 openssl) -o hsic-payload-sanitized
./hsic-payload-sanitized
g++ -std=c++20 -O2 -UNDEBUG -Wall -Wextra -Werror -I. o82-hsic-contract.cpp -o hsic-converter
./hsic-converter
clang++ -std=c++20 -O1 -g -UNDEBUG -Wall -Wextra -Werror -I. \
    -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer \
    o82-hsic-contract.cpp -o hsic-converter-sanitized
./hsic-converter-sanitized

g++ -std=c++20 -O2 -UNDEBUG -Wall -Wextra -Werror -I. \
    -Wl,--wrap=main o82-sixzone-payload-contract.cpp $(pkg-config --cflags --libs json-c lcms2 openssl) -o sixzone-payload
./sixzone-payload
clang++ -std=c++20 -O1 -g -UNDEBUG -Wall -Wextra -Werror -I. \
    -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer \
    -Wl,--wrap=main o82-sixzone-payload-contract.cpp $(pkg-config --cflags --libs json-c lcms2 openssl) -o sixzone-payload-sanitized
./sixzone-payload-sanitized
g++ -std=c++20 -O2 -UNDEBUG -Wall -Wextra -Werror -I. \
    o82-sixzone-contract.cpp -o sixzone-converter
./sixzone-converter
g++ -std=c++20 -O2 -UNDEBUG -Wall -Wextra -Werror -I. \
    -Wl,--wrap=main o82-gamut-grid-contract.cpp $(pkg-config --cflags --libs json-c lcms2 openssl) -o gamut-grid
./gamut-grid
clang++ -std=c++20 -O1 -g -UNDEBUG -Wall -Wextra -Werror -I. \
    -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer \
    -Wl,--wrap=main o82-gamut-grid-contract.cpp $(pkg-config --cflags --libs json-c lcms2 openssl) -o gamut-grid-sanitized
./gamut-grid-sanitized
g++ -std=c++20 -O2 -UNDEBUG -Wall -Wextra -Werror -I. \
    -DO82_COLOR_IMPLEMENTATION='"o82-color-before-grid.cpp"' \
    -Wl,--wrap=main o82-gamut-grid-contract.cpp $(pkg-config --cflags --libs json-c lcms2 openssl) -o gamut-grid-before
set +e
./gamut-grid-before > gamut-grid-before.log 2>&1
before_status=$?
set -e
test "$before_status" = 1
grep -E '^OEM gamut grid regression rejected: [1-9][0-9]*/[0-9]+ checks failed$' gamut-grid-before.log

%files
%license LICENSE
%doc O82-COLOR-PROFILE.md
%{_bindir}/uke-o82-color-profile

%changelog
* Thu Nov 05 2026 Uke contributors - 0.7.0-1
- Prepare private fitted-panel v5 data from exact read-only stock ODM input.
- Admit installed inactive unstable candidates and publish without replacement.
- Check admission, private permissions, failed writes and concurrent publication.

* Thu Nov 05 2026 Uke contributors - 0.6.0-3
- Preserve system UAPI integer types in the mixed C/C++ pipeline fixture.
- Include the existing GPL license text with the native fixture sources.

* Thu Nov 05 2026 Uke contributors - 0.6.0-2
- Correct the typed value hold-control field used by memory conversion.

* Thu Nov 05 2026 Uke contributors - 0.6.0-1
- Compile OEM memory-color fields and protection into private v5 presets.
- Check actual JSON, bundle, kernel loader and paired command encoding together.
- Preserve v4 loading and the observed O82 skin saturation edge conversion.

* Wed Nov 04 2026 Uke contributors - 0.5.0-1
- Compile explicit active and neutral HSIC into a bounded private v4 bundle.
- Validate composed PA state, actual parser/loader and scalar rounding contracts.

* Wed Nov 04 2026 Uke contributors - 0.4.0-1
- Encode bounded active SixZone state in private v3 bundles with legacy curve selection.
- Validate actual parser, shared PA semantics and native loader using synthetic data.
- Retain unsupported HSIC, memory-color and HDR operations as explicit refusals.

* Wed Nov 04 2026 MCC45TR <75160848+MCC45TR@users.noreply.github.com> - 0.3.0-6
- Redirect only the fixture entry at link time and retain strict production diagnostics.

* Wed Nov 04 2026 MCC45TR <75160848+MCC45TR@users.noreply.github.com> - 0.3.0-5
- Use the OEM 12-bit input grid for factory interpolation and native LUT sampling.
- Require independent synthetic regressions and rejection of the actual former source.
- Keep kernel DMA qualification in its complete retained KMS check.

* Sun Nov 01 2026 MCC45TR <75160848+MCC45TR@users.noreply.github.com> - 0.3.0-4
- Use the upstream generator command for a header without a top-level Make target.

* Sun Nov 01 2026 MCC45TR <75160848+MCC45TR@users.noreply.github.com> - 0.3.0-3
- Include the pinned upstream MSM generated header in the remote kernel-object check.

* Sun Nov 01 2026 MCC45TR <75160848+MCC45TR@users.noreply.github.com> - 0.3.0-2
- Load and select validated private root-resident presets in native kernel C.
- Check refusal, four input combinations and firmware lifetime with synthetic data.
- Preserve enabled IGC dithering found in the real OEM preset input.

* Sun Nov 01 2026 MCC45TR <75160848+MCC45TR@users.noreply.github.com> - 0.3.0-1
- Compile distinct native-gamut/BT.2020 and gamma2.2/PQ preset inputs.
- Preserve active unsupported operations and refuse them instead of aliasing profiles.

* Sun Nov 01 2026 MCC45TR <75160848+MCC45TR@users.noreply.github.com> - 0.2.0-9
- Check the actual native REGDMA transport with completion and failed-reset faults.

* Sun Nov 01 2026 MCC45TR <75160848+MCC45TR@users.noreply.github.com> - 0.2.0-8
- Keep the DMA refusal fixture distinct from existing parser-failure state.

* Sun Nov 01 2026 MCC45TR <75160848+MCC45TR@users.noreply.github.com> - 0.2.0-7
- Verify Cliffs register-DMA descriptor alignment, aperture and length bounds.

* Sun Nov 01 2026 MCC45TR <75160848+MCC45TR@users.noreply.github.com> - 0.2.0-6
- Check both OEM input gamuts and gate HDR descriptors on a native converter.

* Sun Nov 01 2026 MCC45TR <75160848+MCC45TR@users.noreply.github.com> - 0.2.0-5
- Use a base EDID revision that permits all native timings in DisplayID.

* Sun Nov 01 2026 MCC45TR <75160848+MCC45TR@users.noreply.github.com> - 0.2.0-4
- Require a conformant native timing and HDR descriptor in the metadata fixture.

* Sun Nov 01 2026 MCC45TR <75160848+MCC45TR@users.noreply.github.com> - 0.2.0-3
- Use the KWin-compatible leading-matrix LUT16 profile and validate serialized stages.

* Sun Nov 01 2026 MCC45TR <75160848+MCC45TR@users.noreply.github.com> - 0.2.0-2
- Use libdisplay-info's C linkage in the compositor capability fixture.

* Sun Nov 01 2026 MCC45TR <75160848+MCC45TR@users.noreply.github.com> - 0.2.0-1
- Generate bounded native PQ and BT.2020 color data and verify KDE EDID inputs.

* Sun Nov 01 2026 MCC45TR <75160848+MCC45TR@users.noreply.github.com> - 0.1.0-2
- Build the installed binary with Fedora's matching GCC hardening flags.

* Sun Nov 01 2026 MCC45TR <75160848+MCC45TR@users.noreply.github.com> - 0.1.0-1
- Generate local OEM P3 ICC mappings with pinned inputs and bounded color data.
