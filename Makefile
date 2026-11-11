SHELL := /bin/bash
.SHELLFLAGS := -Eeuo pipefail -c
.ONESHELL:
.PHONY: validate srpm test-touch-protocol test-touch-transport test-touch-dt
version := 7.3.1
patch_series := 7.3.0
patch_count := 128
outdir ?= $(CURDIR)/build/srpm
.PHONY: refresh-pins check-pins require-unstable-series
refresh-pins:
	bash tools/refresh-source-pins.sh
check-pins:
	bash tools/refresh-source-pins.sh --check
require-unstable-series:
	bash scripts/require-unstable-series.sh "$(version)"
validate: check-pins test-touch-protocol test-touch-transport
	bash tests/storage-crypto-negative-contract.sh
	bash tests/input-capability-inventory.sh
	bash tests/kvm-source-contract.sh
	bash tests/el2-profile-contract.sh
	bash -n tests/usb-role-pm-contract.sh
	bash tests/copr-source-guards-contract.sh
	bash -n tests/msm-retirement-contract.sh tests/msm-writeback-contract.sh tests/msm-retirement-proof-contract.sh
	bash -n tests/o82-avr-contract.sh tests/dpu-video-timing-contract.sh
	bash -n tests/o82-abm-contract.sh packaging/native/copr-o82-abm731.sh
	bash tests/o82-selector-contract.sh
	bash tests/o82-on-batch-contract.sh
	bash -n tests/o82-variants-contract.sh tests/o82-variants-dt-contract.sh src/display/generate-native-panels.sh
	bash -n tests/msm-kms-lifecycle-contract.sh tests/msm-kms-unwind-contract.sh tests/msm-kms-alternate-build.sh
	bash tests/msm-kms-release-contract.sh
	bash -n tests/gunyah-boot-watchdog-contract.sh packaging/native/copr-boot-watchdog61.sh
	bash -n tests/optional-gaming-platform.sh packaging/native/copr-optional-gaming72.sh
	bash -n tests/ucsi-pd-contract.sh
	bash -n tests/battery-protocol-inspect.sh
	bash -n tests/battery-notification-contract.sh
	bash -n tests/pm8010-population-contract.sh
	bash -n tests/clock-debug-fdt-contract.sh tests/cpufreq-boost-error-contract.sh
	bash -n src/power/prepare-cpucp-observe.sh
	bash -n tests/scmi-no-negotiation-contract.sh
	bash -n tests/cpufreq-lmh-lifecycle-contract.sh
	CC=cc bash tests/memlat-scmi-probe-contract.sh src/power/uke-cpucp-observe.c
	bash -n tests/dp-dsc-contract.sh tests/dp-dsc-state-contract.sh
	bash -n tests/dp-fec-status-contract.sh tests/dp-dsc-tu-contract.sh
	bash -n tests/dp-mst-payload-contract.sh tests/dp-mst-control-contract.sh tests/dp-altmode-retimer-contract.sh
	bash -n tests/lid-wake-contract.sh
	bash -n tests/msm-shrinker-policy-contract.sh
	bash -n tests/dp-eld-notification-contract.sh
	bash -n tests/dpu-output-affinity-contract.sh tests/ucsi-debugfs-bounds-contract.sh tests/dpu-mixer-reservation-contract.sh
	bash -n src/leds/prepare-source.sh tests/rgb-policy.sh tests/rgb-lifetime.sh tests/rgb-sysfs.sh tests/rgb-syntax.sh
	bash -n src/video/prepare-source.sh tests/iris-sm7675-caps-contract.sh tests/iris-sm7675-schema-contract.sh
	bash tests/rgb-policy.sh
	bash tests/rgb-supplier.sh
	bash tests/torch-lifetime.sh
	bash tests/torch-supplier.sh
	bash -n tests/light-cleanup.sh tests/light-dt.sh tests/light-brightness.sh tests/flash-thermal-errors.sh
	bash tests/uke-build-scope-contract.sh
	bash -n src/performance/prepare-source.sh tests/llcc-pmu-contract.sh
	CC=clang bash tests/llcc-pmu-contract.sh
	CC=cc bash tests/audio-fs19xx-lifecycle-contract.sh
	bash -n tests/audio-probe-contract.sh
	bash -n tests/microphone-audio-{card,fdt,topology}-contract.sh tests/wcd939x-io-contract.sh tests/soundwire-resume-clock-contract.sh
	bash -n src/boot/check-root-capability.sh tests/root-selector-note-contract.sh
	test "$(version)" = 7.3.1
	jq -e '.version == "$(version)" and .hardware_tested == false and (.patches | length == $(patch_count)) and (.configs | length == 3)' manifests/linux-$(version).json >/dev/null
	jq -e '.version == "$(version)" and .patch_series == "$(patch_series)" and .parent_copr_build == 11230581 and (.patches | length == 122)' manifests/native-linux-$(version).json >/dev/null
	cmp <(jq -r '.patches[].path | split("/") | last' manifests/linux-$(version).json) patches/$(patch_series)/series
	while IFS=$$'\t' read -r path expected; do
		test "$$(sha256sum "$$path" | cut -d ' ' -f1)" = "$$expected"
	done < <(jq -r '.patches[], .configs[] | [.path,.sha256] | @tsv' manifests/linux-$(version).json)
	abi="$$(rpmspec --target aarch64 --define 'dist %{nil}' -q --srpm --qf '%{VERSION}-%{RELEASE}' packaging/senemos-uke-linux-kernel-mainline.spec)"
	jq -e --arg abi "$$abi" '.active_series == true and .dt_enabled == true and .tablet_tested == false and .kernel_release_changed == true and .kernel_release == $$abi and (.patches | length == 3)' manifests/llcc-source-candidate-20261020.json >/dev/null
	while IFS=$$'\t' read -r path expected; do
		test "$$(sha256sum "$$path" | cut -d ' ' -f1)" = "$$expected"
	done < <(jq -r '.patches[], .files[] | [.path,.sha256] | @tsv' manifests/llcc-source-candidate-20261020.json)
	bash -n src/boot/prepare-abl-source.sh src/performance/prepare-llcc-dt.sh tests/llcc-sm7675-contract.sh tests/llcc-sm7675-dt-contract.sh tests/llcc-gpu-startup-contract.sh tests/llcc-boot-fdt-contract.sh
	bash tests/mainline-package-contract.sh
	bash tests/mainline-boot-status-contract.sh
	bash tests/upstream-candidate-contract.sh
	bash tests/touch-runtime-package-contract.sh
	bash tests/prebuilt-helpers-contract.sh
	bash tests/identity-contract.sh
	bash tests/fm19511-contract.sh
	bash tests/hardware-dt.sh
	bash tests/ufs-ice-contract.sh
	bash -n tests/ufs-ice-dt-contract.sh
	bash -n tests/ufs-mcq-contract.sh tests/bwmon-vote-error-contract.sh tests/usbss-kconfig-contract.sh
	bash -n tests/ufs-mcq-allocation-contract.sh
	bash -n tests/bwmon-counter-contract.sh tests/bwmon-dt-contract.sh
	bash -n tests/l3-provider-contract.sh
	bash -n tests/opp-bandwidth-transaction-contract.sh
	bash -n tests/cpu-bwmon-dt-contract.sh
	CXX=clang++ bash tests/cpu-bwmon-dt-contract.sh
	CXX=clang++ bash tests/bwmon-dt-contract.sh
	bash -n tests/mdt-memory-admission-contract.sh tests/mdt-metadata-contract.sh tests/fastrpc-buffer-lifetime-contract.sh tests/rproc-edge-stop-contract.sh
	bash -n tests/qup-interconnect-contract.sh tests/uke-rpmh-resource-contract.sh tests/wpss-proxy-contract.sh
	bash -n tests/pas-stop-ownership-contract.sh tests/rproc-early-stop-contract.sh tests/sysmon-stop-preparation-contract.sh
	bash -n tests/wcd939x-channel-switch-contract.sh tests/wcd939x-probe-error-contract.sh \
	    tests/wcd939x-reset-consumer-contract.sh tests/wcd939x-reset-contract.sh \
	    tests/wcd939x-micbias-contract.sh \
	    tests/wcd939x-supply-order-contract.sh \
	    tests/wcd939x-chip-info-contract.sh \
	    tests/usbss-reset-lifetime-contract.sh tests/soundwire-probe-error-contract.sh \
	    tests/lpass-sm7675-pins-contract.sh tests/audio-providers-fdt-contract.sh
	bash -n src/nfc/prepare-source.sh tests/nfc-syntax.sh tests/ir-spi-contract.sh
	bash tests/kernel-family-contract.sh
	bash tests/userdata-grow-contract.sh
	bash tests/early-modules-contract.sh
	bash -n src/boot/make-initramfs-cpio.sh tests/initramfs-cpio-contract.sh
	bash tests/platform-profile-contract.sh
	bash tests/dispcc-dp-votes-contract.sh src/display/uke-dispcc-votes.c
	bash tests/module-compress-contract.sh
	bash -n tests/resin-wake-contract.sh
	bash -n tests/gpu-fault-capture-contract.sh
