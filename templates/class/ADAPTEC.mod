#! /bin/sh

# load adaptec scsi driver and show results

modprobe aic7xxx
cat /proc/scsi/scsi
if [ -d /proc/scsi/aic7xxx/ ]; then
    cat /proc/scsi/aic7xxx/*
    disk_info  # recalculate number of available disks
    save_dmesg # save new boot messages
    cat /proc/partitions
fi

