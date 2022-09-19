
# Configuration space

. /etc/fai/nfsroot.conf

N=$NFSROOT
CS=$FAI_CONFIGDIR
TFTP=$TFTPROOT

# - - - - - - - - - - - - - - - - -
error() {
    echo "$@" >/dev/stderr
}
# - - - - - - - - - - - - - - - - -
chk-file() {

    local file=$1
    if [ ! -f $file ]; then
        error "$file is missing"
    fi
}
# - - - - - - - - - - - - - - - - -
chk-size() {

    # check if the disk space of a path is greater than minsize
    # path can be a directory or a file

    local path=$1
    local minsize=$2
    local size

    size=$(du -sm $path | awk '{print $1}')

    if [ $size -lt $minsize ]; then
        error "$path is too small: $size MB"
    else
        echo "OK: $path size is $size MB"
    fi
}
