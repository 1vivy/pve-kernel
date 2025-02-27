include /usr/share/dpkg/pkg-info.mk

-include ubuntu-kernel_env.mk
# TODO: also bump proxmox-kernel-meta if the default MAJ.MIN version changes!
KERNEL_SHA1 ?= cod/mainline/v6.6-rc5
ZFS_SHA1 ?= zfs-2.2.0
# increment KREL for every published package release!
# rebuild packages with new KREL and run 'make abiupdate'

KERNEL_MAJMIN=$(KERNEL_MAJ).$(KERNEL_MIN)
KERNEL_VER=$(KERNEL_MAJMIN).$(KERNEL_PATCHLEVEL)

EXTRAVERSION=$(KERNEL_EXTRAVERSION)-$(KREL)-pve
KVNAME=$(KERNEL_VER)$(EXTRAVERSION)
PACKAGE=proxmox-kernel-$(KVNAME)
HDRPACKAGE=proxmox-headers-$(KVNAME)

ARCH=$(shell dpkg-architecture -qDEB_BUILD_ARCH)

# amd64/x86_64/x86 share the arch subdirectory in the kernel, 'x86' so we need
# a mapping
KERNEL_ARCH=x86
ifneq ($(ARCH), amd64)
KERNEL_ARCH=$(ARCH)
endif

SKIPABI=1

BUILD_DIR=proxmox-kernel-$(KERNEL_VER)

KERNEL_SRC=ubuntu-kernel
KERNEL_SRC_SUBMODULE=submodules/$(KERNEL_SRC)
KERNEL_CFG_ORG=config-$(KERNEL_VER).org

ZFSONLINUX_SUBMODULE=submodules/zfsonlinux
ZFSDIR=pkg-zfs

MODULES=modules
MODULE_DIRS=$(ZFSDIR)

# exported to debian/rules via debian/rules.d/dirs.mk
DIRS=KERNEL_SRC ZFSDIR MODULES

DSC=proxmox-kernel-$(KERNEL_MAJMIN)_$(KERNEL_VER)$(KERNEL_EXTRAVERSION)-$(KREL).dsc
DST_DEB=$(PACKAGE)_$(KERNEL_VER)$(KERNEL_EXTRAVERSION)-$(KREL)_$(ARCH).deb
META_DEB=proxmox-kernel-$(KERNEL_MAJMIN)_$(KERNEL_VER)$(KERNEL_EXTRAVERSION)-$(KREL)_all.deb
HDR_DEB=$(HDRPACKAGE)_$(KERNEL_VER)$(KERNEL_EXTRAVERSION)-$(KREL)_$(ARCH).deb
META_HDR_DEB=proxmox-headers-$(KERNEL_MAJMIN)_$(KERNEL_VER)$(KERNEL_EXTRAVERSION)-$(KREL)_all.deb
USR_HDR_DEB=proxmox-kernel-libc-dev_$(KERNEL_VER)$(KERNEL_EXTRAVERSION)-$(KREL)_$(ARCH).deb
LINUX_TOOLS_DEB=linux-tools-$(KERNEL_MAJMIN)_$(KERNEL_VER)$(KERNEL_EXTRAVERSION)-$(KREL)_$(ARCH).deb
LINUX_TOOLS_DBG_DEB=linux-tools-$(KERNEL_MAJMIN)-dbgsym_$(KERNEL_VER)$(KERNEL_EXTRAVERSION)-$(KREL)_$(ARCH).deb

DEBS=$(DST_DEB) $(META_DEB) $(HDR_DEB) $(META_HDR_DEB) $(LINUX_TOOLS_DEB) $(LINUX_TOOLS_DBG_DEB) # $(USR_HDR_DEB)

all: deb
deb: $(DEBS)

$(META_DEB) $(META_HDR_DEB) $(LINUX_TOOLS_DEB) $(HDR_DEB): $(DST_DEB)
$(DST_DEB): $(BUILD_DIR).prepared
	cd $(BUILD_DIR); dpkg-buildpackage --jobs=auto -b -uc -us
	lintian $(DST_DEB)
	#lintian $(HDR_DEB)
	lintian $(LINUX_TOOLS_DEB)

dsc:
	$(MAKE) $(DSC)
	lintian $(DSC)

$(DSC): $(BUILD_DIR).prepared
	cd $(BUILD_DIR); dpkg-buildpackage -S -uc -us -d

sbuild: $(DSC)
	sbuild $(DSC)

$(BUILD_DIR).prepared: $(addsuffix .prepared,$(KERNEL_SRC) $(MODULES) debian)
	cp -a fwlist-previous $(BUILD_DIR)/
	cp -a abi-prev-* $(BUILD_DIR)/
	cp -a abi-blacklist $(BUILD_DIR)/
	touch $@

