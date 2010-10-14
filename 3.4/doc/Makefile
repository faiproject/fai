#!/bin/make -s

DOC = fai-guide
MISC_DOC = classes_description.txt links.html changelog.old lenny-instructions.txt

free:	text html ps pdf
#	echo "`grep -c FIXME $(DOC).txt` FIXMEs left to fix:"
#	grep FIXME $(DOC).txt

html:
	a2x --icons-dir=.a2x-icons --icons --copy --asciidoc-opt="-a toc -a toclevels=3" -f xhtml $(DOC).txt

chunked:
	a2x --icons-dir=.a2x-icons --icons --copy --asciidoc-opt="-a toc -a toclevels=3" -f chunked $(DOC).txt

pdf:	
	a2x --icons -a toc -a toclevels=3 -f pdf $(DOC).txt
	rm -f $(DOC).xml $(DOC).fo

ps:	
	a2x --icons -a toc -a toclevels=3 -f ps $(DOC).txt
	rm -f $(DOC).xml $(DOC).fo

# a2x uses lynx, maybe use w3m instead
# which texwidth for text output?
# asciidoc --doctype=article  -a "toc" -a "toclevels=3" -f /etc/asciidoc/text.conf -b html4 -o - "f-guide.txt" | lynx -dump -stdin >"./f-guide.text"
text:	
	a2x --icons -a toc -a toclevels=3 -f text $(DOC).txt

# for openoffice
doc:	html
	unoconv --show >/dev/null 2>&1 || exit "Please install the unoconv package." 
	unoconv -f doc $(DOC).html

all:	free

install:
	cp -dRp $(DOC)* $(DOCDIR)
	cp -p $(MISC_DOC) $(DOCDIR)

clean: 
	rm -rf .a2x-icons
	rm -f $(DOC).text $(DOC).html $(DOC).doc $(DOC).pdf $(DOC).xml $(DOC).ps docbook-xsl.css

test:
	asciidoc --version > /dev/null 2>&1 || exit "Please install the asciidoc package." 


.PHONY: all test clean




