#! /bin/bash

if [ X$FAI_ACTION = Xinstall -o X$FAI_ACTION = X ]; then
    :
else
    return 0
fi
if [ X$action = Xdirinstall ]; then
    return 0
fi

grep -q INSTALL $LOGDIR/FAI_CLASSES || return 0
[ "$flag_menu" ] || return 0

out=$(tty)
red=$(mktemp)
echo 'screen_color = (CYAN,RED,ON)' > $red

DIALOGRC=$red dialog --colors --clear --aspect 6 --title "FAI - Fully Automatic Installation" --trim \
	        --msgbox "\n\n        If you continue,       \n   all your data on the disk   \n                               \n|\Zr\Z1       WILL BE DESTROYED     \Z0\Zn|\n\n" 0 0 1>$out

# stop on any error, or if ESC was hit
if [ $? -ne 0 ]; then
    task_error 999
fi

rm $red
unset red
