#! /bin/sh

# all faiclient's are using classes in faiclient
case $HOSTNAME in

    faiclient??)
	cat faiclient ;;
esac


# if host belongs to class C subnet 134.95.9.0 use class NET_9
case $IPADDR in
    134.95.9.*)
	echo NET_9 ;;
esac
