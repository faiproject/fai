# This script is part of FAI (Fully Automatic Installation)
# (c) 2003 by Thomas Lange, lange@informatik.uni-koeln.de
# Universitaet zu Koeln

include ../VERSION

DESTDIR=/tmp/jumpstart
# $(shell pwd)/debian/fai

SCRIPTS = fcopy ftar fai-class fai-do-scripts
SHARES = subroutines subroutines-sunos
FAI=$(DESTDIR)/fai

install: 
	rm -rf $(DESTDIR)
	mkdir -p $(FAI) $(DESTDIR)/lib
	cp -a bin $(DESTDIR)
	cp -a class disk_config package_config scripts files $(FAI)
	cd ../scripts ; install $(SCRIPTS) $(DESTDIR)/bin
	cd ../share   ; install $(SHARES) $(DESTDIR)/bin
	cd ../examples/simple/class ; cp 01alias $(FAI)/class


	chmod -R a+rx $(DESTDIR)/bin $(FAI)/scripts
	perl -pi -e 's/FAIVERSIONSTRING/$(VERSIONSTRING)/' $(DESTDIR)/bin/subroutines-sunos
	find $(DESTDIR) -name CVS | xargs rm -rf

clean:
	rm -rf $(DESTDIR)

tar:
	tar -C $(DESTDIR) -cvf - . | gzip > jumpstart.tgz 

.PHONY: clean veryclean
