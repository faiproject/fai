#! /bin/bash

if ! getargbool 0 fai.discover; then
    return
fi

port=$(getarg fai.port=)
[ -z ${port} ] && port=4711  # default value

sleep 1

rootok=1
