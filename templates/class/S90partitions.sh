#! /bin/sh 

for c in $classes
do
    if [ -r /fai/disk_config/$c ] 
    then
	grep -v "^#" /fai/disk_config/$c | \
	grep -q '[[:space:]]/scratch[[:space:]]' && echo "NFS_SERVER SCRATCH"

	grep -v "^#" /fai/disk_config/$c | \
	grep -q '[[:space:]]/files/scratch[[:space:]]' && echo "NFS_SERVER FILES_SCRATCH"

	grep -v "^#" /fai/disk_config/$c | \
	grep -q '[[:space:]]/tmp[[:space:]]'  && echo "TMP_PARTITION"

	grep -v "^#" /fai/disk_config/$c | \
	grep -q '[[:space:]]/fai-boot[[:space:]]'  && echo "FAI_BOOTPART"

	exit
    fi
done
