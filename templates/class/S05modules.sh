#! /bin/sh

# load kernel modules
# message of loading modules are written to syslogd and read with dmesg

conffiles="global $HOSTNAME"

for file in $conffiles ; do
    if [ -f "${file}.mod" ]; then
	.  ${file}.mod  >> $moduleslog 2>&1
    fi
done

unset conffiles file
