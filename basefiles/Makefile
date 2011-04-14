# basefiles/Makefile (c) 2011 Michael Goetze <mgoetze@mgoetze.net>
#
# Usage example: sudo make SQUEEZE64.tar.xz
#
# This Makefile can build .tar.xz and .tar.gz basefiles for:
# Debian GNU/Linux 6.0 (SQUEEZE32, SQUEEZE64)
# Ubuntu 10.04 (LUCID32, LUCID64)
# CentOS 5 (CENTOS5_32, CENTOS5_64)
#
# Packages you might want to install to use this Makefile:
# debootstrap, rinse, xz-utils

ifndef BASEFILEDIR
BASEFILEDIR:=$(shell mktemp -d /tmp/basefiles.XXXXXXXX)
endif
export BASEFILEDIR
MIRROR_DEBIAN=http://cdn.debian.net/debian/
MIRROR_UBUNTU=http://ftp.halifax.rwth-aachen.de/ubuntu/
#MIRROR_CENTOS=http://mirror.netcologne.de/centos/
# For the first stage, set the CentOS mirror in /etc/rinse/rinse.conf
# For the second stage, it is not so easy, due to #612164
EXCLUDE_SQUEEZE=isc-dhcp-client,isc-dhcp-common,info,tasksel,tasksel-data
EXCLUDE_LUCID=dhcp3-client,dhcp3-common
RINSEOPT_CENTOS=--distribution centos-5
XZ=xz -8
GZ=gzip -9

.PHONY: check cleanup-deb cleanup-rinse all32 all64 all

check::
	@if [ `id -u` != 0 ]; then echo "You must be root to create chroots."; exit 1; fi
	@mknod ${BASEFILEDIR}/test-dev-null c 1 3 || (echo "Cannot create device files on ${BASEFILEDIR}, aborting."; rm -rf ${BASEFILEDIR}; exit 1)
	@echo test > ${BASEFILEDIR}/test-dev-null || (echo "Cannot use device files on ${BASEFILEDIR}, aborting."; rm -rf ${BASEFILEDIR}; exit 1)
	@rm -f ${BASEFILEDIR}/test-dev-null

cleanup-deb::
	chroot ${BASEFILEDIR} aptitude clean
	rm ${BASEFILEDIR}/etc/hostname
	rm ${BASEFILEDIR}/etc/resolv.conf
	rm ${BASEFILEDIR}/etc/udev/rules.d/70-persistent-net.rules || true
	rm ${BASEFILEDIR}/var/lib/apt/lists/*_*

cleanup-rinse::
	rm ${BASEFILEDIR}/etc/resolv.conf
	cp ${BASEFILEDIR}/etc/modprobe.d/modprobe.conf.dist ${BASEFILEDIR}/etc/modprobe.conf

CENTOS5_32.tar.xz: check
	linux32 rinse --directory ${BASEFILEDIR} ${RINSEOPT_CENTOS} --arch i386
	$(MAKE) cleanup-rinse
	tar --one-file-system -C ${BASEFILEDIR} -cf - . | ${XZ} > $@
	rm -rf ${BASEFILEDIR}

CENTOS5_32.tar.gz: check
	linux32 rinse --directory ${BASEFILEDIR} ${RINSEOPT_CENTOS} --arch i386
	$(MAKE) cleanup-rinse
	tar --one-file-system -C ${BASEFILEDIR} -cf - . | ${GZ} > $@
	rm -rf ${BASEFILEDIR}

CENTOS5_64.tar.xz: check
	rinse --directory ${BASEFILEDIR} ${RINSEOPT_CENTOS} --arch amd64
	$(MAKE) cleanup-rinse
	tar --one-file-system -C ${BASEFILEDIR} -cf - . | ${XZ} > $@
	rm -rf ${BASEFILEDIR}

CENTOS5_64.tar.gz: check
	rinse --directory ${BASEFILEDIR} ${RINSEOPT_CENTOS} --arch amd64
	$(MAKE) cleanup-rinse
	tar --one-file-system -C ${BASEFILEDIR} -cf - . | ${GZ} > $@
	rm -rf ${BASEFILEDIR}

LUCID32.tar.xz: check
	debootstrap --arch i386 --exclude=${EXCLUDE_LUCID} lucid ${BASEFILEDIR} ${MIRROR_UBUNTU}
	$(MAKE) cleanup-deb
	tar --one-file-system -C ${BASEFILEDIR} -cf - . | ${XZ} > $@
	rm -rf ${BASEFILEDIR}

LUCID32.tar.gz: check
	debootstrap --arch i386 --exclude=${EXCLUDE_LUCID} lucid ${BASEFILEDIR} ${MIRROR_UBUNTU}
	$(MAKE) cleanup-deb
	tar --one-file-system -C ${BASEFILEDIR} -cf - . | ${GZ} > $@
	rm -rf ${BASEFILEDIR}

LUCID64.tar.xz: check
	debootstrap --arch amd64 --exclude=${EXCLUDE_LUCID} lucid ${BASEFILEDIR} ${MIRROR_UBUNTU}
	$(MAKE) cleanup-deb
	tar --one-file-system -C ${BASEFILEDIR} -cf - . | ${XZ} > $@ 
	rm -rf ${BASEFILEDIR}

LUCID64.tar.gz: check
	debootstrap --arch amd64 --exclude=${EXCLUDE_LUCID} lucid ${BASEFILEDIR} ${MIRROR_UBUNTU}
	$(MAKE) cleanup-deb
	tar --one-file-system -C ${BASEFILEDIR} -cf - . | ${GZ} > $@ 
	rm -rf ${BASEFILEDIR}

SQUEEZE32.tar.xz: check
	debootstrap --arch i386 --exclude=${EXCLUDE_SQUEEZE} squeeze ${BASEFILEDIR} ${MIRROR_DEBIAN}
	$(MAKE) cleanup-deb
	tar --one-file-system -C ${BASEFILEDIR} -cf - . | ${XZ} > $@
	rm -rf ${BASEFILEDIR}

SQUEEZE32.tar.gz: check
	debootstrap --arch i386 --exclude=${EXCLUDE_SQUEEZE} squeeze ${BASEFILEDIR} ${MIRROR_DEBIAN}
	$(MAKE) cleanup-deb
	tar --one-file-system -C ${BASEFILEDIR} -cf - . | ${GZ} > $@
	rm -rf ${BASEFILEDIR}

SQUEEZE64.tar.xz: check
	debootstrap --arch amd64 --exclude=${EXCLUDE_SQUEEZE} squeeze ${BASEFILEDIR} ${MIRROR_DEBIAN}
	$(MAKE) cleanup-deb
	tar --one-file-system -C ${BASEFILEDIR} -cf - . | ${XZ} > $@ 
	rm -rf ${BASEFILEDIR}

SQUEEZE64.tar.gz: check
	debootstrap --arch amd64 --exclude=${EXCLUDE_SQUEEZE} squeeze ${BASEFILEDIR} ${MIRROR_DEBIAN}
	$(MAKE) cleanup-deb
	tar --one-file-system -C ${BASEFILEDIR} -cf - . | ${GZ} > $@ 
	rm -rf ${BASEFILEDIR}

all32: CENTOS5_32.tar.xz LUCID32.tar.xz SQUEEZE32.tar.xz

all64: CENTOS5_64.tar.xz LUCID64.tar.xz SQUEEZE64.tar.xz

all: all32 all64
