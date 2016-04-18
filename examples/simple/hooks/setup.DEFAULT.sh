#! /bin/bash

# use short hostname instead of FQDN
export HOSTNAME=${HOSTNAME%%.*}
# n.b. use $action instead of $FAI_ACTION
# as the latter is apparently unset at this point in dirinstall
if [ "$action" = "dirinstall" ] ; then
  :
else
  echo $HOSTNAME > /proc/sys/kernel/hostname
fi