test-touch-protocol:
	bash tests/touch-protocol-contract.sh
test-touch-transport:
	bash tests/touch-transport-contract.sh
test-touch-dt:
	test -n "$(kernel_source)" -a -n "$(running_fdt)" -a -n "$(dt_output)"
	bash tests/touch-dt-contract.sh "$(kernel_source)" "$(running_fdt)" "$(dt_output)"
.PHONY: test-ufs-mcq test-root-capability
test-ufs-mcq:
	test -n "$(kernel_source)"
	bash tests/ufs-mcq-contract.sh "$(kernel_source)"
	bash tests/ufs-mcq-allocation-contract.sh "$(kernel_source)"
test-root-capability:
	test -n "$(kernel_source)"
	bash tests/root-selector-note-contract.sh "$(kernel_source)" manifests/boot-payload.json
.PHONY: test-microphones
test-microphones:
	test -n "$(kernel_source)"
	bash tests/microphone-audio-fdt-contract.sh "$(kernel_source)"
	bash tests/microphone-audio-topology-contract.sh
	bash tests/microphone-audio-card-contract.sh
	bash tests/wcd939x-reset-consumer-contract.sh "$(kernel_source)"
	bash tests/wcd939x-io-contract.sh "$(kernel_source)"
	bash tests/soundwire-resume-clock-contract.sh "$(kernel_source)"
