#! /bin/sh

# add class $HOSTNAME and class ALL
echo ALL $HOSTNAME

# add classes defined in file $HOSTNAME
[ -f $HOSTNAME ] && cat $HOSTNAME
