FILES = fai-guide.sgml version.ent common.ent
docname = fai-guide
fdocname = $(docname).sgml
MISC_DOC = QUESTIONAIRE classes_description.txt links.html README*


dvi: test
	debiandoc2latexdvi $(fdocname)

pdf:
	debiandoc2latexpdf $(fdocname)

text:
	debiandoc2text $(fdocname)

html:
	debiandoc2html $(fdocname)

test:
	nsgmls -wall -E20 -gues $(fdocname)

clean:
	rm -rf $(docname).txt $(docname).dvi $(docname).pdf $(docname).html $(docname).sasp *~ $(docname).texinfo

print: dvi
	dvips -f $(docname) | lpr

install:
	cp -dRp $(FILES) $(docname)* $(DESTDIR)/$(DOCDIR)
	cp -p $(MISC_DOC) $(DESTDIR)/$(DOCDIR)

all: dvi pdf text html

.PHONY: all dvi text html pdf test clean print