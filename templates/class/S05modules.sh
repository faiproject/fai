#! /bin/sh

# load kernel modules
# message of loading modules are written to syslogd and read with dmesg
# for all classes, that are defines before this script is called, lokk for
# a $class.mod file and execute it.

conffiles="$classes $HOSTNAME"

for cfile in $conffiles ; do
    if [ -f "${file}.mod" ]; then
	.  ${file}.mod  >> $moduleslog 2>&1
    fi
done

unset conffiles cfile
