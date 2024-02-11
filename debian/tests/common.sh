
# Configuration space

. /etc/fai/nfsroot.conf

N=$NFSROOT
CS=$FAI_CONFIGDIR
TFTP=$TFTPROOT

# - - - - - - - - - - - - - - - - -
error() {
    echo "ERROR: $@" >/dev/stderr
}
# - - - - - - - - - - - - - - - - -
chk-file() {

    local file=$1
    if [ ! -f $file ]; then
        error "$file is missing"
    fi
}
# - - - - - - - - - - - - - - - - -
chk-no-file() {

    # check that files does not exist
    local file=$1
    if [ -f $file ]; then
        error "$file exists, but it should not."
    fi
}
# - - - - - - - - - - - - - - - - -
chk-size() {

    # check if the disk space of a path is greater than minsize
    # path can be a directory or a file

    local path=$1
    local minsize=$2
    local size

    if [ ! -e $path ]; then
        error "$path does not exist."
    fi

    size=$(du -Dsm $path | awk '{print $1}')

    if [ $size -lt $minsize ]; then
        error "$path is too small: $size MB. Should be greater $minsize MB"
    else
        echo "OK: $path size is $size MB"
    fi
}
# - - - - - - - - - - - - - - - - -
chk-loop-device() {

    # check if we can use loop devices
    trap 'exit 77' ERR ABRT EXIT QUIT
    qemu-img create test.raw 10M
    loop=$(losetup -P -f --show test.raw)
    echo "LOOP: $loop"
    losetup -d $loop
    rm test.raw
    trap - ERR ABRT EXIT QUIT
}
