Default: Xfce

Name: Simple
Description: My first FAI installation
Short: just a very simple example, no xorg, an account called demo
Long: This is the demohost example of FAI.
Additional account called demo. PW: fai, root pw: fai
Classes: FAIBASE DEBIAN DEMO

Name: Xfce
Description: Xfce desktop, LVM partitioning
Short: A fancy Xfce desktop will be installed, the user account is demo
Long: This is the Xfce desktop example. Additional account called
demo. PW: fai, root pw: fai
Classes: FAIBASE DEBIAN DEMO XORG XFCE LVM

Name: Gnome
Description: Gnome desktop installation
Short: A Gnome desktop, no LVM, You will get an account called demo
Long: This is the Gnome desktop example. Additional account called
demo. PW: fai, root pw: fai
Classes: FAIBASE DEBIAN DEMO XORG GNOME
Name: FAI server
Description: automatically install a FAI server
Short: All services needed for FAI are installed and configured
Long: A complete FAI server is set up automatically
Classes: FAIBASE DEBIAN DEMO FAISERVER


Name: dummy
Description: A dummy profile
Short: This is the short one liner text for the dummy menu, Shown at the bottom of the menu
Long: Here you can add more lines to describe details of you
profile. A profile is only a list of FAI classes. Those classes can
then define the disk partitioning scheme, the list of packages to be
installed, the variables to defined and other things.

In the end, a profile is just a list of FAI classes combined with some description.
Classes: A B C E
