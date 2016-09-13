#! /bin/bash

# use short hostname instead of FQDN
export HOSTNAME=${HOSTNAME%%.*}
# n.b. use $action instead of $FAI_ACTION
# as the latter is apparently unset at this point in dirinstall
if [ $do_init_tasks -eq 1 ]; then
  echo $HOSTNAME > /proc/sys/kernel/hostname
fi
