include VERSION

SHELL=/bin/bash
DESTDIR=$(shell pwd)/debian/tmp
export DOCDIR = $(shell pwd)/debian/fai-doc/usr/share/doc/fai-doc
LIBDIR = $(DESTDIR)/usr/lib/fai
SHAREDIR = $(DESTDIR)/usr/share/fai
USRSBIN_SCRIPTS = make-fai-nfsroot fai-setup fcopy ftar install_packages fai-chboot faimond fai-cd fai setup_harddisks faireboot fai-statoverride setup-storage dhcp-edit
USRBIN_SCRIPTS = fai-class fai-do-scripts fai-mirror fai-debconf device2grub policy-rc.d.fai ainsl faimond-gui

# do not include .svn dir and setup-storage subdir
libfiles=$(patsubst lib/setup-storage,,$(wildcard lib/[a-z]*))

all:
	$(MAKE) -C doc all

clean:
	find -name svn-commit\*.tmp -o -name svn-commit.tmp~ | xargs -r rm
	$(MAKE) -C doc clean

veryclean: clean
	$(MAKE) -f debian/rules clean

install: 
	mkdir -p $(DESTDIR)/{sbin,man} $(DESTDIR)/etc/{modutils,apt/apt.conf.d}
	mkdir -p $(DESTDIR)/usr/{sbin,bin} $(DESTDIR)/usr/lib/fai $(DESTDIR)/etc/fai/apt
	mkdir -p $(DESTDIR)/etc/{init,init.d} $(DESTDIR)/usr/share/fai/{pixmaps/small,setup-storage}
	install man/* $(DESTDIR)/man
	pod2man -c '' -r '' -s8 bin/dhcp-edit > $(DESTDIR)/man/dhcp-edit.8
	$(MAKE) -C doc install
	-install $(libfiles) $(LIBDIR)
	install lib/setup-storage/* $(SHAREDIR)/setup-storage
	cd bin ; install $(USRSBIN_SCRIPTS) $(DESTDIR)/usr/sbin
	cd bin ; install $(USRBIN_SCRIPTS) $(DESTDIR)/usr/bin
	install bin/fai-start-stop-daemon $(DESTDIR)/sbin
	install bin/dhclient-fai-script  $(DESTDIR)/usr/share/fai
	install -m644 conf/dhclient-fai.conf $(DESTDIR)/usr/share/fai
	install -m644 conf/apt.conf $(DESTDIR)/etc/apt/apt.conf.d/90fai
	cd conf ; install -m644 fai.conf menu.lst grub.cfg live.conf $(DESTDIR)/etc/fai/
	install -m644 conf/make-fai-nfsroot.conf $(DESTDIR)/etc/fai/
	install -m644 conf/sources.list $(DESTDIR)/etc/fai/apt/
	install -m644 conf/NFSROOT $(DESTDIR)/etc/fai
	install -m644 conf/fai_modules_off $(DESTDIR)/etc/modutils
	install -m644 conf/menu.lst.boot-only $(DESTDIR)/usr/share/fai/menu.lst
	install -m644 conf/upstart-fai.conf $(DESTDIR)/etc/init/fai.conf
	install -m755 lib/fai-abort $(DESTDIR)/etc/init.d
	install -p -m644 pixmaps/*.gif $(DESTDIR)/usr/share/fai/pixmaps
	perl -pi -e 's/FAIVERSIONSTRING/$(VERSIONSTRING)/' $(DESTDIR)/usr/sbin/fai
	cp -a examples $(DOCDIR)
	cp -a utils $(DOCDIR)/examples
	find $(DOCDIR) -name .svn | xargs rm -rf

.PHONY: clean veryclean