.PHONY: build-dir-fresh
build-dir-fresh:
	$(MAKE) clean
	$(MAKE) extract-kernel-version
	$(MAKE) $(BUILD_DIR).prepared
	echo "created build-directory: $(BUILD_DIR).prepared/"

debian.prepared: debian
	rm -rf $(BUILD_DIR)/debian
	mkdir -p $(BUILD_DIR)
	cp -a debian $(BUILD_DIR)/debian
	echo -e "git clone $(shell git remote get-url origin)\ngit checkout $(shell git rev-parse HEAD)\n" \
	    "git clone $(shell git config --file .gitmodules submodule.$(KERNEL_SRC_SUBMODULE).url)\ngit checkout $(shell git submodule status $(KERNEL_SRC_SUBMODULE) | cut -d' ' -f2)" \
	    >$(BUILD_DIR)/debian/SOURCE
	@$(foreach dir, $(DIRS),echo "$(dir)=$($(dir))" >> $(BUILD_DIR)/debian/rules.d/env.mk;)
	echo "KVNAME=$(KVNAME)" >> $(BUILD_DIR)/debian/rules.d/env.mk
	echo "KERNEL_MAJMIN=$(KERNEL_MAJMIN)" >> $(BUILD_DIR)/debian/rules.d/env.mk
	cd $(BUILD_DIR); debian/rules debian/control
	touch $@

$(KERNEL_SRC).prepared: $(KERNEL_SRC_SUBMODULE)
	rm -rf $(BUILD_DIR)/$(KERNEL_SRC) $@
	mkdir -p $(BUILD_DIR)
	cp -a $(KERNEL_SRC_SUBMODULE) $(BUILD_DIR)/$(KERNEL_SRC)
