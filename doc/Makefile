FILES = fai-guide.sgml common.ent
docname = fai-guide
fdocname = $(docname).sgml
MISC_DOC = FAQ QUESTIONNAIRE classes_description.txt links.html changelog.old README*

%.html: %.sgml
	debiandoc2html $<

%.pdf: %.sgml
	debiandoc2latexpdf $<

%.ps: %.sgml
	debiandoc2latexps $<

%.txt: %.sgml
	debiandoc2text $<

postscript: fai-guide.ps

pdf: fai-guide.pdf

html: fai-guide.html

dvi: test
	debiandoc2latexdvi $(fdocname)

text: fai-guide.txt

test:
	nsgmls -wall -E20 -gues $(fdocname)

clean:
	rm -rf $(docname).txt $(docname).dvi $(docname).pdf $(docname).html $(docname).sasp *~ $(docname).texinfo $(docname).ps

print: dvi
	dvips -f $(docname) | lpr

install:
	cp -dRp $(FILES) $(docname)* $(DESTDIR)/$(DOCDIR)
	cp -p $(MISC_DOC) $(DESTDIR)/$(DOCDIR)

all: test pdf text html postscript

.PHONY: all dvi text html pdf test clean print postscript