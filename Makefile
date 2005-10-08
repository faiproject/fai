include VERSION

DESTDIR=$(shell pwd)/debian/fai
DEB_HOST_ARCH=$(MACHTYPE)
export DOCDIR = $(shell pwd)/debian/fai-doc/usr/share/doc/fai-doc
LIBDIR = $(DESTDIR)/usr/lib/fai
SHAREDIR = $(DESTDIR)/usr/share/fai
SCRIPTSDIR = $(LIBDIR)/sbin
SCRIPTS =  setup_harddisks faireboot dhclient-perl dhclient-script
USRSBIN_SCRIPTS = make-fai-nfsroot make-fai-bootfloppy fai-setup fcopy ftar install_packages fai-chboot faimond fai-cd fai
SBIN= fai-start-stop-daemon
USRBIN_SCRIPTS = fai-class fai-do-scripts fai-mirror fai-debconf
CONFDIR= $(SHAREDIR)/etc
CONFFILES= apt.conf dhclient.conf fai_modules_off
ADEXAMPLE=$(DOCDIR)/examples/advanced
SIEXAMPLE=$(DOCDIR)/examples/simple
BEOEXAMPLE=$(DOCDIR)/examples/beowulf
libfiles=$(wildcard lib/[a-z]*)  # do not include CVS dir

# files with variable KERNLEVERSION in it; this string will be substituted
KVERSION_FILES =  $(DESTDIR)/etc/fai/make-fai-nfsroot.conf

all:
	$(MAKE) -C doc all

clean:
	$(MAKE) -C doc clean

veryclean: clean
	$(MAKE) -f debian/rules clean

install: 
	$(MAKE) -C doc install
	-install -m755 $(libfiles) $(LIBDIR)
	-install -m755 scripts/device2grub $(LIBDIR)
	cd scripts ; install $(SBIN) $(DESTDIR)/sbin
	cd scripts ; install $(USRSBIN_SCRIPTS) $(DESTDIR)/usr/sbin
	cd scripts ; install $(USRBIN_SCRIPTS) $(DESTDIR)/usr/bin
	cd scripts ; install $(SCRIPTS) $(SCRIPTSDIR)
	install -m755 share/subroutines* $(SHAREDIR)
	install -m644 share/Fai.pm $(DESTDIR)/usr/share/perl5/Debian
	cd conf ; install -m644 $(CONFFILES) $(CONFDIR)
	install -m644 conf/menu.lst conf/sources.list $(DESTDIR)/etc/fai/
	install -m644 conf/fai.conf conf/sources.list $(DESTDIR)/etc/fai/
	install -m600 conf/make-fai-nfsroot.conf $(DESTDIR)/etc/fai/
	cp -a examples $(DOCDIR)
	cp -a utils $(DOCDIR)/examples
	cp -a templates/* $(DOCDIR)/examples/advanced
	cd $(DOCDIR)/examples/advanced/scripts ; mv DEFAULT1 DEFAULT
	cd $(DOCDIR)/examples/simple/scripts ; mv LAST1 LAST
	perl -pi -e 's/_KERNELVERSION_/$(KERNELVERSION)/' $(KVERSION_FILES)
	perl -pi -e 's/FAIVERSIONSTRING/$(VERSIONSTRING)/' $(DESTDIR)/usr/sbin/fai

.PHONY: clean veryclean
