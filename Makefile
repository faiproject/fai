DESTDIR=debian/tmp

KERNELVERSION=2.2.15
KERNEL=/usr/src/kernel-source-$(KERNELVERSION)
DEB_HOST_ARCH=$(MACHTYPE)
libdir = $(DESTDIR)/usr/lib/fai
SCRIPTS = rcS_fai setup_harddisks install_packages faireboot
SBIN_SCRIPTS = mk3comimage make-fai-nfsroot
KERNEL_FILES = System.map bzImage.install config-$(KERNELVERSION) emptydosdisk.gz imagegen_firstblock

# don't forget 3com patch
kernel/bzImage.install: kernel/config-$(KERNELVERSION)
	mv $(KERNEL)/.config $(KERNEL)/.config.pre_fai
	cp kernel/config-$(KERNELVERSION) $(KERNEL)/.config
	cd $(KERNEL) && make oldconfig clean dep bzImage > /tmp/make.log
	cp $(KERNEL)/arch/$(DEB_HOST_ARCH)/boot/bzImage kernel/bzImage.install
	cp $(KERNEL)/System.map kernel/System.map
	mv $(KERNEL)/.config.pre_fai $(KERNEL)/.config

cleankernel:
	rm kernel/bzImage.install kernel/System.map
	cd $(KERNEL) && make clean >/dev/null
	rm -rf /tmp/make.log

clean:
	rm -f /tmp/make.log

install: kernel/bzImage.install
	cd scripts ; install $(SBIN_SCRIPTS) $(DESTDIR)/usr/sbin
	cd kernel ; install -m644 $(KERNEL_FILES) $(libdir)/kernel
	install -m644 conf/apt.conf $(libdir)/etc/
	install -m644 conf/apt.conf.nfsroot $(libdir)/etc
	install -m644 lib/Fai.pm $(DESTDIR)/usr/lib/perl5/Debian
	scripts/mk3comimage -r `pwd`/kernel kernel/bzImage.install $(DESTDIR)/boot/fai/installimage /dev/nfs
	cp -dRp examples $(DESTDIR)/usr/share/doc/fai
	cp -dRp templates $(DESTDIR)/usr/share/doc/fai
	cp -dRp doc/* $(DESTDIR)/usr/share/doc/fai
	cd scripts ; install $(SCRIPTS) $(libdir)/sbin
	ln -fs installimage $(DESTDIR)/boot/fai/faiserver
	ln -fs installimage $(DESTDIR)/boot/fai/faiclient01
	ln -fs /usr/local/share/fai/fai_config/global.conf $(DESTDIR)/etc/fai.conf

.PHONY: clean cleankernel
