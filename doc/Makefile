#!/bin/make

DOC = fai-guide
MISC_DOC = classes_description.txt changelog.old
DOC2DIR = $(shell pwd)/../debian/fai-setup-storage/usr/share/doc/fai-setup-storage
OPT = --dblatex-opts "-P latex.output.revhistory=0"
LANGUAGES = fr
POFILES = $(patsubst %, po/%.po, $(LANGUAGES))
HTML_LANG_FILES = $(patsubst %, $(DOC)_%.html, $(LANGUAGES))
PDF_LANG_FILES = $(patsubst %, $(DOC)_%.pdf, $(LANGUAGES))
TEXT_LANG_FILES = $(patsubst %, $(DOC)_%.text, $(LANGUAGES))
DOC_LANG_FILES = $(patsubst %, $(DOC)_%.doc, $(LANGUAGES))
# kill conversion to doc when it is too long
TIMEOUT = 10

free:	text html pdf
#	echo "`grep -c FIXME $(DOC).txt` FIXMEs left to fix:"
#	grep FIXME $(DOC).txt

potfile: $(DOC).txt
	[ -d po ] || mkdir po
	txt2po $< -o po/$(DOC).pot --pot

updatepo: potfile
	for l in $(LANGUAGES); do \
	  [ -f po/$$l.po ] || cp po/$(DOC).pot po/$$l.po ; \
	  pot2po po/$(DOC).pot -o po/$$l.po.tmp -t po/$$l.po && \
            mv po/$$l.po.tmp po/$$l.po ; \
	done

translate: $(DOC).txt $(POFILES)
	for l in $(LANGUAGES); do \
	  po2txt -i po/$$l.po -t $(DOC).txt -o $(DOC)_$$l.txt ; \
	done


images:
	ln -fs /usr/share/asciidoc/images images

%.html : %.txt
	@echo "$< ==> $@"
	@asciidoc -a toc2 -a toclevels=3 --theme=flask $<

html: $(DOC).html $(HTML_LANG_FILES)

%.pdf: %.txt
	@echo "$< ==> $@"
	@a2x $(OPT) -L --icons -a toc -a toclevels=3 -f pdf $<
	@prefix=$$(echo $< | sed 's/\.txt//'); rm -f $$prefix.xml $$prefix.fo

pdf: $(DOC).pdf $(PDF_LANG_FILES)


# a2x uses lynx, maybe use w3m instead
# which texwidth for text output?
# asciidoc --doctype=article  -a "toc" -a "toclevels=3" -f /etc/asciidoc/text.conf -b html4 -o - "f-guide.txt" | lynx -dump -stdin >"./f-guide.text"
%.text: %.txt
	@echo "$< ==> $@"
	@a2x $(OPT) -L -a toc -a toclevels=3 -f text $<

text: $(DOC).text $(TEXT_LANG_FILES)

# for openoffice
%.doc: %.html
	@echo "$< ==> $@"
	@unoconv --show >/dev/null 2>&1 || exit "Please install the unoconv package."
	@timeout $(TIMEOUT) unoconv -f doc $< || \
	  echo "$@ could not be generated after $(TIMEOUT) s."

doc:	$(DOC).doc $(DOC_LANG_FILES)

.NOTPARALLEL:	free
all:	free

install:
	cp -dRp $(DOC)* $(DOCDIR)
	cp -p $(MISC_DOC) $(DOCDIR)
	cp -p setup-storage-call-graph.txt setup-storage-overview.txt $(DOC2DIR)

clean:
	rm -rf images .a2x-icons grohtml-*.png
	rm -f *.text *.html *.doc *.pdf *.xml *.ps* docbook-xsl.css

test:
	asciidoc --version > /dev/null 2>&1 || exit "Please install the asciidoc package."


.PHONY: all test clean free html pdf text doc
