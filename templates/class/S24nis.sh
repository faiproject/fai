#! /bin/sh

# add NIS if YPDOMAIN is defined

if [ -n "$YPDOMAIN" ];then
   echo NIS
   echo $YPDOMAIN | tr '.a-z-' '_A-Z_'
else
   echo NONIS
fi
