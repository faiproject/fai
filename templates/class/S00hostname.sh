#! /bin/sh

# add class $HOSTNAME and class ALL
echo $HOSTNAME ALL

# add classes defined in file $HOSTNAME
[ -f $HOSTNAME ] && cat $HOSTNAME
