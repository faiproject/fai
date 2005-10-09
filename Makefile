include VERSION

DESTDIR=$(shell pwd)/debian/tmp
DEB_HOST_ARCH=$(MACHTYPE)
export DOCDIR = $(shell pwd)/debian/fai-doc/usr/share/doc/fai-doc
LIBDIR = $(DESTDIR)/usr/lib/fai
USRSBIN_SCRIPTS = make-fai-nfsroot make-fai-bootfloppy fai-setup fcopy ftar install_packages fai-chboot faimond fai-cd fai setup_harddisks faireboot fai-start-stop-daemon dhclient-perl dhclient-script

USRBIN_SCRIPTS = fai-class fai-do-scripts fai-mirror fai-debconf
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
	mkdir -p $(DESTDIR)/man $(DESTDIR)/etc/fai $(DESTDIR)/etc/modutils
	mkdir -p $(DESTDIR)/usr/{sbin,bin} $(DESTDIR)/usr/lib/fai
	install man/* $(DESTDIR)/man
	$(MAKE) -C doc install
	-install -m755 $(libfiles) $(LIBDIR)
	cd scripts ; install $(USRSBIN_SCRIPTS) $(DESTDIR)/usr/sbin
	cd scripts ; install $(USRBIN_SCRIPTS) $(DESTDIR)/usr/bin
#	install -m644 share/Fai.pm $(DESTDIR)/usr/share/perl5/Debian
	install -m644 conf/apt.conf conf/dhclient.conf $(DESTDIR)/etc/fai/
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
