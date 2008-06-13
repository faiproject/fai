#!/usr/bin/perl -w

#*********************************************************************
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
# General Public License for more details.
#
# A copy of the GNU General Public License is available as
# `/usr/share/common-licences/GPL' in the Debian GNU/Linux distribution
# or on the World Wide Web at http://www.gnu.org/copyleft/gpl.html. You
# can also obtain it by writing to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA
#*********************************************************************

use strict;

################################################################################
#
# @file init.pm
#
# @brief Initialize all variables and acquire the set of disks of the system.
#
# The layout of the data structures is documented in the wiki:
# http://faiwiki.debian.net/index.php/Setup-storage
#
# $Id$
#
# @author Christian Kern, Michael Tautschnig
# @date Sun Jul 23 16:09:36 CEST 2006
#
################################################################################

package FAI;

################################################################################
#
# @brief Enable debugging by setting $debug to a value greater than 0
#
################################################################################
$FAI::debug = 0;
defined( $ENV{debug} ) and $FAI::debug = $ENV{debug};

################################################################################
#
# @brief The lists of disks of the system
#
################################################################################
@FAI::disks = split( /\n/, $ENV{disklist} );
( $FAI::debug > 0 ) and print "disklist was: $ENV{disklist}\n";

################################################################################
#
# @brief The variables later written to disk_var.sh
#
################################################################################
%FAI::disk_var = ();
$FAI::disk_var{SWAPLIST} = "";
$FAI::disk_var{BOOT_DEVICE} = "";

################################################################################
#
# @brief The contents later written to crypttab, if any
#
################################################################################
@FAI::crypttab = ();

################################################################################
#
# @brief A flag to tell our script that the system is not installed for the
# first time
#
################################################################################
$FAI::reinstall = 1;
defined( $ENV{fl_initial} ) and $FAI::reinstall = 0;

################################################################################
#
# @brief The hash of all configurations specified in the disk_config file
#
################################################################################
%FAI::configs = ();

################################################################################
#
# @brief The current disk configuration
#
################################################################################
%FAI::current_config = ();

################################################################################
#
# @brief The current LVM configuration
#
################################################################################
%FAI::current_lvm_config = ();

################################################################################
#
# @brief The current RAID configuration
#
################################################################################
%FAI::current_raid_config = ();

################################################################################
#
# @brief The commands to be executed
#
################################################################################
%FAI::commands = ();

################################################################################
#
# @brief Each command is associated with a unique id -- this one aids in
# counting (next_command_index)
#
################################################################################
$FAI::n_c_i = 1;

################################################################################
#
# @brief Add command to hash
#
# @param cmd Command
# @param pre Preconditions
# @param post Postconditions
#
################################################################################
sub push_command { 
  my ($cmd, $pre, $post) = @_;

  $FAI::commands{$FAI::n_c_i} = {
    cmd => $cmd,
    pre => $pre,
    post => $post
  };
  $FAI::n_c_i++;
}


################################################################################
#
# @brief Sort integer arrays
#
################################################################################
sub numsort { return sort { $a <=> $b } @_; }


################################################################################
#
# @brief Check, whether $dev is a physical device, and extract sub-parts
#
# @param $dev Device string
#
# @return 1, if it the matches the regexp, and disk device string, and
# partition number, if any, otherwise -1
#
################################################################################
sub phys_dev {
  my ($dev) = @_;
  if ($dev =~ m{^/dev/(i2o/hd[a-t]|sd[a-t]{1,2}|hd[a-t])(\d+)?$})
  {
    defined($2) or return (1, $1, -1);
    return (1, "/dev/$1", $2);
  }
  elsif ($dev =~ m{^/dev/(cciss/c\dd\d|ida/c\dd\d|rd/c\dd\d|ataraid/d\d)p(\d+)?$})
  {
    defined($2) or return (1, "/dev/$1", -1);
    return (1, $1, $2);
  }
  return (0, "", -2);
}

################################################################################
#
# @brief Convert a device name and a partition id to a proper device name,
# handling cciss and the like
#
# @param $dev Device name of disk
# @param $id Partition id
#
# @return Full device name
#
################################################################################
sub make_device_name {
  my ($dev, $p) = @_;
  $dev .= "p" if ($dev =~
    m{^/dev/(cciss/c\dd\d|ida/c\dd\d|rd/c\dd\d|ataraid/d\d)$});
  $dev .= $p;
  internal_error("Invalid device $dev") unless (&FAI::phys_dev($dev))[0];
  return $dev;
}

################################################################################
#
# @brief Report an error that is due to a bug in the implementation
#
# @param $error_msg Error message
#
################################################################################
sub internal_error {

  my ($error_msg) = @_;

  die <<EOF;
INTERNAL ERROR in setup-storage:
$error_msg
Please report this error to the Debian Bug Tracking System.
EOF
}

1;

