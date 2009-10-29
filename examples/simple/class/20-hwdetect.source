#! /bin/bash

# (c) Thomas Lange, 2002-2008, lange@informatik.uni-koeln.de

# NOTE: Files named *.source will be evaluated, but their output ignored. Instead
# the contents of $newclasses will be added to the list of defined classes.

[ "$action" = "dirinstall" ] && return 0 # Do not execute when doing dirinstall

echo 0 > /proc/sys/kernel/printk

# load all IDE drivers

# DMA does not work if we load all modules in drivers/ide, so only try pci modules
mod=$(find /lib/modules/$(uname -r)/kernel/drivers/ide/pci -type f | sed 's/\.o$//' | sed 's/\.ko$//' | sed 's/.*\///')
for i in $mod; do
    modprobe $i 1>/dev/null 2>&1
done
# Booting from CD does not always enable DMA.
for d in $( echo /proc/ide/hd[a-z] 2>/dev/null); do
    [ -d $d ] && echo "using_dma:1" > $d/settings
done

# load additional kernel modules (from old 11modules.source)
# this order should also enable DMA for all IDE drives
kernelmodules="usbkbd ide-disk ide-cd"
case $(uname -r) in
    2.6*) kernelmodules="$kernelmodules ohci-hcd usbhid usbmouse ide-generic mptspi ata_piix dm-mod md-mod aes dm-crypt" ;;
esac

for mod in $kernelmodules; do
    [ "$verbose" ] && echo loading kernel module $mod
    modprobe -a $mod 1>/dev/null 2>&1
done

# let discover do most of the job
#[ -x /sbin/discover-modprobe ] && /sbin/discover-modprobe

# now we can mount the USB filesystem
mount -t usbfs  usbfs /proc/bus/usb

modprobe -a sd_mod sr_mod

echo $printk > /proc/sys/kernel/printk

set_disk_info  # calculate number of available disks
save_dmesg     # save new boot messages (from loading modules)

