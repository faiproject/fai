include VERSION

DESTDIR=debian/tmp
KERNEL=/usr/src/kernel-source-$(KERNELVERSION)
DOCDIR=/usr/share/doc/fai
DEB_HOST_ARCH=$(MACHTYPE)
LIBDIR = $(DESTDIR)/usr/lib/fai
SCRIPTS = rcS_fai setup_harddisks install_packages faireboot start-stop-daemon
SBIN_SCRIPTS = mk3comimage make-fai-nfsroot
KERNEL_FILES = System.map bzImage config emptydosdisk.gz imagegen_firstblock

# files with variable KERNLEVERSION in it
KVERSION_FILES = $(DESTDIR)/$(DOCDIR)/templates/package_config/KERNEL_SOFT $(DESTDIR)/$(DOCDIR)/templates/class/S91global.source $(DESTDIR)/$(DOCDIR)/templates/class/S98variables.source

FVERSION_FILES = $(LIBDIR)/sbin/rcS_fai

# don't forget 3c90x patch, Thomas !
kernel/bzImage: kernel/config
	mv $(KERNEL)/.config $(KERNEL)/.config.pre_fai
	cp kernel/config $(KERNEL)/.config
	cd $(KERNEL) && make oldconfig clean dep bzImage > /tmp/make.log
	cp $(KERNEL)/arch/$(DEB_HOST_ARCH)/boot/bzImage kernel/bzImage
	cp $(KERNEL)/System.map kernel/System.map
	mv $(KERNEL)/.config.pre_fai $(KERNEL)/.config

cleankernel:
	rm kernel/bzImage kernel/System.map
	cd $(KERNEL) && make clean >/dev/null
	rm -rf /tmp/make.log

clean:
	rm -f /tmp/make.log

install: kernel/bzImage
	cd scripts ; install $(SBIN_SCRIPTS) $(DESTDIR)/usr/sbin
	cd kernel ; install -m644 $(KERNEL_FILES) $(LIBDIR)/kernel
	cd scripts ; install $(SCRIPTS) $(LIBDIR)/sbin
	install -m644 conf/apt.conf $(LIBDIR)/etc/
	install -m644 conf/apt.conf.nfsroot $(LIBDIR)/etc
	install -m644 lib/Fai.pm $(DESTDIR)/usr/lib/perl5/Debian
	scripts/mk3comimage -r `pwd`/kernel kernel/bzImage $(DESTDIR)/boot/fai/installimage /dev/nfs
	cp -dRp examples templates doc/* $(DESTDIR)/$(DOCDIR)
	perl -pi -e 's/KERNELVERSION/$(KERNELVERSION)/' $(KVERSION_FILES)
	perl -pi -e 's/FAIVERSIONSTRING/$(VERSIONSTRING)/' $(FVERSION_FILES)
	ln -fs installimage $(DESTDIR)/boot/fai/faiserver
	ln -fs installimage $(DESTDIR)/boot/fai/faiclient01
	ln -fs /usr/local/share/fai/fai_config/global.conf $(DESTDIR)/etc/fai.conf

.PHONY: clean cleankernel


