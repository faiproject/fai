#! /bin/bash

# use short hostname instead of FQDN
export HOSTNAME=${HOSTNAME%%.*}
if [ $do_init_tasks -eq 1 ]; then
  echo $HOSTNAME > /proc/sys/kernel/hostname
fi
