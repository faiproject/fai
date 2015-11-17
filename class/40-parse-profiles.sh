
#! /bin/bash

# parse *.profile and build a curses menu, so the user can select a profile
#
# (c) 2015 by Thomas Lange, lange@informatik.uni-koeln.de
# Universitaet zu Koeln

if [ X$FAI_ACTION = Xinstall -o X$FAI_ACTION = Xdirinstall -o X$FAI_ACTION = X ]; then
    :
else
    return
fi

[ "$flag_menu" ] || return 0

out=$(tty)
tempfile=`(tempfile) 2>/dev/null`
tempfile2=`(tempfile) 2>/dev/null`
trap "rm -f $tempfile $tempfile2" EXIT INT QUIT

# declare the data structure, use associative arrays
declare -A arshort
declare -A ardesc
declare -A arlong
declare -A arclasses
declare -a list


parse_profile() {

    # read a profile and add all info to the data structure

    local short
    local long
    local desc
    local name
    local classes
    local lflag=0

    # disable word splitting when reading a line, this helps reading a keyword without a value
    local OIF=$IFS
    IFS=

    while read -r line || [[ -n $line ]]; do

	if [[ $line =~ "Name: " ]]; then
	    if [ -n "$long" ]; then
		arlong[$name]="$long"
	    fi
	    short=
	    desc=
	    long=
	    classes=
	    lflag=0
            name=${line##Name: }
	    [ $debug ] && echo "XX NAME $name found"
	    list+=("$name")  # add new item to list
	    continue
	fi

	if [[ $line =~ "Description: " ]]; then
	    lflag=0
            desc=${line##Description: }
	    [ $debug ] && echo "XX $desc found"
	    ardesc[$name]="$desc"
	    continue
	fi

	if [[ $line =~ "Short: " ]]; then
	    lflag=0
            short=${line##Short: }
	    [ $debug ] && echo "XX $short found"
	    arshort[$name]="$short"
	    continue
	fi

	if [[ $line =~ "Classes: " ]]; then
            lflag=0
            classes=${line##Classes: }
	    [ $debug ] && echo "XX classes found"
	    arclasses[$name]="$classes"
	    continue
	fi
	
	if [[ $line =~ "Long: " ]]; then
            lflag=1
            long=${line##Long: }
	    [ $debug ] && echo "XX long found"

	# else it's another long line
	elif [ $lflag -eq 1 ]; then
	    long+="\n$line"
	fi

	if [[ $line =~ "Default: " ]]; then
	    lflag=0
            default=${line##Default: }
	    continue
	fi

    done < $1

    if [ -n "$long" ]; then
	arlong[$name]="$long"
    fi
    IFS=$OIF
}

prtresult() {

    # set newclasses which is used by fai-class(1)
    local res=$(<$tempfile)
    echo "$BASH_SOURCE defined new classes: ${arclasses[$res]}"
    newclasses="${arclasses[$res]}"
}


# read all files with name matching *.profile 
_parsed=0
shopt -s nullglob
for _f in *.profile; do
    parse_profile $_f
    _parsed=1
done
unset _f

# do nothing if no profile was read
if [ $_parsed -eq 0 ]; then
    unset _parsed
    return 0
fi

# create the argument list containing the menu entries
# and the help text file
for i in "${list[@]}"; do
    par+=("$i")
    par+=("${ardesc[${i}]}")
    par+=("${arshort[${i}]}")
    echo "Name: ${i}" >> $tempfile2
    echo -e ${arlong[${i}]} >> $tempfile2
    echo -e "Classes: " ${arclasses[${i}]} "\n" >> $tempfile2
done
unset i

while true; do

    dialog --clear --item-help --title "FAI - Fully Automatic Installation" --help-button \
	--default-item "$default" \
	--menu "\nSelect your FAI profile\n\nThe profile will define a list of classes,\nwhich are used by FAI.\n\n\n"\
	15 70 0 "${par[@]}" 2> $tempfile  1> $out

    _retval=$?
    case $_retval in
	0)
	    prtresult
	    break ;;
	1)
	    echo "No profile selected."
	    break ;;
	2)
	    dialog --title "Description of all profiles" --textbox $tempfile2 0 0 1> $out;;
    esac

done
unset par ardesc arshort arlong arclasses list tempfile tempfile2 _parsed _retval line
