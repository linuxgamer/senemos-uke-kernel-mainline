SHELL := /bin/bash
.SHELLFLAGS := -Eeuo pipefail -c
.ONESHELL:
.PHONY: srpm
srpm:
	version=$$(sed -n 's/^version := //p' Makefile)
	bash scripts/require-unstable-series.sh "$$version"
	# COPR runs source generation as root in its isolated Fedora mock chroot.
	dnf -y --setopt=install_weak_deps=False install make curl jq gnupg2 xz tar rpm-build coreutils git-core gcc gcc-c++ dtc libfdt-devel clang compiler-rt
	# COPR collects this directory as an unprivileged user. Keep verification
	# state and the private-mode GPG home in the source workspace, not outdir.
	$(MAKE) -f Makefile srpm outdir="$(CURDIR)/build/copr-source"
	mkdir -p "$(outdir)"
	install -m644 build/copr-source/*.src.rpm "$(outdir)/"