.PHONY: test-o82-regdma
test-o82-regdma:
	bash tests/o82-regdma-transport-contract.sh
.PHONY: test-o82-profiles
test-o82-profiles:
	bash tests/o82-profile-loader-contract.sh
srpm: validate
	cache="$(CURDIR)/referances/releases"
	top="$$(realpath -m "$(outdir)/rpmbuild")"
	mkdir -p "$$cache" "$$top"/{BUILD,BUILDROOT,RPMS,SRPMS,SOURCES,SPECS}
	for name in linux-$(version).tar.xz linux-$(version).tar.sign; do
		if test ! -s "$$cache/$$name"; then
			url=$$(jq -er --arg n "$$name" 'if ($$n|endswith(".tar.sign")) then .signature_url else .source_url end' manifests/linux-$(version).json)
			curl -fL --retry 3 --connect-timeout 20 "$$url" -o "$$cache/$$name.part"
			mv "$$cache/$$name.part" "$$cache/$$name"
		fi
	done
	expected=$$(jq -er .source_sha256 manifests/linux-$(version).json)
	test "$$(sha256sum "$$cache/linux-$(version).tar.xz" | cut -d ' ' -f1)" = "$$expected"
	keyring=$$(mktemp -d)
	trap 'gpgconf --homedir "$$keyring" --kill gpg-agent; rm -rf -- "$$keyring"' EXIT
	gpg --batch --homedir "$$keyring" --import configs/keys/linux-stable.asc
	xz -cd "$$cache/linux-$(version).tar.xz" | gpg --batch --homedir "$$keyring" --status-fd=1 --verify "$$cache/linux-$(version).tar.sign" - > "$$top/signature.txt"
	grep -F "[GNUPG:] VALIDSIG $$(jq -er .signer manifests/linux-$(version).json) " "$$top/signature.txt"
	rm -rf "$$top/adaptation"
	mkdir -p "$$top/adaptation/senemos-adaptation"/{patches,configs}
	cp patches/$(patch_series)/* "$$top/adaptation/senemos-adaptation/patches/"
	cp configs/{arm64-qcom,uke,fedora}.config "$$top/adaptation/senemos-adaptation/configs/"
	cp manifests/linux-$(version).json "$$top/adaptation/senemos-adaptation/source-lock.json"
	cp patches/$(patch_series)/README.md "$$top/adaptation/senemos-adaptation/README.md"
	tar --sort=name --mtime=@$$(jq -er .source_date_epoch manifests/linux-$(version).json) --owner=0 --group=0 --numeric-owner -cJf "$$top/SOURCES/senemos-uke-adaptation-$(version).tar.xz" -C "$$top/adaptation" senemos-adaptation
	cp "$$cache/linux-$(version).tar."{xz,sign} configs/keys/linux-stable.asc "$$top/SOURCES/"
	assets="$$(mktemp -d "$$top/profile.XXXXXX")/native-profile"
	mkdir -p "$$assets"
	git archive HEAD src patches manifests/video-linux73-candidate-20261025.json tests | tar -xf - -C "$$assets"
	install -m644 packaging/native/native.config packaging/native/README.md packaging/native/usb-profile packaging/native/audio-profile packaging/native/llcc-profile "$$assets/"
	install -m755 packaging/native/prepare.sh "$$assets/"
	git rev-parse HEAD > "$$assets/source-commit"
	jq -n --arg commit "$$(git rev-parse HEAD)" '{schema_version:1,source_mode:"git-archive",source_commit:$$commit}' > "$$assets/source-composition.json"
	(cd "$$assets"; find . -type f ! -name SHA256SUMS -print0 | LC_ALL=C sort -z | xargs -0 sha256sum > SHA256SUMS)
	tar --sort=name --mtime=@$$(jq -er .source_date_epoch manifests/linux-$(version).json) --owner=0 --group=0 --numeric-owner -cJf "$$top/SOURCES/senemos-native-profile-$(version).tar.xz" -C "$$(dirname "$$assets")" native-profile
	sed "s/^Version: .*/Version: $(version)/" packaging/senemos-uke-linux-kernel-mainline.spec > "$$top/SPECS/senemos-uke-linux-kernel-mainline.spec"
	# Source generation needs no target compiler or installed binary BuildRequires.
	bash scripts/stage-boot-sources.sh "$$top/SOURCES"
	install -m644 packaging/SINGLEBOOT.md "$$top/SOURCES/SINGLEBOOT.md"
	install -m644 LICENSE "$$top/SOURCES/singleboot-LICENSE"
	rpmbuild -bs --nodeps --target aarch64 --define "_topdir $$top" "$$top/SPECS/senemos-uke-linux-kernel-mainline.spec"
	for source_rpm in "$$top/SRPMS/"*.src.rpm; do
		destination="$(outdir)/$${source_rpm##*/}"
		[[ "$$source_rpm" -ef "$$destination" ]] || cp "$$source_rpm" "$$destination"
	done
# A standalone source clone also owns its host build entry and pinned rules.
.PHONY: test-entry
test-entry:
	./senemos.sh --self-test
