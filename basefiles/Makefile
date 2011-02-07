# basefiles/Makefile (c) 2011 Michael Goetze <mgoetze@mgoetze.net>
#
# Usage example: sudo make SQUEEZE64.tar.xz
#
# This Makefile can build .tar.xz and .tar.gz basefiles for:
# Debian GNU/Linux 6.0 (SQUEEZE32, SQUEEZE64)
# Ubuntu 10.04 (LUCID32, LUCID64)
# CentOS 5 (CENTOS5-32, CENTOS5-64)
#
# Packages you might want to install to use this Makefile:
# debootstrap, rinse, xz-utils

TMPDIR=/tmp/debootstrap-fai
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
	@if [ -d ${TMPDIR} ]; then echo "${TMPDIR} already exists, aborting."; exit 1; fi
	@if [ `id -u` != 0 ]; then echo "You must be root to create chroots."; exit 1; fi
	@mkdir -p ${TMPDIR}
	@mknod "${TMPDIR}/test-dev-null" c 1 3 || (echo "Cannot create device files on ${TMPDIR}, aborting."; rm -rf ${TMPDIR}; exit 1)
	@echo test > "${TMPDIR}/test-dev-null" || (echo "Cannot use device files on ${TMPDIR}, aborting."; rm -rf ${TMPDIR}; exit 1)
	@rm -f "${TMPDIR}/test-dev-null"

cleanup-deb::
	chroot ${TMPDIR} aptitude clean
	rm ${TMPDIR}/etc/hostname
	rm ${TMPDIR}/etc/resolv.conf
	rm ${TMPDIR}/etc/udev/rules.d/70-persistent-net.rules || true
	rm ${TMPDIR}/var/lib/apt/lists/*_*

cleanup-rinse::
	rm ${TMPDIR}/etc/resolv.conf
	cp ${TMPDIR}/etc/modprobe.d/modprobe.conf.dist ${TMPDIR}/etc/modprobe.conf

CENTOS5-32.tar.xz: check
	linux32 rinse --directory ${TMPDIR} ${RINSEOPT_CENTOS} --arch i386
	$(MAKE) cleanup-rinse
	tar --one-file-system -C ${TMPDIR} -cf - . | ${XZ} > $@
	rm -rf ${TMPDIR}

CENTOS5-32.tar.gz: check
	linux32 rinse --directory ${TMPDIR} ${RINSEOPT_CENTOS} --arch i386
	$(MAKE) cleanup-rinse
	tar --one-file-system -C ${TMPDIR} -cf - . | ${GZ} > $@
	rm -rf ${TMPDIR}

CENTOS5-64.tar.xz: check
	rinse --directory ${TMPDIR} ${RINSEOPT_CENTOS} --arch amd64
	$(MAKE) cleanup-rinse
	tar --one-file-system -C ${TMPDIR} -cf - . | ${XZ} > $@
	rm -rf ${TMPDIR}

CENTOS5-64.tar.gz: check
	rinse --directory ${TMPDIR} ${RINSEOPT_CENTOS} --arch amd64
	$(MAKE) cleanup-rinse
	tar --one-file-system -C ${TMPDIR} -cf - . | ${GZ} > $@
	rm -rf ${TMPDIR}

LUCID32.tar.xz: check
	debootstrap --arch i386 --exclude=${EXCLUDE_LUCID} lucid ${TMPDIR} ${MIRROR_UBUNTU}
	$(MAKE) cleanup-deb
	tar --one-file-system -C ${TMPDIR} -cf - . | ${XZ} > $@
	rm -rf ${TMPDIR}

LUCID32.tar.gz: check
	debootstrap --arch i386 --exclude=${EXCLUDE_LUCID} lucid ${TMPDIR} ${MIRROR_UBUNTU}
	$(MAKE) cleanup-deb
	tar --one-file-system -C ${TMPDIR} -cf - . | ${GZ} > $@
	rm -rf ${TMPDIR}

LUCID64.tar.xz: check
	debootstrap --arch amd64 --exclude=${EXCLUDE_LUCID} lucid ${TMPDIR} ${MIRROR_UBUNTU}
	$(MAKE) cleanup-deb
	tar --one-file-system -C ${TMPDIR} -cf - . | ${XZ} > $@ 
	rm -rf ${TMPDIR}

LUCID64.tar.gz: check
	debootstrap --arch amd64 --exclude=${EXCLUDE_LUCID} lucid ${TMPDIR} ${MIRROR_UBUNTU}
	$(MAKE) cleanup-deb
	tar --one-file-system -C ${TMPDIR} -cf - . | ${GZ} > $@ 
	rm -rf ${TMPDIR}

SQUEEZE32.tar.xz: check
	debootstrap --arch i386 --exclude=${EXCLUDE_SQUEEZE} squeeze ${TMPDIR} ${MIRROR_DEBIAN}
	$(MAKE) cleanup-deb
	tar --one-file-system -C ${TMPDIR} -cf - . | ${XZ} > $@
	rm -rf ${TMPDIR}

SQUEEZE32.tar.gz: check
	debootstrap --arch i386 --exclude=${EXCLUDE_SQUEEZE} squeeze ${TMPDIR} ${MIRROR_DEBIAN}
	$(MAKE) cleanup-deb
	tar --one-file-system -C ${TMPDIR} -cf - . | ${GZ} > $@
	rm -rf ${TMPDIR}

SQUEEZE64.tar.xz: check
	debootstrap --arch amd64 --exclude=${EXCLUDE_SQUEEZE} squeeze ${TMPDIR} ${MIRROR_DEBIAN}
	$(MAKE) cleanup-deb
	tar --one-file-system -C ${TMPDIR} -cf - . | ${XZ} > $@ 
	rm -rf ${TMPDIR}

SQUEEZE64.tar.gz: check
	debootstrap --arch amd64 --exclude=${EXCLUDE_SQUEEZE} squeeze ${TMPDIR} ${MIRROR_DEBIAN}
	$(MAKE) cleanup-deb
	tar --one-file-system -C ${TMPDIR} -cf - . | ${GZ} > $@ 
	rm -rf ${TMPDIR}

all32: CENTOS5-32.tar.xz LUCID32.tar.xz SQUEEZE32.tar.xz

all64: CENTOS5-64.tar.xz LUCID64.tar.xz SQUEEZE64.tar.xz

all: all32 all64
