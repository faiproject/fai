#!/bin/bash

# autodiscover of the FAI server

# (c) Thomas Lange 2015

. /lib/dracut-lib.sh

opt=$(getargs fai.discover)
if [ -z $opt ] ; then
    return
fi

port=$(getarg fai.port=)
[ -z ${port} ] && port=4711  # default value
export FAI_MONITOR_PORT=$port


# this script is called with all network interfaces
nic=$1

ivar=/run/initramfs/fai-variables
declare -a faisrv
declare -A version
declare -a para

scan_net() {

    # scan local network for FAI server
    
    local iprange=$1
    shift
    local port=$1
    local iplist
    local host
    
    iplist=$(nmap -n -e $nic --host-timeout 10 --open -oG - -p $port $iprange 2>/dev/null  | grep -v '#' | cut -d' ' -f2 | sort -n | uniq)

    # check all IPs, if a faiserver is listening there
    for host in $iplist; do
	getvar FAI_VERSION $host
	if [ -n "$FAI_VERSION" ]; then
	    faiserver+=" $host"
	    version[$host]="$FAI_VERSION"
	fi
    done
}

getvar() {

    # get a variable from the fai-monitor
    # use $monserver and $FAI_MONITOR_PORT is no arguments are used
    local ret
    local srv
    local var
    local port

    var=$1; shift
    srv=$1; shift
    port=$1; shift

    : ${port:=$FAI_MONITOR_PORT}
    : ${srv:=$monserver}

    ret=$(echo "VARIABLE $var" | nc $srv $port)
    if [[ $ret =~ ^OK\  ]]; then
	val=${ret#OK }
	eval $var=\$val
    else
	eval "$var="
    fi
}

iprange=$(ip addr show up | grep -w 'inet'|grep -v 127.0.0.1| cut -d t -f 2 | cut -d ' ' -f 2 |head -1)
echo "Scanning $iprange for FAI server (port $FAI_MONITOR_PORT)"

while [ 1 ]; do

    dialog --infobox "\n  Scanning $iprange for FAI server (port $FAI_MONITOR_PORT)\n" 5 59
    scan_net $iprange $FAI_MONITOR_PORT
    faisrv=($faiserver)

    if [ ${#faisrv[@]} -eq 0 ]; then
	dialog --colors --yesno "\n  \Zr\Z1No FAI server found.\Zn\n\n\n      Retry scan?\n" 10 28
	if [ $? -eq 1 ]; then
	   die "No FAI server found."
	   root=
	   return
	fi
    elif [ ${#faisrv[@]} -gt 1 ]; then
	echo "More than one FAI server found."
	# build parameter list for the menu
	for i in "${faisrv[@]}"; do
	    # resolve IP to host name
	    hn=$(getent hosts $i)
	    hn=${hn#* }
	    hn=${hn%%.*}
	    str=$(printf "%-20s" $hn)
	    para+=("$i" "$str FAI ${version[$i]}")
	done

	exec 3>&1
	selection=$(dialog --colors --no-cancel --menu "  More than one server found. \n  Please select a server:\n\n" 15 70 10 "${para[@]}" "Rescan" "Rescan the network" 2>&1 >&3)

	if [ "$selection" = "Rescan" ]; then
	    faiserver=""
	    para=()
	    unset version
	    declare -A version
	else
	    # one server was selected
	    monserver=${selection}
	    break
	fi
    else
	# we found excatly one FAI server
	monserver=${faisrv[0]}
	break
    fi
done

FAI_VERSION=${version[$monserver]}

getvar FAI_FLAGS
getvar NFSROOT
getvar FAI_CONFIG_SRC

if [ -z "FAI_CONFIG_SRC" ]; then
    getvar FAI_CONFIGDIR
    FAI_CONFIG_SRC="nfs://$monserver/$FAI_CONFIGDIR"
fi

dialog --infobox "\n\n FAI server $FAI_VERSION found at $monserver\n\n  Using root=$monserver:$NFSROOT\n" 9 50
sleep 4

root=$monserver:$NFSROOT
netroot=nfs:$monserver:$NFSROOT:
echo "root=$root"

echo "FAI_VERSION=$FAI_VERSION" >> $ivar
echo FAI_FLAGS=$FAI_FLAGS >> $ivar
echo "root=$monserver:$NFSROOT" >> $ivar
echo "monserver=$monserver" >> $ivar
echo "FAI_CONFIG_SRC=$FAI_CONFIG_SRC" >> $ivar

# Done, all good!
rootok=1
