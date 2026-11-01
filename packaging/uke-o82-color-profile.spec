Name: uke-o82-color-profile
Version: 0.3.0
Release: 4%{?dist}
Summary: Generate private O82 OEM color mappings and native preset data
License: MIT
URL: https://github.com/MCC45TR/senemos-uke-kernel-mainline
Source0: o82-color-profile.cpp
Source1: O82-COLOR-PROFILE.md
Source2: LICENSE
Source3: uke-o82-hdr-format.h
Source4: o82-hdr-edid-contract.cpp
Source5: o82-regdma.h
Source6: dpu_o82_regdma.c
Source7: dpu_o82_regdma.h
Source8: o82-regdma-transport-contract.c
Source9: o82-regdma-transport-contract.sh
Source10: o82-color-firmware.h
Source11: dpu_o82_profiles.c
Source12: dpu_o82_profiles.h
Source13: o82-profile-loader-contract.c
Source14: o82-profile-loader-contract.sh
ExclusiveArch: aarch64
BuildRequires: clang gcc-c++ compiler-rt pkgconf-pkg-config
BuildRequires: pkgconfig(json-c) pkgconfig(lcms2) pkgconfig(openssl)
BuildRequires: pkgconfig(libdisplay-info)

%description
Read an exact, hash-verified O82 factory QDCM profile and generate a new private
ICC mapping from its P3 inverse gamma, gamut and output gamma tables. Original
KWin performs color conversion in its existing ICC shader path. The generator
does not access hardware, modify the backlight, install a desktop profile or
redistribute factory tables. Optical calibration and native HDR10 acceptance
remain separate from OEM-derived P3 mapping and the compositor's existing EDR.
The native-preset preparation command retains each preset's identity and
compiles independent native/BT.2020 and gamma2.2/PQ inputs. Active operations
without a complete implementation remain preserved and explicitly refused;
the command does not install firmware or advertise new display capabilities.

%prep
cp %{SOURCE0} .
cp %{SOURCE1} .
cp %{SOURCE2} .
cp %{SOURCE3} .
cp %{SOURCE4} .
cp %{SOURCE5} .
cp %{SOURCE10} .
mkdir -p src/display tests
cp %{SOURCE5} %{SOURCE6} %{SOURCE7} src/display/
cp %{SOURCE3} %{SOURCE10} %{SOURCE11} %{SOURCE12} src/display/
cp %{SOURCE8} %{SOURCE9} tests/
cp %{SOURCE13} %{SOURCE14} tests/

%build
g++ -std=c++20 %{optflags} -UNDEBUG -Wall -Wextra -Werror \
    o82-color-profile.cpp $(pkg-config --cflags --libs json-c lcms2 openssl) \
    %{build_ldflags} -o uke-o82-color-profile

%install
install -Dpm755 uke-o82-color-profile %{buildroot}%{_bindir}/uke-o82-color-profile

%check
gcc -std=c11 -Wall -Wextra -Werror -x c -fsyntax-only o82-regdma.h
gcc -std=c11 -Wall -Wextra -Werror -x c -fsyntax-only o82-color-firmware.h
./uke-o82-color-profile --self-test
clang++ -std=c++20 -O1 -g -UNDEBUG -Wall -Wextra -Werror \
    -fsanitize=address,undefined -fno-omit-frame-pointer \
    o82-color-profile.cpp $(pkg-config --cflags --libs json-c lcms2 openssl) \
    -o color-profile-sanitized
./color-profile-sanitized --self-test
g++ -std=c++20 -O2 -UNDEBUG -Wall -Wextra -Werror -I. \
    o82-hdr-edid-contract.cpp $(pkg-config --cflags --libs libdisplay-info) -o edid-contract
./edid-contract
bash tests/o82-regdma-transport-contract.sh .
bash tests/o82-profile-loader-contract.sh .

%files
%license LICENSE
%doc O82-COLOR-PROFILE.md
%{_bindir}/uke-o82-color-profile

%changelog
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
