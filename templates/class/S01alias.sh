#! /bin/sh

# all hosts named ant?? are using the classes in file ants
case $HOSTNAME in

    ant??)
	cat anthill ;;
esac


# if host belongs to class C subnet 134.95.9.0 use class NET_9
case $IPADDR in
    134.95.9.*)
	echo NET_9 ;;
esac
