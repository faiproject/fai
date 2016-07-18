#! /bin/bash

# use short hostname instead of FQDN
export HOSTNAME=${HOSTNAME%%.*}
# n.b. use $action instead of $FAI_ACTION
# as the latter is apparently unset at this point in dirinstall
[ $do_init_tasks -eq 1 ] && echo $HOSTNAME > /proc/sys/kernel/hostname
