include ../VERSION

# where I can build the kernel. I have a very huge ramdisk (160MB)
kerneldir=/tmp/ram

DEB_HOST_ARCH=$(MACHTYPE)
KERNEL=$(kerneldir)/kernel-source-$(KERNELVERSION)
BOOTP_REVISION=BOOTP1
DHCP_REVISION=DHCP1
BOOTPKERNEL=kernel-image-$(KERNELVERSION)_$(BOOTP_REVISION)_$(DEB_HOST_ARCH).deb
DHCPKERNEL=kernel-image-$(KERNELVERSION)_$(DHCP_REVISION)_$(DEB_HOST_ARCH).deb
KERNEL_FILES = emptydosdisk.gz imagegen_firstblock

$(KERNEL): /usr/src/kernel-source-$(KERNELVERSION).tar.bz2
	mkdir -p $(kerneldir); cd $(kerneldir) ;\
	tar Ixf /usr/src/kernel-source-$(KERNELVERSION).tar.bz2
	touch $(KERNEL)

# kernel using BOOTP protocol
.config-bootp: kernel-config fai-kernel-config-bootp
	cat kernel-config fai-kernel-config-bootp > .config-bootp

$(BOOTPKERNEL): $(kerneldir)/$(BOOTPKERNEL)
	cp -p $(kerneldir)/$(BOOTPKERNEL) .

$(kerneldir)/$(BOOTPKERNEL): .config-bootp
	cp -p .config-bootp $(KERNEL)/.config
	cd $(KERNEL) ; \
	echo -e "\t\n\n" | make menuconfig ; \
	make-kpkg clean ; \
	fakeroot make-kpkg --revision $(BOOTP_REVISION) kernel-image 

# kernel using DHCP protocol
.config-dhcp: kernel-config fai-kernel-config-bootp enable-dhcp
	cat kernel-config fai-kernel-config-bootp enable-dhcp > .config-dhcp

$(DHCPKERNEL): $(kerneldir)/$(DHCPKERNEL)
	cp -p $(kerneldir)/$(DHCPKERNEL) .

$(kerneldir)/$(DHCPKERNEL): .config-dhcp
	cp -p .config-dhcp $(KERNEL)/.config
	cd $(KERNEL) ; \
	echo -e "\t\n\n" | make menuconfig ; \
	make-kpkg clean ; \
	fakeroot make-kpkg --revision $(DHCP_REVISION) kernel-image 

kernels: $(KERNEL) $(BOOTPKERNEL) $(DHCPKERNEL)

all: $(BOOTPKERNEL) $(DHCPKERNEL)

install:
	install -m644 $(BOOTPKERNEL) $(DHCPKERNEL) $(KERNEL_FILES) $(LIBDIR)/kernel


clean:
	rm -f $(BOOTPKERNEL) $(DHCPKERNEL)

veryclean: clean
	rm -rf $(KERNEL) .config-bootp .config-dhcp

.PHONY: clean veryclean kernels