# TODO: split for archs, track and diff in our repository?
	cd $(BUILD_DIR)/$(KERNEL_SRC); python3 debian/scripts/misc/annotations --arch amd64 --export >../../$(KERNEL_CFG_ORG)
	cp $(KERNEL_CFG_ORG) $(BUILD_DIR)/$(KERNEL_SRC)/.config
	sed -i $(BUILD_DIR)/$(KERNEL_SRC)/Makefile -e 's/^EXTRAVERSION.*$$/EXTRAVERSION=$(EXTRAVERSION)/'
	rm -rf $(BUILD_DIR)/$(KERNEL_SRC)/debian $(BUILD_DIR)/$(KERNEL_SRC)/debian.master
	set -e; cd $(BUILD_DIR)/$(KERNEL_SRC); \
	  for patch in ../../patches/kernel/*.patch; do \
	    echo "applying patch '$$patch'"; \
	    patch --batch -p1 < "$${patch}"; \
	  done
	touch $@

$(MODULES).prepared: $(addsuffix .prepared,$(MODULE_DIRS))
	touch $@

$(ZFSDIR).prepared: $(ZFSONLINUX_SUBMODULE)
	rm -rf $(BUILD_DIR)/$(MODULES)/$(ZFSDIR) $(BUILD_DIR)/$(MODULES)/tmp $@
	mkdir -p $(BUILD_DIR)/$(MODULES)/tmp
	cp -a $(ZFSONLINUX_SUBMODULE)/* $(BUILD_DIR)/$(MODULES)/tmp
	cd $(BUILD_DIR)/$(MODULES)/tmp; make kernel SHA1=$(ZFS_SHA1)
	rm -rf $(BUILD_DIR)/$(MODULES)/tmp
	touch $(ZFSDIR).prepared

# extract kernel version
extract-kernel-version:
	rm -f ubuntu-kernel_env.mk
	$(eval VERSION := $(shell grep "^VERSION =" $(KERNEL_SRC_SUBMODULE)/Makefile | cut -d' ' -f3))
	$(eval PATCHLEVEL := $(shell grep "^PATCHLEVEL =" $(KERNEL_SRC_SUBMODULE)/Makefile | cut -d' ' -f3))
	$(eval SUBLEVEL := $(shell grep "^SUBLEVEL =" $(KERNEL_SRC_SUBMODULE)/Makefile | cut -d' ' -f3))
	$(eval KEXTRAVERSION := $(shell grep "^EXTRAVERSION =" $(KERNEL_SRC_SUBMODULE)/Makefile | cut -d' ' -f3))
	$(eval KERNEL_MAJ := $(VERSION))
	$(eval KERNEL_MIN := $(PATCHLEVEL))
	$(eval KERNEL_PATCHLEVEL := $(SUBLEVEL))
	$(eval KERNEL_EXTRAVERSION := $(KEXTRAVERSION))
# totally not inline shell function
	$(eval ABINUM := $(shell echo $(KERNEL_MAJ).$(KERNEL_MIN).$(KERNEL_PATCHLEVEL)-$(KERNEL_EXTRAVERSION) | awk -F'[.-]' '{ for (i = 1; i <= NF; i++) { if ($$i ~ /^[0-9][0-9]*$$/) { printf("%02d", $$i); } else { printf("%s", $$i); } } }'))
	$(eval KREL := $(ABINUM)$(shell date +%y%m%d%H%M))

	echo "KERNEL_MAJ=$(KERNEL_MAJ)" >> ubuntu-kernel_env.mk
	echo "KERNEL_MIN=$(KERNEL_MIN)" >> ubuntu-kernel_env.mk
	echo "KERNEL_PATCHLEVEL=$(KERNEL_PATCHLEVEL)" >> ubuntu-kernel_env.mk
	echo "KERNEL_EXTRAVERSION=$(KERNEL_EXTRAVERSION)" >> ubuntu-kernel_env.mk
	echo "KREL=$(KREL)" >> ubuntu-kernel_env.mk

# shallow clone the ubuntu mainline repo at a specific SHA1
clone-mainline:
	git submodule update --init --depth 1 submodules/ubuntu-kernel
	cd $(KERNEL_SRC_SUBMODULE); git fetch --depth 1 origin +refs/tags/$(KERNEL_SHA1):refs/tags/$(KERNEL_SHA1); git reset --hard $(KERNEL_SHA1)

debian-changelog:
	rm -f debian/changelog
	sed -e 's/@KVMAJMIN@/$(KERNEL_MAJMIN)/g' -e 's/@KVER@/$(KERNEL_VER)$(KERNEL_EXTRAVERSION)-$(KREL)/g' -e 's|@KSHA1@|$(KERNEL_SHA1)|g' \
		-e 's/@BUILDTIME@/$(shell date +"%a, %d %b %Y %T %z")/g' < debian/changelog.in > debian/changelog

debian-lintian:
	rm -f debian/source/lintian-overrides
	sed -e 's/@KVMAJMIN@/$(KERNEL_MAJMIN)/g' < debian/source/lintian-overrides.in > debian/source/lintian-overrides

.PHONY: prep
prep: submodule	clone-mainline extract-kernel-version debian-changelog debian-lintian
	cd $(ZFSONLINUX_SUBMODULE); make prep SHA1=$(ZFS_SHA1)

.PHONY: upload
upload: UPLOAD_DIST ?= $(DEB_DISTRIBUTION)
upload: $(DEBS)
	tar cf - $(DEBS)|ssh -X repoman@repo.proxmox.com -- upload --product pve,pmg,pbs --dist $(UPLOAD_DIST) --arch $(ARCH)

.PHONY: distclean
distclean: clean
	git submodule deinit --all

# upgrade to current master
.PHONY: update_modules
update_modules: submodule
	cd $(ZFSONLINUX_SUBMODULE); git pull --ff-only origin master

# make sure submodules were initialized
.PHONY: submodule
submodule:
	test -f "$(KERNEL_SRC_SUBMODULE)/README" || git submodule update --init $(KERNEL_SRC_SUBMODULE)
	test -f "$(ZFSONLINUX_SUBMODULE)/Makefile" || git submodule update --init --recursive $(ZFSONLINUX_SUBMODULE)

# call after ABI bump with header deb in working directory
.PHONY: abiupdate
abiupdate: abi-prev-$(KVNAME)
abi-prev-$(KVNAME): abi-tmp-$(KVNAME)
ifneq ($(strip $(shell git status --untracked-files=no --porcelain -z)),)
	@echo "working directory unclean, aborting!"
	@false
else
	git rm "abi-prev-*"
	mv $< $@
	git add $@
	git commit -s -m "update ABI file for $(KVNAME)" -m "(generated with debian/scripts/abi-generate)"
	@echo "update abi-prev-$(KVNAME) committed!"
endif

abi-tmp-$(KVNAME):
	@ test -e $(HDR_DEB) || (echo "need $(HDR_DEB) to extract ABI data!" && false)
	debian/scripts/abi-generate $(HDR_DEB) $@ $(KVNAME) 1

.PHONY: clean
clean:
	rm -rf *~ proxmox-kernel-[0-9]*/ *.prepared $(KERNEL_CFG_ORG)
	rm -f *.deb *.dsc *.changes *.buildinfo *.build proxmox-kernel*.tar.*
