#! /bin/sh

# load kernel modules
# message of loading modules are written to syslogd and read with dmesg
# for all classes, that are defines before this script is called, look for
# a $class.mod file and execute it.

conffiles="$classes $HOSTNAME"

for cfile in $conffiles ; do
    if [ -f "${cfile}.mod" ]; then
	.  ${cfile}.mod  >> $moduleslog 2>&1
    fi
done

unset conffiles cfile
