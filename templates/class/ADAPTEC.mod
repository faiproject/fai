#! /bin/sh

# show adaptec scsi info
# kernel module is loaded by S03discover

#modprobe aic7xxx
cat /proc/scsi/scsi
if [ -d /proc/scsi/aic7xxx/ ]; then
    cat /proc/scsi/aic7xxx/*
    cat /proc/partitions
fi

