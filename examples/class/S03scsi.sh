#! /bin/sh

# add class SCSI if a SCSI adapter is available

if [ -e /proc/scsi/scsi ]; then
    grep -q "Attached devices: none" /proc/scsi/scsi && exit
    echo "SCSI"
fi

