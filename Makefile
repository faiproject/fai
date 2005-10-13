include VERSION

DESTDIR=$(shell pwd)/debian/tmp
export DOCDIR = $(shell pwd)/debian/fai-doc/usr/share/doc/fai-doc
LIBDIR = $(DESTDIR)/usr/lib/fai
USRSBIN_SCRIPTS = make-fai-nfsroot make-fai-bootfloppy fai-setup fcopy ftar install_packages fai-chboot faimond fai-cd fai setup_harddisks faireboot dhclient-perl

USRBIN_SCRIPTS = fai-class fai-do-scripts fai-mirror fai-debconf device2grub
CONFFILES= 
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
	mkdir -p $(DESTDIR)/{sbin,man} $(DESTDIR)/etc/{fai,modutils,dhcp3,apt.conf.d}
	mkdir -p $(DESTDIR)/usr/{sbin,bin} $(DESTDIR)/usr/lib/fai
	install man/* $(DESTDIR)/man
	$(MAKE) -C doc install
	-install $(libfiles) $(LIBDIR)
	cd scripts ; install $(USRSBIN_SCRIPTS) $(DESTDIR)/usr/sbin
	cd scripts ; install $(USRBIN_SCRIPTS) $(DESTDIR)/usr/bin
	install scripts/start-stop-daemon $(DESTDIR)/sbin
	install scripts/dhclient-script  $(DESTDIR)/etc/dhcp3
	install -m644 conf/dhclient.conf $(DESTDIR)/etc/dhcp3
#	install -m644 share/Fai.pm $(DESTDIR)/usr/share/perl5/Debian
	install -m644 conf/apt.conf $(DESTDIR)/etc/apt.conf.d/90fai
	install -m644 conf/fai.conf conf/sources.list conf/menu.lst $(DESTDIR)/etc/fai/
	install -m600 conf/make-fai-nfsroot.conf $(DESTDIR)/etc/fai/
	install -m600 conf/fai_modules_off $(DESTDIR)/etc/modutils
	perl -pi -e 's/_KERNELVERSION_/$(KERNELVERSION)/' $(KVERSION_FILES)
	perl -pi -e 's/FAIVERSIONSTRING/$(VERSIONSTRING)/' $(DESTDIR)/usr/sbin/fai
	cp -a examples $(DOCDIR)
	cp -a utils $(DOCDIR)/examples
	cp -a templates/* $(DOCDIR)/examples/advanced
	cd $(DOCDIR)/examples/advanced/scripts ; mv DEFAULT1 DEFAULT
	cd $(DOCDIR)/examples/simple/scripts ; mv LAST1 LAST

.PHONY: clean veryclean
