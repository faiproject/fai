include VERSION

DESTDIR=$(shell pwd)/debian/fai
DEB_HOST_ARCH=$(MACHTYPE)
DOCDIR=/usr/share/doc/fai
LIBDIR = $(DESTDIR)/usr/lib/fai
SHAREDIR = $(DESTDIR)/usr/share/fai
SCRIPTS = rcS_fai setup_harddisks install_packages faireboot start-stop-daemon dhclient-perl dhclient-script fcopy ftar mount2dir bootsector device2grub
SBIN_SCRIPTS = make-fai-nfsroot make-fai-bootfloppy fai-setup fcopy ftar bootsector
CONFFILES= apt.conf dhclient.conf fai_modules_off pxelinux.cfg

# files with variable KERNLEVERSION in it; this string will be substituted
KVERSION_FILES =  $(DESTDIR)/etc/fai/fai.conf $(SHAREDIR)/templates/class/DEFAULT.var $(SHAREDIR)/templates/class/ATOMCLIENT.var $(SHAREDIR)/templates/class/pittermaennche.var

all:
	$(MAKE) -C doc all

clean:
	$(MAKE) -C doc clean

veryclean: clean
	$(MAKE) -f debian/rules clean

install: 
	$(MAKE) -C doc install DOCDIR=$(DOCDIR)
	cd scripts ; install $(SBIN_SCRIPTS) $(DESTDIR)/usr/sbin
	cd scripts ; install $(SCRIPTS) $(LIBDIR)/sbin
	install -m644 share/subroutines* $(SHAREDIR)
	install -m644 share/Fai.pm $(DESTDIR)/usr/share/perl5/Debian
	cd conf ; install -m644 $(CONFFILES) $(SHAREDIR)/etc/
	install -m644 conf/fai.conf $(DESTDIR)/etc/fai/
	cp -a examples $(DESTDIR)/$(DOCDIR)
	cp -a utils templates $(SHAREDIR)
	cd $(SHAREDIR)/templates/scripts ; mv NETWORK1 NETWORK; mv DEFAULT1 DEFAULT
	perl -pi -e 's/_KERNELVERSION_/$(KERNELVERSION)/' $(KVERSION_FILES)
	perl -pi -e 's/FAIVERSIONSTRING/$(VERSIONSTRING)/' $(LIBDIR)/sbin/rcS_fai
	ln -fs installimage_3com $(DESTDIR)/boot/fai/bigfoot
	ln -fs installimage_3com $(DESTDIR)/boot/fai/ant01
	ln -fs installimage_3com $(DESTDIR)/boot/fai/atom_install

.PHONY: clean veryclean
