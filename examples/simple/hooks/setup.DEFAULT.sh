#! /bin/bash

# use short hostname instead of FQDN
export HOSTNAME=${HOSTNAME%%.*}
echo $HOSTNAME > /proc/sys/kernel/hostname
