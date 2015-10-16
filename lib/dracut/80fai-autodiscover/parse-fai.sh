#! /bin/bash

opt=$(getarg fai.discover)

if [ -z "$opt" ] ; then
    return
fi

port=$(getarg fai.port=)
[ -z ${port} ] && port=4711  # default value

#[ -z "$root" ] && root=$(getarg root=)

echo FAI
echo ROOT= $root
echo fai.discover= $opt
echo fai.port= $port
sleep 1

rootok=1
