docname = fai-guide
fdocname = $(docname).sgml
MISC_DOC = classes_description.txt links.html changelog.old

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
	rm -rf $(docname).txt $(docname).dvi $(docname).pdf $(docname).html $(docname).sasp* *~ $(docname).texinfo $(docname).ps $(docname).out $(docname).tpt $(docname).tex
	rm -f body.tmp head.tmp thb*.png *.log

print: dvi
	dvips -f $(docname) | lpr

install:
	rm -f $(docname).tpt $(docname).out
	cp -dRp $(docname)* $(DOCDIR)
	cp -p $(MISC_DOC) $(DOCDIR)

all: test pdf text html postscript

.PHONY: all dvi text html pdf test clean print postscript
