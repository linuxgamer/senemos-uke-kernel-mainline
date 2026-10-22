SHELL := /bin/bash
.SHELLFLAGS := -Eeuo pipefail -c
.ONESHELL:
.PHONY: validate srpm
version := 7.2.11
outdir ?= $(CURDIR)/build/srpm
validate:
	test "$(version)" = 7.2.11
	jq -e '.version == "$(version)" and .hardware_tested == false and (.patches | length == 81) and (.configs | length == 3)' manifests/linux-$(version).json >/dev/null
	cmp <(jq -r '.patches[].path | split("/") | last' manifests/linux-$(version).json) patches/$(version)/series
	while IFS=$$'\t' read -r path expected; do
		test "$$(sha256sum "$$path" | cut -d ' ' -f1)" = "$$expected"
	done < <(jq -r '.patches[], .configs[] | [.path,.sha256] | @tsv' manifests/linux-$(version).json)
	bash tests/mainline-package-contract.sh
srpm: validate
	cache="$(CURDIR)/referances/releases"
	top="$$(realpath -m "$(outdir)/rpmbuild")"
	mkdir -p "$$cache" "$$top"/{BUILD,BUILDROOT,RPMS,SRPMS,SOURCES,SPECS}
	for name in linux-$(version).tar.xz linux-$(version).tar.sign; do
		if test ! -s "$$cache/$$name"; then
			curl -fL --retry 3 --connect-timeout 20 "https://cdn.kernel.org/pub/linux/kernel/v7.x/$$name" -o "$$cache/$$name.part"
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
	cp patches/$(version)/* "$$top/adaptation/senemos-adaptation/patches/"
	cp configs/{arm64-qcom,uke,fedora}.config "$$top/adaptation/senemos-adaptation/configs/"
	cp manifests/linux-$(version).json "$$top/adaptation/senemos-adaptation/source-lock.json"
	cp patches/$(version)/README.md "$$top/adaptation/senemos-adaptation/README.md"
	tar --sort=name --mtime=@$$(jq -er .source_date_epoch manifests/linux-$(version).json) --owner=0 --group=0 --numeric-owner -cJf "$$top/SOURCES/senemos-uke-adaptation-$(version).tar.xz" -C "$$top/adaptation" senemos-adaptation
	cp "$$cache/linux-$(version).tar."{xz,sign} configs/keys/linux-stable.asc "$$top/SOURCES/"
	assets="$$(mktemp -d "$$top/profile.XXXXXX")/native-profile"
	mkdir -p "$$assets"
	git archive HEAD src/display src/boot src/usb src/audio patches/$(version) patches/display patches/boot tests | tar -xf - -C "$$assets"
	install -m644 packaging/native/native.config packaging/native/README.md packaging/native/usb-profile packaging/native/audio-profile "$$assets/"
	install -m755 packaging/native/prepare.sh "$$assets/"
	git rev-parse HEAD > "$$assets/source-commit"
	(cd "$$assets"; find . -type f ! -name SHA256SUMS -print0 | LC_ALL=C sort -z | xargs -0 sha256sum > SHA256SUMS)
	tar --sort=name --mtime=@$$(jq -er .source_date_epoch manifests/linux-$(version).json) --owner=0 --group=0 --numeric-owner -cJf "$$top/SOURCES/senemos-native-profile-$(version).tar.xz" -C "$$(dirname "$$assets")" native-profile
	sed "s/^Version: .*/Version: $(version)/" packaging/senemos-uke-linux-kernel-mainline.spec > "$$top/SPECS/senemos-uke-linux-kernel-mainline.spec"
	# Source generation needs no target compiler or installed binary BuildRequires.
	bash scripts/stage-boot-sources.sh "$$top/SOURCES"
	rpmbuild -bs --nodeps --target aarch64 --define "_topdir $$top" "$$top/SPECS/senemos-uke-linux-kernel-mainline.spec"
	cp "$$top/SRPMS/"*.src.rpm "$(outdir)/"
# A standalone source clone also owns its host build entry and pinned rules.
.PHONY: test-entry
test-entry:
	./senemos.sh --self-test
