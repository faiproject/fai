#! /bin/sh

# This is for demonstration purpose
# all faiclients except faiclient99 are dataless clients

case $HOSTNAME in

    faiclient99)
	exit
	;;
    faiclient??)
	echo DATALESS
	;;

esac
