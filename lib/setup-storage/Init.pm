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
# http://wiki.fai-project.org/index.php/Setup-storage
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
$FAI::debug = $ENV{debug} // 0;

################################################################################
#
# @brief Directory to store generated files such as fstab, crypttab
#
################################################################################
$FAI::DATADIR = $ENV{LOGDIR} // "/tmp/fai";
################################################################################
#
# @brief Write changes to disk only if set to
#
################################################################################
$FAI::no_dry_run = 0;

################################################################################
#
# @brief Perform syntactic checks only if set to 1
#
################################################################################
$FAI::check_only = 0;

################################################################################
#
# @brief The command to tell udev to settle (udevsettle or udevadm settle).
#        Will be set in bin/setup-storage according to installed tool.
#
################################################################################
$FAI::udev_settle = undef;

################################################################################
#
# @brief The lists of disks of the system
#
################################################################################
@FAI::disks = ();

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
$ENV{flag_initial} and $FAI::reinstall = 0;

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
# @brief Map from devices to volumes stacked on top of them
#
################################################################################
%FAI::dev_children = ();
%FAI::current_dev_children = ();

################################################################################
#
# @brief Add command to hash. $pre and $post are never executed, they are just
# debug information showing the state of the program before and after the
# command has been executed.
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
# @brief Test whether device is a loopback device and, if so, extract the
# numeric device id
#
# @param $dev Device name of disk
#
# @return 1, iff it is a loopback device, and device id as second item
#
################################################################################
sub loopback_dev {
  my ($dev) = @_;
  return (1, $1) if ($dev =~ m{^/dev/loop(\d+)$});
  return (0, -1);
}

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
  if ($dev =~ m{^/dev/(i2o/hd[a-z]|sd[a-z]{1,2}|hd[a-z]|vd[a-z]|xvd[a-z]|fio[a-z])(\d+)?$})
  {
    defined($2) or return (1, "/dev/$1", -1);
    return (1, "/dev/$1", $2);
  }
  elsif ($dev =~
    m{^/dev/(cciss/c\d+d\d+|ida/c\d+d\d+|rd/c\d+d\d+|ataraid/d\d+|etherd/e\d+\.\d+)(p(\d+))?$})
  {
    defined($2) or return (1, "/dev/$1", -1);
    return (1, "/dev/$1", $3);
  }
  elsif ((&FAI::loopback_dev($dev))[0])
  {
    # we can't tell whether this is a disk of its own or a partition
    return (1, $dev, -1);
  }
  return (0, "", -2);
}

# used exclusively by enc_name() and mark_encrypted
my %dev_alias;

################################################################################
#
# @brief Compute the name of $dev considering possible encryption
#
# @param $dev Device string
#
# @return $dev iff $dev is not encrypted, otherwise /dev/mapper/<mangled name>
#
################################################################################
sub enc_name {
  my ($dev) = @_;

  return $dev_alias{$dev} if defined($dev_alias{$dev});

  # handle old-style encryption entries
  my ($i_p_d, $disk, $part_no) = &FAI::phys_dev($dev);
  if ($i_p_d) {
    defined ($FAI::configs{"PHY_$disk"}) or return $dev;
    defined ($FAI::configs{"PHY_$disk"}{partitions}{$part_no}) or return $dev;
    return $dev unless
      ($FAI::configs{"PHY_$disk"}{partitions}{$part_no}{encrypt});
  } elsif ($dev =~ /^\/dev\/md(\d+)$/) {
    defined ($FAI::configs{RAID}) or return $dev;
    defined ($FAI::configs{RAID}{volumes}{$1}) or return $dev;
    return $dev unless ($FAI::configs{RAID}{volumes}{$1}{encrypt});
  } elsif ($dev =~ /^\/dev\/([^\/]+)\/([^\/]+)$/) {
    defined ($FAI::configs{"VG_$1"}) or return $dev;
    defined ($FAI::configs{"VG_$1"}{volumes}{$2}) or return $dev;
    return $dev unless ($FAI::configs{"VG_$1"}{volumes}{$2}{encrypt});
  } else {
    return $dev;
  }

  &FAI::mark_encrypted($dev);

  return $dev_alias{$dev};
}

################################################################################
#
# @brief Store mangled name for $dev
#
# @param $dev Device string
#
################################################################################
sub mark_encrypted {
  my ($dev) = @_;

  # encryption requested, rewrite the device name
  my $enc_dev_name = $dev;
  $enc_dev_name =~ s#/#_#g;
  my $enc_dev_short_name = "crypt$enc_dev_name";
  $enc_dev_name = "/dev/mapper/$enc_dev_short_name";

  $dev_alias{$dev} = $enc_dev_name;
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
    m{^/dev/(cciss/c\d+d\d+|ida/c\d+d\d+|rd/c\d+d\d+|ataraid/d\d+|etherd/e\d+\.\d+)$});
  if ((&FAI::loopback_dev($dev))[0])
  {
    $p += (&FAI::loopback_dev($dev))[1];
    $dev = "/dev/loop"
  }
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

  use Carp;
  $Carp::CarpLevel = 1;
  confess <<EOF;
INTERNAL ERROR in setup-storage:
$error_msg
Please report this error to the Debian Bug Tracking System.
EOF
}

1;

