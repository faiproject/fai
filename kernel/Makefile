include ../VERSION

# don't forget 3c90x patch, Thomas !

# where I can build the kernel
ramdisk=/tmp/ram
DEB_HOST_ARCH=$(MACHTYPE)
KERNEL=/$(ramdisk)/kernel-source-$(KERNELVERSION)
BOOTP_REVISION=BOOTP1
DHCP_REVISION=DHCP1
BOOTPKERNEL=kernel-image-$(KERNELVERSION)_$(BOOTP_REVISION)_$(DEB_HOST_ARCH).deb
DHCPKERNEL=kernel-image-$(KERNELVERSION)_$(DHCP_REVISION)_$(DEB_HOST_ARCH).deb
KERNEL_FILES = emptydosdisk.gz imagegen_firstblock

# kernel using BOOTP protocol
.config-bootp: kernel-config fai-kernel-config-bootp
	cat kernel-config fai-kernel-config-bootp > .config-bootp

$(BOOTPKERNEL): $(ramdisk)/$(BOOTPKERNEL)
	cp -p $(ramdisk)/$(BOOTPKERNEL) .

$(ramdisk)/$(BOOTPKERNEL): .config-bootp
	cp -p .config-bootp $(KERNEL)
	cd $(KERNEL) ; \
	echo -e "\t\n\n" | make menuconfig ; \
	make-kpkg clean ; \
	fakeroot make-kpkg --revision $(BOOTP_REVISION) kernel-image 

# kernel using DHCP protocol
.config-dhcp: kernel-config fai-kernel-config-bootp enable-dhcp
	cat kernel-config fai-kernel-config-bootp enable-dhcp > .config-dhcp

$(DHCPKERNEL): $(ramdisk)/$(DHCPKERNEL)
	cp -p $(ramdisk)/$(DHCPKERNEL) .

$(ramdisk)/$(DHCPKERNEL): .config-dhcp
	cp -p .config-dhcp $(KERNEL)
	cd $(KERNEL) ; \
	echo -e "\t\n\n" | make menuconfig ; \
	make-kpkg clean ; \
	fakeroot make-kpkg --revision $(DHCP_REVISION) kernel-image 

all: $(BOOTPKERNEL) $(DHCPKERNEL)

install:
	install -m644 kernel-image*.deb $(KERNEL_FILES) $(LIBDIR)/kernel


clean:
	cd $(KERNEL) ; make-kpkg clean
	rm -f .config-bootp .config-dhcp $(BOOTPKERNEL) $(DHCPKERNEL)
