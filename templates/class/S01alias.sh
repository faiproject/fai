#! /bin/sh

# echo architecture in upper case
dpkg --print-installation-architecture | tr /a-z/ /A-Z/
uname -s | tr 'a-z' 'A-Z'

# all hosts named ant?? are using the classes in file anthill
case $HOSTNAME in
    ant??) cat anthill ;;
esac


# the Beowulf cluster; all nodes except the master node use classes from file class/atoms
case $HOSTNAME in
    atom00) echo BEOWULF_MASTER ;;
    atom??) cat atoms ;;
esac

# if host belongs to class C subnet 134.95.9.0 use class NET_9
case $IPADDR in
    134.95.9.*)	echo NET_9 ;;
esac

