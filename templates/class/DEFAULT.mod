# load kernel modules for usb keyboard support

kernelmodules="rtc floppy parport_pc keybdev usb-uhci hid"

for mod in $kernelmodules; do
    [ "$verbose" ] && echo loading kernel module $mod
    modprobe -a $mod
done
