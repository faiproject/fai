FILES = fai-guide.sgml common.ent
docname = fai-guide
fdocname = $(docname).sgml
MISC_DOC = FAQ QUESTIONAIRE classes_description.txt links.html changelog.old README*


dvi: test
	debiandoc2latexdvi $(fdocname)

postscript:
	debiandoc2latexps $(fdocname)

pdf:
	debiandoc2latexpdf $(fdocname)

text:
	debiandoc2text $(fdocname)

html:
	debiandoc2html $(fdocname)

test:
	nsgmls -wall -E20 -gues $(fdocname)

clean:
	rm -rf $(docname).txt $(docname).dvi $(docname).pdf $(docname).html $(docname).sasp *~ $(docname).texinfo $(docname).ps

print: dvi
	dvips -f $(docname) | lpr

install:
	cp -dRp $(FILES) $(docname)* $(DESTDIR)/$(DOCDIR)
	cp -p $(MISC_DOC) $(DESTDIR)/$(DOCDIR)

all: pdf text html postscript

.PHONY: all dvi text html pdf test clean print postscript