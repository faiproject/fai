include VERSION

SHELL=/bin/bash
DESTDIR=$(shell pwd)/debian/tmp
export DOCDIR = $(shell pwd)/debian/fai-doc/usr/share/doc/fai-doc
LIBDIR = $(DESTDIR)/usr/lib/fai
SHAREDIR = $(DESTDIR)/usr/share/fai
USRSBIN_SCRIPTS = fai-make-nfsroot fai-setup fcopy ftar install_packages fai-chboot fai-monitor fai-cd fai faireboot fai-statoverride setup-storage dhcp-edit fai-new-mac

USRBIN_SCRIPTS = fai-class fai-do-scripts fai-mirror fai-debconf device2grub policy-rc.d.fai ainsl fai-monitor-gui fai-deps

# for syntax checks
BASH_SCRIPTS = bin/fai bin/fai-cd bin/fai-class bin/fai-debconf bin/fai-do-scripts bin/fai-make-nfsroot bin/fai-mirror bin/fai-setup bin/fai-statoverride bin/faireboot bin/ftar dev-utils/fai-kvm dev-utils/fai-mk-network examples/simple/basefiles/mk-basefile examples/simple/class/*.sh examples/simple/class/[0-9]* examples/simple/files/etc/rc.local/FAISERVER examples/simple/hooks/* examples/simple/scripts/*/* lib/fai-divert lib/fai-mount-disk lib/fai-savelog lib/fetch-basefile lib/get-boot-info lib/get-config-dir* lib/mkramdisk lib/mount2dir lib/prcopyleft lib/subroutines lib/task_* lib/updatebase lib/dracut/*/*
SHELL_SCRIPTS = bin/dhclient-fai-script bin/policy-rc.d.fai lib/check_status lib/create_resolv_conf lib/fai-abort lib/fai-disk-info lib/load_keymap_consolechars utils/mkdebmirror
PERL_SCRIPTS = lib/setup-storage/*.pm bin/ainsl bin/device2grub bin/dhcp-edit bin/fai-chboot bin/fai-deps bin/fai-monitor bin/fai-monitor-gui bin/fai-new-mac bin/fcopy bin/install_packages bin/setup-storage dev-utils/setup-storage_deps-graph.pl examples/simple/tests/Faitest.pm lib/dhclient-perl lib/fai-savelog-ftp

# do not include .svn dir and setup-storage subdir
libfiles=$(patsubst lib/setup-storage,,$(wildcard lib/[a-z]*))

all:
	$(MAKE) syntaxcheck
	$(MAKE) -C doc all

syntaxcheck: bashismcheck shellcheck perlcheck

bashismcheck:
	@if [ -x "$$(which checkbashisms 2>/dev/null)" ]; then \
		echo -n "Checking for bashisms"; \
		for SCRIPT in $(SHELL_SCRIPTS); do \
			test -r $${SCRIPT} || continue ; \
			ec=0 ; \
			checkbashisms -x $${SCRIPT} || ec=$$? ; \
			if [ $${ec} -ne 0 ] && [ $${ec} -ne 2 ] ; then exit $${ec} ; fi ; \
			echo -n "."; \
		done; \
		echo " done."; \
	else \
		echo "W: checkbashisms - command not found"; \
		echo "I: checkbashisms can be optained from: "; \
		echo "I:   http://git.debian.org/?p=devscripts/devscripts.git"; \
		echo "I: On Debian systems, checkbashisms can be installed with:"; \
		echo "I:   apt-get install devscripts"; \
	fi

shellcheck:
	@echo -n "Checking for shell syntax errors"; \
	for SCRIPT in $(BASH_SCRIPTS) $(SHELL_SCRIPTS); do \
		test -r $${SCRIPT} || continue ; \
		bash -n $${SCRIPT} || exit ; \
		echo -n "."; \
	done; \
	echo " done."; \

perlcheck:
	@echo "Checking for perl syntax errors:"; \
	mkdir -p perl-dummy/Linux perl-dummy/Tk ; \
	for f in Linux/LVM.pm Tk.pm Tk/HList.pm Tk/ItemStyle.pm; do \
		echo '1;' > perl-dummy/$$f ; \
	done; \
	for SCRIPT in $(PERL_SCRIPTS); do \
		test -r $${SCRIPT} || continue ; \
		perl -Iperl-dummy/ -Ilib/setup-storage/ -w -c $${SCRIPT} || exit ; \
	done; \
	rm -r perl-dummy ; \
	echo "-> perl check done."; \

clean:
	rm -rf perl-dummy
	$(MAKE) -C doc clean

veryclean: clean
	$(MAKE) -f debian/rules clean

install:
	mkdir -p $(DESTDIR)/{sbin,man} $(DESTDIR)/etc/{modutils,apt/apt.conf.d}
	mkdir -p $(DESTDIR)/usr/{sbin,bin} $(DESTDIR)/usr/lib/fai $(DESTDIR)/etc/fai/apt
	mkdir -p $(DESTDIR)/etc/{init,init.d} $(DESTDIR)/usr/share/fai/{pixmaps/small,setup-storage}
	mkdir -p $(DESTDIR)/usr/lib/dracut/modules.d
	install man/* $(DESTDIR)/man
	pod2man -c '' -r '' -s8 bin/dhcp-edit > $(DESTDIR)/man/dhcp-edit.8
	pod2man -c '' -r '' -s8 bin/fai-deps > $(DESTDIR)/man/fai-deps.8
	$(MAKE) -C doc install
	-install $(libfiles) $(LIBDIR)
	cp -a lib/dracut/80fai-autodiscover $(DESTDIR)/usr/lib/dracut/modules.d
	install lib/setup-storage/* $(SHAREDIR)/setup-storage
	cd bin ; install $(USRSBIN_SCRIPTS) $(DESTDIR)/usr/sbin
	cd bin ; install $(USRBIN_SCRIPTS) $(DESTDIR)/usr/bin
	install dev-utils/fai-kvm $(DESTDIR)/usr/bin
	install dev-utils/fai-mk-network $(DESTDIR)/usr/sbin
	install bin/dhclient-fai-script  $(DESTDIR)/usr/share/fai
	install -m644 conf/dhclient-fai.conf $(DESTDIR)/usr/share/fai
	install -m644 conf/apt.conf $(DESTDIR)/etc/apt/apt.conf.d/90fai
	cd conf ; install -m644 fai.conf grub.cfg grub.cfg.autodiscover $(DESTDIR)/etc/fai/
	install -m644 conf/nfsroot.conf $(DESTDIR)/etc/fai/
	install -m644 conf/sources.list $(DESTDIR)/etc/fai/apt/
	install -m644 conf/NFSROOT $(DESTDIR)/etc/fai
	install -m644 conf/upstart-fai.conf $(DESTDIR)/etc/init/fai.conf
	install -m755 lib/fai-abort $(DESTDIR)/etc/init.d
	cp -a pixmaps/*.gif $(DESTDIR)/usr/share/fai/pixmaps
	cp -a pixmaps/small/*.gif $(DESTDIR)/usr/share/fai/pixmaps/small
	perl -pi -e 's/FAIVERSIONSTRING/$(VERSIONSTRING)/' $(DESTDIR)/usr/sbin/fai
	cp -a examples $(DOCDIR)
	cp -a utils $(DOCDIR)/examples

.PHONY: clean veryclean
