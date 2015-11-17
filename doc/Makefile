#!/bin/make -s

DOC = fai-guide
MISC_DOC = classes_description.txt changelog.old
DOC2DIR = $(shell pwd)/../debian/fai-setup-storage/usr/share/doc/fai-setup-storage
OPT = --dblatex-opts "-P latex.output.revhistory=0"


free:	text html ps pdf
#	echo "`grep -c FIXME $(DOC).txt` FIXMEs left to fix:"
#	grep FIXME $(DOC).txt

images:
	ln -s /usr/share/asciidoc/images images 

html: $(DOC).txt images
	a2x $(OPT) -L --icons --copy --asciidoc-opt="-a toc2 -a toclevels=3 -a theme=flask" --xsltproc-opts="--stringparam use.id.as.filename 1" -f xhtml $(DOC).txt

chunked: $(DOC).txt  images
	a2x $(OPT) -L --icons --copy --asciidoc-opt="-a toc2 -a toclevels=3 -a theme=flask" --xsltproc-opts="--stringparam use.id.as.filename 1" -f chunked $(DOC).txt

pdf: $(DOC).txt	images
	a2x $(OPT) -L --icons -a toc -a toclevels=3 -f pdf $(DOC).txt
	rm -f $(DOC).xml $(DOC).fo

ps: $(DOC).txt images
	a2x $(OPT) -L --icons -a toc -a toclevels=3 -f ps $(DOC).txt
	rm -f $(DOC).xml $(DOC).fo

# a2x uses lynx, maybe use w3m instead
# which texwidth for text output?
# asciidoc --doctype=article  -a "toc" -a "toclevels=3" -f /etc/asciidoc/text.conf -b html4 -o - "f-guide.txt" | lynx -dump -stdin >"./f-guide.text"
text: $(DOC).txt
	a2x $(OPT) -L -a toc -a toclevels=3 -f text $(DOC).txt

# for openoffice
doc:	html
	unoconv --show >/dev/null 2>&1 || exit "Please install the unoconv package."
	unoconv -f doc $(DOC).html

all:	free

install:
	cp -dRp $(DOC)* $(DOCDIR)
	cp -p $(MISC_DOC) $(DOCDIR)
	cp -p setup-storage-call-graph.txt setup-storage-overview.txt $(DOC2DIR)

clean:
	rm -rf images .a2x-icons fai-guide.chunked
	rm -f $(DOC).text $(DOC).html $(DOC).doc $(DOC).pdf $(DOC).xml $(DOC).ps docbook-xsl.css

test:
	asciidoc --version > /dev/null 2>&1 || exit "Please install the asciidoc package."


.PHONY: all test clean
