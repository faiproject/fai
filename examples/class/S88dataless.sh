#! /bin/sh

# This is for demonstration purpose
# all ants except ant99 are dataless clients

case $HOSTNAME in

    ant99)
	exit
	;;
    ant??)
	echo DATALESS
	;;

esac
