#!/bin/bash

check() {
    # do not add this module by default
    return 255
}

depends() {
    echo network
    return 0
}

install() {

    inst_multiple nmap grep cut sort uniq head nc dialog getent
    
    inst_hook cmdline  40 "$moddir/parse-fai.sh"
    inst_hook initqueue/online 95 "$moddir/fai-scan.sh"
}
