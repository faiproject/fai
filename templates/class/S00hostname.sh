#! /bin/sh

# add class DEFAULT (lowest priority)
echo DEFAULT

# add classes defined in file $HOSTNAME
[ -f $HOSTNAME ] && cat $HOSTNAME
