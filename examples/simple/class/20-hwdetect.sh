#! /bin/bash

# (c) Thomas Lange, 2002-2013, lange@informatik.uni-koeln.de

# NOTE: Files named *.sh will be evaluated, but their output ignored.

[ $do_init_tasks -eq 1 ] || return 0 # Do only execute when doing install

echo 0 > /proc/sys/kernel/printk

#kernelmodules=
# here, you can load modules depending on the kernel version
case $(uname -r) in
    2.6*) kernelmodules="$kernelmodules mptspi dm-mod md-mod aes dm-crypt" ;;
      3*) kernelmodules="$kernelmodules mptspi dm-mod md-mod aes dm-crypt" ;;
      4*) kernelmodules="$kernelmodules mptspi dm-mod md-mod aes dm-crypt" ;;
esac

for mod in $kernelmodules; do
    [ "$verbose" ] && echo Loading kernel module $mod
    modprobe -a $mod 1>/dev/null 2>&1
done

ip ad show up | egrep -iv 'loopback|127.0.0.1|::1/128|_lft'

echo $printk > /proc/sys/kernel/printk

odisklist=$disklist
set_disk_info  # recalculate list of available disks
if [ "$disklist" != "$odisklist" ]; then
    echo New disklist: $disklist
    echo disklist=\"$disklist\" >> $LOGDIR/additional.var
fi

save_dmesg     # save new boot messages (from loading modules)

