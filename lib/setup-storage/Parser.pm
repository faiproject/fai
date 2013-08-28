#!/usr/bin/perl -w

# $Id$
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
# @file parser.pm
#
# @brief A parser for the disk_config files within FAI.
#
# $Id$
#
# @author Christian Kern, Michael Tautschnig, Sam Vilain, Andreas Schludei
# @date Sun Jul 23 16:09:36 CEST 2006
#
################################################################################

use Parse::RecDescent;
use Storable qw(dclone);

package FAI;

################################################################################
#
# @brief the name of the device currently being configured, including a prefix
# such as PHY_ or VG_ to indicate physical devices or LVM volume groups. For
# RAID, the entry is only "RAID"
#
################################################################################
$FAI::device = "";

################################################################################
#
# @brief Test, whether @ref $cmd is available on the system using $PATH
#
# @param $cmd Command that is to be found in $PATH
#
# @return 1, if the command is found, else 0
#
################################################################################
sub in_path {

  # initialize the parameter
  my ($cmd) = @_;

  # ignored in syntax-check mode
  return 1 if ($FAI::check_only);

  # check full path names first
  ($cmd =~ /^\//) and return (-x "$cmd");

  # split $PATH into its components, search all of its components
  # and test for $cmd being executable
  (-x "$_/$cmd") and return 1 foreach (split (":", $ENV{PATH}));
  # return 0 otherwise
  return 0;
}

################################################################################
# @brief Determines a device's full path from a short name or number
#
# Resolves the device name (/dev/sda), short name (sda) or device number (0) to
# a full device name (/dev/sda) and tests whether the device is a valid block
# device.
#
# @param $disk Either an integer, occurring in the context of, e.g., disk2, or
# a device name. The latter may be fully qualified, such as /dev/hda, or a short
# name, such as sdb, in which case /dev/ is prepended.
################################################################################
sub resolve_disk_shortname {
  my ($disk) = @_;

  $disk = "sdx" . chr(ord('a') + $disk - 1)
    if ($FAI::check_only && $disk =~ /^\d+$/);

  # test $disk for being numeric
  if ($disk =~ /^\d+$/) {
    # $disk-1 must be a valid index in the map of all disks in the system
    (scalar(@FAI::disks) >= $disk)
      or die "this system does not have a physical disk $disk\n";

    # fetch the (short) device name
    $disk = $FAI::disks[ $disk - 1 ];
  }

  # test, whether the device name starts with a / and prepend /dev/, if
  # appropriate
  ($disk =~ m{^/}) or $disk = "/dev/$disk";
  my @candidates = glob($disk);
  die "Failed to resolve $disk to a unique device name\n" if (scalar(@candidates) > 1);
  $disk = $candidates[0] if (scalar(@candidates) == 1);
  die "Device name $disk could not be substituted\n" if ($disk =~ m{[\*\?\[\{\~]});

  return $disk;
}

################################################################################
#
# @brief Initialise a new entry in @ref $FAI::configs for a physical disk.
#
# Checks whether the specified device is valid, creates the entry in the hash
# and sets @ref $FAI::device.
#
# @param $disk Either an integer, occurring in the context of, e.g., disk2, or
# a device name. The latter may be fully qualified, such as /dev/hda, or a short
# name, such as sdb, in which case /dev/ is prepended.
#
################################################################################
sub init_disk_config {

  # Initialise $disk
  my ($disk) = @_;

  $disk = &FAI::resolve_disk_shortname($disk);

  &FAI::in_path("losetup") or die "losetup not found in PATH\n"
    if ((&FAI::loopback_dev($disk))[0]);

  # prepend PHY_
  $FAI::device = "PHY_$disk";

  # test, whether this is the first disk_config stanza to configure $disk
  defined ($FAI::configs{$FAI::device})
    and die "Duplicate configuration for disk $disk\n";

  # Initialise the entry in $FAI::configs
  $FAI::configs{$FAI::device} = {
    virtual    => 0,
    disklabel  => "msdos",
    bootable   => -1,
    fstabkey   => "device",
    preserveparts => 0,
    partitions => {},
    opts_all   => {}
  };

  # Init device tree object
  $FAI::dev_children{$disk} = ();

  return 1;
}

################################################################################
#
# @brief Initialise the entry of a partition in @ref $FAI::configs
#
# @param $type The type of the partition. It must be either primary or logical
# or raw.
#
################################################################################
sub init_part_config {

  # the type of the partition to be created
  my ($type) = @_;

  # type must either be primary or logical or raw, nothing else may be accepted
  # by the parser
  ($type eq "primary" || $type eq "logical" || $type eq "raw") or
    &FAI::internal_error("invalid type $type");

  # check that a physical device is being configured; logical partitions are
  # only supported on msdos disk labels.
  ($FAI::device =~ /^PHY_(.+)$/ && ($type ne "logical"
      || $FAI::configs{$FAI::device}{disklabel} eq "msdos")) or 
    die "Syntax error: invalid partition type";

  # the disk
  my $disk = $1;

  # the index of the new partition
  my $part_number = 0;

  # defaults from options
  my $preserve_default =
    defined($FAI::configs{$FAI::device}{opts_all}{preserve}) ? 1 :
      (defined($FAI::configs{$FAI::device}{opts_all}{preserve_lazy}) ? 2 : 0);
  my $always_format_default =
    defined($FAI::configs{$FAI::device}{opts_all}{always_format}) ? 1 : 0;
  my $resize_default =
    defined($FAI::configs{$FAI::device}{opts_all}{resize}) ? 1 : 0;

  # create a primary partition
  if ($type eq "primary") {
    (defined($FAI::configs{$FAI::device}{partitions}{0})) and
      die "You cannot use raw-disk together with primary/logical partitions\n";

    # find all previously defined primary partitions
    foreach my $part_id (&numsort(keys %{ $FAI::configs{$FAI::device}{partitions} })) {

      # break, if the partition has not been created by init_part_config
      defined ($FAI::configs{$FAI::device}{partitions}{$part_id}{size}{extended}) or last;

      # on msdos disklabels we cannot have more than 4 primary partitions
      last if ($part_id > 4 && ! $FAI::configs{$FAI::device}{virtual}
        && $FAI::configs{$FAI::device}{disklabel} eq "msdos");

      # store the latest index found
      $part_number = $part_id;
    }

    # the next index available - note that $part_number might have been 0
    $part_number++;

    # msdos disk labels don't allow for more than 4 primary partitions
    ($part_number < 5 || $FAI::configs{$FAI::device}{virtual} || 
      $FAI::configs{$FAI::device}{disklabel} ne "msdos")
      or die "$part_number are too many primary partitions\n";
  } elsif ($type eq "raw") {
    (0 == scalar(keys %{ $FAI::configs{$FAI::device}{partitions} })) or
      die "You cannot use raw-disk together with primary/logical partitions\n";
    # special-case hack: part number 0 is invalid otherwise
    $part_number = 0;
  } else {
    (defined($FAI::configs{$FAI::device}{partitions}{0})) and
      die "You cannot use raw-disk together with primary/logical partitions\n";

    # no further checks for the disk label being msdos have to be performed in
    # this branch, it has been ensured above

    # find the index of the new partition, initialise it to the highest current index
    foreach my $part_id (&numsort(keys %{ $FAI::configs{$FAI::device}{partitions} })) {

      # skip primary partitions
      next if ($part_id < 5);

      # break, if the partition has not been created by init_part_config
      defined($FAI::configs{$FAI::device}{partitions}{$part_id}{size}{extended})
        or last;

      # store the latest index found
      $part_number = $part_id;
    }

    # and use the next one available
    $part_number++;

    # if this is the first logical partition, the index must be set to 5 and an
    # extended partition  must be created
    if ($part_number <= 5) {
      $part_number = 5;

      # the proposed index of the extended partition
      my $extended = 0;

      # find all previously defined primary partitions
      foreach my $part_id (&numsort(keys %{ $FAI::configs{$FAI::device}{partitions} })) {

        # break, if the partition has not been created by init_part_config
        defined ($FAI::configs{$FAI::device}{partitions}{$part_id}{size}{extended}) or last;

        # we cannot have more than 4 primary partitions
        last if ($part_id > 4);

        # store the latest index found
        $extended = $part_id;
      }

      # the next index available
      $extended++;

      # msdos disk labels don't allow for more than 4 primary partitions
      ($extended < 5)
        or die "Too many primary partitions; cannot add extended partition\n";

      # initialize the entry, unless it already exists
      defined ($FAI::configs{$FAI::device}{partitions}{$extended})
        or (\%FAI::configs)->{$FAI::device}->{partitions}->{$extended} = {
          size => {}
        };

      my $part_size =
        (\%FAI::configs)->{$FAI::device}->{partitions}->{$extended}->{size};

      # mark the entry as an extended partition
      $part_size->{extended} = 1;

      # add the preserve = 0 flag, if it doesn't exist already
      defined ($part_size->{preserve})
        or $part_size->{preserve} = 0;

      # add the always_format = 0 flag, if it doesn't exist already
      defined ($part_size->{always_format})
        or $part_size->{always_format} = 0;

      # add the resize = default flag, if it doesn't exist already
      defined ($part_size->{resize}) or $part_size->{resize} = $resize_default;

      # add entry to device tree
      push @{ $FAI::dev_children{$disk} }, &FAI::make_device_name($disk, $extended);
    }
  }

  # initialise the hash for the partitions, if it doesn't exist already
  # note that it might exists due to options, such as preserve:x,y
  # the initialisation is required for the reference defined next
  defined ($FAI::configs{$FAI::device}{partitions}{$part_number})
    or $FAI::configs{$FAI::device}{partitions}{$part_number} = {};

  # set the reference to the current partition
  # the reference is used by all further processing of this config line
  $FAI::partition_pointer =
    (\%FAI::configs)->{$FAI::device}->{partitions}->{$part_number};
  $FAI::partition_pointer_dev_name = &FAI::make_device_name($disk, $part_number);

  # the partition is not an extended one
  $FAI::partition_pointer->{size}->{extended} = 0;

  # add the preserve = 0 flag, if it doesn't exist already
  defined ($FAI::partition_pointer->{size}->{preserve})
    or $FAI::partition_pointer->{size}->{preserve} = $preserve_default;

  # add the always_format = 0 flag, if it doesn't exist already
  defined ($FAI::partition_pointer->{size}->{always_format})
    or $FAI::partition_pointer->{size}->{always_format} = $always_format_default;

  # add the resize = 0 flag, if it doesn't exist already
  defined ($FAI::partition_pointer->{size}->{resize})
    or $FAI::partition_pointer->{size}->{resize} = $resize_default;

  # add entry to device tree
  push @{ $FAI::dev_children{$disk} }, $FAI::partition_pointer_dev_name;
}

################################################################################
#
# @brief This function converts different sizes to MiB
#
# @param $val is the number with its unit
#
################################################################################
sub convert_unit
{
  my ($val) = @_;

  if ($val =~ /^RAM:(\d+)%/) {
      $val = $1 / 100.0;

      ## get total RAM
      open(F, "/proc/meminfo");
      my @meminfo = <F>;
      close F;

      my ($totalmem) = grep /^MemTotal:/, @meminfo;
      $totalmem =~ s/[^0-9]//g;
      $totalmem = $totalmem / 1024.0;

      return $val * $totalmem;
  }

  # % is returned as is
  if ($val =~ /^(\d+(\.\d+)?)%\s*$/) { 1; }
  elsif ($val =~ /^(\d+(\.\d+)?)B\s*$/) { $val = $1 * (1 / 1024) * (1 / 1024); }
  elsif ($val =~ /^(\d+(\.\d+)?)[kK](iB)?\s*$/) { $val = $1 * (1 / 1024); }
  elsif ($val =~ /^(\d+(\.\d+)?)[kK]B\s*$/) { $val = $1 * (1000 / 1024) * (1 / 1024); }
  elsif ($val =~ /^(\d+(\.\d+)?)M(iB)?\s*$/) { $val = $1; }
  elsif ($val =~ /^(\d+(\.\d+)?)MB\s*$/) { $val = $1 * (1000 / 1024) * (1000 / 1024); }
  elsif ($val =~ /^(\d+(\.\d+)?)G(iB)?\s*$/) { $val = $1 * 1024; }
  elsif ($val =~ /^(\d+(\.\d+)?)GB\s*$/) { $val = $1 * 1000 * (1000 / 1024) * (1000 / 1024); }
  elsif ($val =~ /^(\d+(\.\d+)?)T(iB)?\s*$/) { $val = $1 * (1024 * 1024); }
  elsif ($val =~ /^(\d+(\.\d+)?)TB\s*$/) { $val = $1 * 1000 * 1000 * (1000 / 1024) * (1000 / 1024); }
  elsif ($val =~ /^(\d+(\.\d+)?)P(iB)?\s*$/) { $val = $1 * (1024 * 1024 * 1024); }
  elsif ($val =~ /^(\d+(\.\d+)?)PB\s*$/) { $val = $1 * 1000 * 1000 * 1000 * (1000 / 1024) * (1000 / 1024); }
  else { &FAI::internal_error("convert_unit $val"); }

  return $val;
}

################################################################################
#
# @brief Fill the "size" key of a partition or volume entry
#
# @param $range Actual size
# @param $options Additional options such as preserve or resize
#
################################################################################
sub set_volume_size
{
  my ($range, $options) = @_;

  # convert the units, if necessary
  my ($min, $max) = split (/-/, $range);
  $min .= "MiB" if ($min =~ /\d\s*$/);
  $min   = &FAI::convert_unit($min);
  $max .= "MiB" if ($max =~ /\d\s*$/);
  $max   = &FAI::convert_unit($max);
  # enter the range into the hash
  $FAI::partition_pointer->{size}->{range} = "$min-$max";
  # set the resize or preserve flag, if required
  if (defined ($options)) {
    $FAI::configs{$FAI::device}{preserveparts} = 1;
    $FAI::partition_pointer->{size}->{resize} = 1 if ($options =~ /^:resize/);
    $FAI::partition_pointer->{size}->{preserve} = 1 if ($options =~ /^:preserve_always/);
    $FAI::partition_pointer->{size}->{preserve} = 1
    if ($FAI::reinstall && $options =~ /^:preserve_reinstall/);
    if ($options =~ /^:preserve_lazy/) {
      $FAI::configs{$FAI::device}{preserveparts} = 2;
      $FAI::partition_pointer->{size}->{preserve} = 2;
    }
  }
}

# have RecDescent do proper error reporting
$::RD_HINT = 1;

################################################################################
#
# @brief The effective implementation of the parser is instantiated here
#
################################################################################
$FAI::Parser = Parse::RecDescent->new(
  q{
    file: line(s?) /\Z/
        {
          $return = 1;
        }

    line: <skip: qr/[ \t]*/> "\\n"
        | <skip: qr/[ \t]*/> comment "\\n"
        | <skip: qr/[ \t]*/> config "\\n"
        | <error>

    comment: /^\s*#.*/

    config: 'disk_config' disk_config_arg
        | volume

    disk_config_arg: 'raid'
        {
          # check, whether raid tools are available
          &FAI::in_path("mdadm") or die "mdadm not found in PATH\n";
          $FAI::device = "RAID";
          $FAI::configs{$FAI::device}{fstabkey} = "device";
          $FAI::configs{$FAI::device}{opts_all} = {};
        }
        raid_option(s?)
        | 'cryptsetup'
        {
          &FAI::in_path("cryptsetup") or die "cryptsetup not found in PATH\n";
          $FAI::device = "CRYPT";
          $FAI::configs{$FAI::device}{fstabkey} = "device";
          $FAI::configs{$FAI::device}{randinit} = 0;
          $FAI::configs{$FAI::device}{volumes} = {};
        }
        cryptsetup_option(s?)
        | /^lvm/
        {

          # check, whether lvm tools are available
          &FAI::in_path("lvcreate") or die "LVM tools not found in PATH\n";
          # initialise $FAI::device to inform the following lines about the LVM
          # being configured
          $FAI::device = "VG_";
          $FAI::configs{"VG_--ANY--"}{fstabkey} = "device";
          $FAI::configs{"VG_--ANY--"}{opts_all} = {};
        }
        lvm_option(s?)
        | 'end'
        {
          # exit config mode
          $FAI::device = "";
        }
        | /^tmpfs/
        {
          $FAI::device = "TMPFS";
          $FAI::configs{$FAI::device}{fstabkey} = "device";
          $FAI::configs{$FAI::device}{volumes} = {};
        }
        | /^disk(\d+)/
        {
          # check, whether parted is available
          &FAI::in_path("parted") or die "parted not found in PATH\n";
          # initialise the entry of the hash corresponding to disk$1
          &FAI::init_disk_config($1);
        }
        option(s?)
        | /^\S+/
        {
          # check, whether parted is available
          &FAI::in_path("parted") or die "parted not found in PATH\n";
          # initialise the entry of the hash corresponding to $item[1]
          &FAI::init_disk_config($item[ 1 ]);
        }
        option(s?)
        | <error>

    raid_option: /^preserve_always:((\d+(,\d+)*)|all)/
        {
          if ($1 eq "all") {
            $FAI::configs{RAID}{opts_all}{preserve} = 1;
          } else {
            # set the preserve flag for all ids in all cases
            $FAI::configs{RAID}{volumes}{$_}{preserve} = 1 foreach (split (",", $1));
          }
        }
        | /^preserve_reinstall:((\d+(,\d+)*)|all)/
        {
          # set the preserve flag for all ids if $FAI::reinstall is set
          if ($FAI::reinstall) {
            if ($1 eq "all") {
              $FAI::configs{RAID}{opts_all}{preserve} = 1;
            } else {
              $FAI::configs{RAID}{volumes}{$_}{preserve} = 1 foreach (split(",", $1));
            }
          }
        }
        | /^preserve_lazy:((\d+(,\d+)*)|all)/
        {
          if ($1 eq "all") {
            $FAI::configs{RAID}{opts_all}{preserve_lazy} = 1;
          } else {
            $FAI::configs{RAID}{volumes}{$_}{preserve} = 2 foreach (split(",", $1));
          }
        }
        | /^fstabkey:(device|label|uuid)/
        {
          # the information preferred for fstab device identifieres
          $FAI::configs{$FAI::device}{fstabkey} = $1;
        }
        | /^always_format:((\d+(,\d+)*)|all)/
        {
          if ($1 eq "all") {
            $FAI::configs{RAID}{opts_all}{always_format} = 1;
          } else {
            $FAI::configs{RAID}{volumes}{$_}{always_format} = 1 foreach (split (",", $1));
          }
        }

    cryptsetup_option: /^randinit/
        {
          $FAI::configs{$FAI::device}{randinit} = 1;
        }

    lvm_option: m{^preserve_always:(([^/,\s\-]+-[^/,\s\-]+(,[^/,\s\-]+-[^/,\s\-]+)*)|all)}
        {
          if ($1 eq "all") {
            $FAI::configs{"VG_--ANY--"}{opts_all}{preserve} = 1;
          } else {
            # set the preserve flag for all ids in all cases
            foreach (split (",", $1)) {
              (m{^([^/,\s\-]+)-([^/,\s\-]+)}) or
                die &FAI::internal_error("VG re-parse failed");
              $FAI::configs{"VG_$1"}{volumes}{$2}{size}{preserve} = 1;
            }
          }
        }
        | m{^preserve_reinstall:(([^/,\s\-]+-[^/,\s\-]+(,[^/,\s\-]+-[^/,\s\-]+)*)|all)}
        {
          # set the preserve flag for all ids if $FAI::reinstall is set
          if ($FAI::reinstall) {
            if ($1 eq "all") {
              $FAI::configs{"VG_--ANY--"}{opts_all}{preserve} = 1;
            } else {
              foreach (split (",", $1)) {
                (m{^([^/,\s\-]+)-([^/,\s\-]+)}) or
                  die &FAI::internal_error("VG re-parse failed");
                $FAI::configs{"VG_$1"}{volumes}{$2}{size}{preserve} = 1;
              }
            }
          }
        }
        | m{^preserve_lazy:(([^/,\s\-]+-[^/,\s\-]+(,[^/,\s\-]+-[^/,\s\-]+)*)|all)}
        {
          if ($1 eq "all") {
            $FAI::configs{"VG_--ANY--"}{opts_all}{preserve_lazy} = 1;
          } else {
            foreach (split (",", $1)) {
              (m{^([^/,\s\-]+)-([^/,\s\-]+)}) or
                die &FAI::internal_error("VG re-parse failed");
              $FAI::configs{"VG_$1"}{volumes}{$2}{size}{preserve} = 2;
            }
          }
        }
        | m{^resize:(([^/,\s\-]+-[^/,\s\-]+(,[^/,\s\-]+-[^/,\s\-]+)*)|all)}
        {
          if ($1 eq "all") {
            $FAI::configs{"VG_--ANY--"}{opts_all}{resize} = 1;
          } else {
            # set the resize flag for all ids
            foreach (split (",", $1)) {
              (m{^([^/,\s\-]+)-([^/,\s\-]+)}) or
                die &FAI::internal_error("VG re-parse failed");
              $FAI::configs{"VG_$1"}{volumes}{$2}{size}{resize} = 1;
            }
          }
        }
        | /^fstabkey:(device|label|uuid)/
        {
          # the information preferred for fstab device identifieres
          $FAI::configs{"VG_--ANY--"}{fstabkey} = $1;
        }
        | m{^always_format:(([^/,\s\-]+-[^/,\s\-]+(,[^/,\s\-]+-[^/,\s\-]+)*)|all)}
        {
          if ($1 eq "all") {
            $FAI::configs{"VG_--ANY--"}{opts_all}{always_format} = 1;
          } else {
            foreach (split (",", $1)) {
              (m{^([^/,\s\-]+)-([^/,\s\-]+)}) or
                die &FAI::internal_error("VG re-parse failed");
              $FAI::configs{"VG_$1"}{volumes}{$2}{size}{always_format} = 1;
            }
          }
        }


    option: /^preserve_always:((\d+(,\d+)*)|all)/
        {
          if ($1 eq "all") {
            $FAI::configs{$FAI::device}{opts_all}{preserve} = 1;
          } else {
            # set the preserve flag for all ids in all cases
            $FAI::configs{$FAI::device}{partitions}{$_}{size}{preserve} = 1 foreach (split (",", $1));
          }
          $FAI::configs{$FAI::device}{preserveparts} = 1;
        }
        | /^preserve_reinstall:((\d+(,\d+)*)|all)/
        {
          # set the preserve flag for all ids if $FAI::reinstall is set
          if ($FAI::reinstall) {
            if ($1 eq "all") {
              $FAI::configs{$FAI::device}{opts_all}{preserve} = 1;
            } else {
              $FAI::configs{$FAI::device}{partitions}{$_}{size}{preserve} = 1 foreach (split(",", $1));
            }
            $FAI::configs{$FAI::device}{preserveparts} = 1;
          }
        }
        | /^preserve_lazy:((\d+(,\d+)*)|all)/
        {
          if ($1 eq "all") {
            $FAI::configs{$FAI::device}{opts_all}{preserve_lazy} = 1;
          } else {
            $FAI::configs{$FAI::device}{partitions}{$_}{size}{preserve} = 2 foreach (split(",", $1));
          }
          $FAI::configs{$FAI::device}{preserveparts} = 2;
        }
        | /^resize:((\d+(,\d+)*)|all)/
        {
          if ($1 eq "all") {
            $FAI::configs{$FAI::device}{opts_all}{resize} = 1;
          } else {
            # set the resize flag for all ids
            $FAI::configs{$FAI::device}{partitions}{$_}{size}{resize} = 1 foreach (split(",", $1));
          }
          $FAI::configs{$FAI::device}{preserveparts} = 1;
        }
        | /^disklabel:(\S+)/
        {
          my $dl = $1;
          ($dl =~ /^(msdos|gpt-bios|gpt)$/) or die
            "Invalid disk label $dl; use one of msdos|gpt-bios|gpt\n";
          # set the disk label - actually not only the above, but all types 
          # supported by parted could be allowed, but others are not implemented
          # yet
          $FAI::configs{$FAI::device}{disklabel} = $dl;
        }
        | /^bootable:(\d+)/
        {
          # specify a partition that should get the bootable flag set
          $FAI::configs{$FAI::device}{bootable} = $1;
          ($FAI::device =~ /^PHY_(.+)$/) or
            &FAI::internal_error("unexpected device name");
        }
        | 'virtual'
        {
          # this is a configuration for a virtual disk
          $FAI::configs{$FAI::device}{virtual} = 1;
        }
        | /^fstabkey:(device|label|uuid)/
        {
          # the information preferred for fstab device identifieres
          $FAI::configs{$FAI::device}{fstabkey} = $1;
        }
	| /^sameas:disk(\d+)/
	{
	  my $ref_dev = &FAI::resolve_disk_shortname($1);
	  defined($FAI::configs{"PHY_" . $ref_dev}) or die "Reference device $ref_dev not found in config\n";

	  $FAI::configs{$FAI::device} = Storable::dclone($FAI::configs{"PHY_" . $ref_dev});
    # add entries to device tree
    defined($FAI::dev_children{$ref_dev}) or
      &FAI::internal_error("dev_children missing reference entry");
    ($FAI::device =~ /^PHY_(.+)$/) or
      &FAI::internal_error("unexpected device name");
    my $disk = $1;
    foreach my $p (@{ $FAI::dev_children{$ref_dev} }) {
      my ($i_p_d, $rd, $pd) = &FAI::phys_dev($p);
      (1 == $i_p_d) or next;
      ($rd eq $ref_dev) or &FAI::internal_error("dev_children is inconsistent");
      push @{ $FAI::dev_children{$disk} }, &FAI::make_device_name($disk, $pd);
    }
	}
	| /^sameas:(\S+)/
	{
	  my $ref_dev = &FAI::resolve_disk_shortname($1);
	  defined($FAI::configs{"PHY_" . $ref_dev}) or die "Reference device $ref_dev not found in config\n";

	  $FAI::configs{$FAI::device} = Storable::dclone($FAI::configs{"PHY_" . $ref_dev});
    # add entries to device tree
    defined($FAI::dev_children{$ref_dev}) or
      &FAI::internal_error("dev_children missing reference entry");
    ($FAI::device =~ /^PHY_(.+)$/) or
      &FAI::internal_error("unexpected device name");
    my $disk = $1;
    foreach my $p (@{ $FAI::dev_children{$ref_dev} }) {
      my ($i_p_d, $rd, $pd) = &FAI::phys_dev($p);
      (1 == $i_p_d) or next;
      ($rd eq $ref_dev) or &FAI::internal_error("dev_children is inconsistent");
      push @{ $FAI::dev_children{$disk} }, &FAI::make_device_name($disk, $pd);
    }
	}
        | /^always_format:((\d+(,\d+)*)|all)/
        {
          if ($1 eq "all") {
            $FAI::configs{$FAI::device}{opts_all}{always_format} = 1;
          } else {
            $FAI::configs{$FAI::device}{partitions}{$_}{size}{always_format} = 1 foreach (split(",", $1));
          }
        }
        | /^align-at:(\d+)([kKMGTPiB]+)?/
        {
          my $u = defined($2) ? $2 : "MiB";
          $FAI::configs{$FAI::device}{align_at} = &FAI::convert_unit("$1$u") * 1024.0 * 1024.0;
        }

    volume: /^vg\s+/ name devices vgcreateopt(s?)
        | /^raid([0156]|10)\s+/
        {
          # make sure that this is a RAID configuration
          ($FAI::device eq "RAID") or die "RAID entry invalid in this context\n";
          # initialise RAID entry, if it doesn't exist already
          defined ($FAI::configs{RAID}) or $FAI::configs{RAID}{volumes} = {};
          # compute the next available index - the size of the entry or the
          # first not fully defined entry
          my $vol_id = 0;
          foreach my $ex_vol_id (&FAI::numsort(keys %{ $FAI::configs{RAID}{volumes} })) {
            defined ($FAI::configs{RAID}{volumes}{$ex_vol_id}{mode}) or last;
            $vol_id++;
          }
          # set the RAID type of this volume
          $FAI::configs{RAID}{volumes}{$vol_id}{mode} = $1;
          # initialise the hash of devices
          $FAI::configs{RAID}{volumes}{$vol_id}{devices} = {};
          # initialise the flags
          defined($FAI::configs{RAID}{volumes}{$vol_id}{preserve}) or
            $FAI::configs{RAID}{volumes}{$vol_id}{preserve} =
              defined($FAI::configs{RAID}{opts_all}{preserve}) ? 1 :
                (defined($FAI::configs{RAID}{opts_all}{preserve_lazy}) ? 2 : 0);
          defined($FAI::configs{RAID}{volumes}{$vol_id}{always_format}) or
            $FAI::configs{RAID}{volumes}{$vol_id}{always_format} =
              defined($FAI::configs{RAID}{opts_all}{always_format}) ? 1 : 0;
          # set the reference to the current volume
          # the reference is used by all further processing of this config line
          $FAI::partition_pointer = (\%FAI::configs)->{RAID}->{volumes}->{$vol_id};
          $FAI::partition_pointer_dev_name = "/dev/md$vol_id";
        }
        mountpoint devices filesystem mount_options mdcreateopts
        | /^(luks|luks:"[^"]+"|tmp|swap)\s+/
        {
          ($FAI::device eq "CRYPT") or
            die "Encrypted device spec $1 invalid in context $FAI::device\n";
          defined ($FAI::configs{CRYPT}) or &FAI::internal_error("CRYPT entry missing");

          my $vol_id = 0;
          foreach my $ex_vol_id (&FAI::numsort(keys %{ $FAI::configs{CRYPT}{volumes} })) {
            defined ($FAI::configs{CRYPT}{volumes}{$ex_vol_id}{mode}) or last;
            $vol_id++;
          }

          $FAI::configs{CRYPT}{volumes}{$vol_id}{mode} = $1;

          # We don't do preserve for encrypted devices
          $FAI::configs{CRYPT}{volumes}{$vol_id}{preserve} = 0;

          $FAI::partition_pointer = (\%FAI::configs)->{CRYPT}->{volumes}->{$vol_id};
          $FAI::partition_pointer_dev_name = "CRYPT$vol_id";
        }
        mountpoint devices filesystem mount_options lv_or_fsopts
        | /^tmpfs\s+/
        {
          ($FAI::device eq "TMPFS") or die "tmpfs entry invalid in this context\n";
          defined ($FAI::configs{TMPFS}) or &FAI::internal_error("TMPFS entry missing");

          my $vol_id = 0;
          foreach my $ex_vol_id (&FAI::numsort(keys %{ $FAI::configs{TMPFS}{volumes} })) {
            defined ($FAI::configs{TMPFS}{volumes}{$ex_vol_id}{device}) or last;
            $vol_id++;
          }

          $FAI::configs{TMPFS}{volumes}{$vol_id}{device} = "tmpfs";
          $FAI::configs{TMPFS}{volumes}{$vol_id}{filesystem} = "tmpfs";

          # We don't do preserve for tmpfs
          $FAI::configs{TMPFS}{volumes}{$vol_id}{preserve} = 0;

          $FAI::partition_pointer = (\%FAI::configs)->{TMPFS}->{volumes}->{$vol_id};
          $FAI::partition_pointer_dev_name = "TMPFS$vol_id";
        }
        mountpoint tmpfs_size mount_options
        | type mountpoint size filesystem mount_options lv_or_fsopts
        | <error>

    type: 'primary'
        {
          # initialise a primary partition
          &FAI::init_part_config($item[ 1 ]);
        }
        | 'logical'
        {
          # initialise a logical partition
          &FAI::init_part_config($item[ 1 ]);
        }
        | 'raw-disk'
        {
          # initialise a pseudo-partition: this disk will be used without
          # partitioning it
          &FAI::init_part_config("raw");
        }
        | m{^([^/,\s\-]+)-([^/,\s\-]+)\s+}
        {
          # set $FAI::device to VG_$1
          $FAI::device = "VG_$1";
          # make sure, the volume group $1 has been defined before
          defined ($FAI::configs{$FAI::device}{devices}) or
            die "Volume group $1 has not been declared yet.\n";
          # make sure, $2 has not been defined already
          defined ($FAI::configs{$FAI::device}{volumes}{$2}{size}{range}) and 
            die "Logical volume $2 has been defined already.\n";
          # add to ordered list
          push @{ $FAI::configs{$FAI::device}{ordered_lv_list} }, $2;
          # initialise the new hash
          defined($FAI::configs{$FAI::device}{volumes}{$2}) or
            $FAI::configs{$FAI::device}{volumes}{$2} = {};
          # initialise the flags
          defined($FAI::configs{$FAI::device}{volumes}{$2}{size}{preserve}) or
            $FAI::configs{$FAI::device}{volumes}{$2}{size}{preserve} =
              defined($FAI::configs{"VG_--ANY--"}{opts_all}{preserve}) ? 1 :
                (defined($FAI::configs{"VG_--ANY--"}{opts_all}{preserve_lazy}) ? 2 : 0);
          defined($FAI::configs{$FAI::device}{volumes}{$2}{size}{always_format}) or
            $FAI::configs{$FAI::device}{volumes}{$2}{size}{always_format} =
              defined($FAI::configs{"VG_--ANY--"}{opts_all}{always_format}) ? 1 : 0;
          defined($FAI::configs{$FAI::device}{volumes}{$2}{size}{resize}) or
            $FAI::configs{$FAI::device}{volumes}{$2}{size}{resize} =
              defined($FAI::configs{"VG_--ANY--"}{opts_all}{resize}) ? 1 : 0;
          # set the reference to the current volume
          # the reference is used by all further processing of this config line
          $FAI::partition_pointer = (\%FAI::configs)->{$FAI::device}->{volumes}->{$2};
          $FAI::partition_pointer_dev_name = "/dev/$1/$2";
          # add entry to device tree
          push @{ $FAI::dev_children{$FAI::device} }, $FAI::partition_pointer_dev_name;
        }

    mountpoint: m{^(-|swap|/[^\s\:]*)(:encrypt(:randinit)?)?}
        {
          # set the mount point, may include encryption-request
          $FAI::partition_pointer->{mountpoint} = $1;
          $FAI::partition_pointer->{mountpoint} = "none" if ($1 eq "swap");
          if (defined($2)) {
            warn "Old-style inline encrypt will be deprecated. Please add cryptsetup definitions (see man 8 setup-storage).\n";
            &FAI::in_path("cryptsetup") or die "cryptsetup not found in PATH\n";
            $FAI::partition_pointer->{encrypt} = 1;
            ++$FAI::partition_pointer->{encrypt} if (defined($3));
          } else {
            $FAI::partition_pointer->{encrypt} = 0;
          }
        }

    name: m{^([^/,\s\-]+)}
        {
          # set the device name to VG_ and the name of the volume group
          $FAI::device = "VG_$1";
          # make sure, the volume group $1 not has been defined already
          defined ($FAI::configs{$FAI::device}{devices}) and
            die "Volume group $1 has been defined already.\n";
          # make sure this line is part of an LVM configuration
          ($FAI::device =~ /^VG_/) or
            die "vg is invalid in a non LVM-context.\n";
          # initialise the new hash unless some preserve/define already created
          # it
          defined($FAI::configs{$FAI::device}{volumes}) or
            $FAI::configs{$FAI::device}{volumes} = {};
          # initialise the list of physical devices
          $FAI::configs{$FAI::device}{devices} = ();
          # initialise the ordered list of volumes
          $FAI::configs{$FAI::device}{ordered_lv_list} = ();
          # init device tree
          $FAI::dev_children{$FAI::device} = ();
          # the rule must not return undef
          1;
        }

    size: /^((RAM:\d+%|\d+[kKMGTP%iB]*)(-(RAM:\d+%|\d+[kKMGTP%iB]*)?)?)(:resize|:preserve_(always|reinstall|lazy))?/
        {
          # complete the size specification to be a range in all cases
          my $range = $1;
          # the size is fixed
          if (!defined ($3))
          {
            # make it a range of the form x-x
            $range = "$range-$2";
          }
          elsif (!defined ($4))
          {
            # range has no upper limit, assume the whole disk
            $range = "${range}100%";
          }

          &FAI::set_volume_size($range, $5);
        }
        | /^(-(RAM:\d+%|\d+[kKMGTP%iB]*))(:resize|:preserve_(always|reinstall|lazy))?\s+/
        {
          # complete the range by assuming 0 as the lower limit 
          &FAI::set_volume_size("0$1", $3);
        }
        | <error: invalid partition size near "$text">

    tmpfs_size: /^(RAM:(\d+%)|\d+[kKMGTPiB]*)\s+/
        {
          my $size;

          # convert the units, if necessary
          # A percentage is kept as is as tmpfs handles it
          if (defined($2)) {
            $size = $2;
          } else {
            $size = $1;
            $size .= "MiB" if ($size =~ /\d\s*$/);
            $size  = &FAI::convert_unit($size);
            # Size in MiB for tmpfs
            $size .= "m";
          }

          # enter the size into the hash
          $FAI::partition_pointer->{size} = $size;
        }
        | <error: invalid tmpfs size near "$text">

    devices: /^([^\d,:\s\-][^,:\s]*(:(spare|missing))*(,[^,:\s]+(:(spare|missing))*)*)/
        {
          # split the device list by ,
          foreach my $dev (split(",", $1))
          {
            # match the substrings
            ($dev =~ /^([^\d,:\s\-][^,:\s]*)(:(spare|missing))*$/) or 
              &FAI::internal_error("PARSER ERROR");
            # redefine the device string
            $dev = $1;
            # store the options
            my $opts = $2;
            # make $dev a full path name; can't validate device name yet as it
            # might be created later on
            unless ($dev =~ m{^/}) {
              if ($dev =~ m/^disk(\d+)\.(\d+)/) {
                $dev = &FAI::make_device_name("/dev/" . $FAI::disks[ $1 - 1 ], $2);
              } elsif ($dev =~ m/^disk(\d+)/) {
                $dev = "/dev/" . $FAI::disks[ $1 - 1 ];
              } else {
                $dev = "/dev/$dev";
              }
            }
            my @candidates = glob($dev);

            # options are only valid for RAID
            defined ($opts) and ($FAI::device ne "RAID") and die "Option $opts invalid in a non-RAID context\n";
            if ($FAI::device eq "RAID") {
              # parse all options
              my $spare = 0;
              my $missing = 0;
              if (defined ($opts)) {
                ($opts =~ /spare/) and $spare = 1;
                ($opts =~ /missing/) and $missing = 1;
              }
              (($spare == 1 || $missing == 1) && $FAI::partition_pointer->{mode} == 0)
                and die "RAID-0 does not support spares or missing devices\n";
              if ($missing) {
                die "Failed to resolve $dev to a unique device name\n" if (scalar(@candidates) > 1);
                $dev = $candidates[0] if (scalar(@candidates) == 1);
              } else {
                die "Failed to resolve $dev to a unique device name\n" if (scalar(@candidates) != 1);
                $dev = $candidates[0];
              }
              # each device may only appear once
              defined ($FAI::partition_pointer->{devices}->{$dev}) and 
                die "$dev is already part of the RAID volume\n";
              # set the options
              $FAI::partition_pointer->{devices}->{$dev} = {
                "spare" => $spare,
                "missing" => $missing
              };
              # add entry to device tree
              push @{ $FAI::dev_children{$dev} }, $FAI::partition_pointer_dev_name;
            } elsif ($FAI::device eq "CRYPT") {
              die "Failed to resolve $dev to a unique device name\n" if (scalar(@candidates) != 1);
              $FAI::partition_pointer->{device} = $candidates[0];
              &FAI::mark_encrypted($candidates[0]);
              # add entry to device tree
              push @{ $FAI::dev_children{$candidates[0]} }, $FAI::partition_pointer_dev_name;
            } else {
              die "Failed to resolve $dev to a unique device name\n" if (scalar(@candidates) != 1);
              $dev = $candidates[0];
              # create an empty hash for each device
              $FAI::configs{$FAI::device}{devices}{$dev} = {};
              # add entry to device tree
              push @{ $FAI::dev_children{$dev} }, $FAI::device;
            }
          }
          1;
        }
        | <error: invalid device spec "$text">

    mount_options: /\S+/
        {
          $FAI::partition_pointer->{mount_options} = $item[ 1 ];
        }

    filesystem: '-'
        {
          $FAI::partition_pointer->{filesystem} = $item[ 1 ];
        }
        | 'swap'
        {
          $FAI::partition_pointer->{filesystem} = $item[ 1 ];
        }
        | /^\S+/
        {
          my ($fs, $journal) = split(/:/, $item[1]);
          my $to_be_preserved = 0;

          $FAI::partition_pointer->{filesystem} = $fs;

          defined($journal) and $journal =~ s/journal=//;
          $FAI::partition_pointer->{journal_dev} = $journal;

          if ($FAI::device eq "RAID" or $FAI::device eq "CRYPT") {
            $to_be_preserved = $FAI::partition_pointer->{preserve};
          } else {
            $to_be_preserved = $FAI::partition_pointer->{size}->{preserve};
          }
          if (0 == $to_be_preserved) {
            $fs =~ s/_journal$//;

            &FAI::in_path("mkfs.$fs") or
              die "unknown/invalid filesystem type $fs (mkfs.$fs not found in PATH)\n";
          }
        }

    vgcreateopt: /pvcreateopts="([^"]*)"/
        {
          $FAI::configs{$FAI::device}{pvcreateopts} = $1 if (defined($1));
          # make sure this line is part of an LVM configuration
          ($FAI::device =~ /^VG_/) or
            die "pvcreateopts is invalid in a non LVM-context.\n";
        }
        | /vgcreateopts="([^"]*)"/
        {
          $FAI::configs{$FAI::device}{vgcreateopts} = $1 if (defined($1));
          # make sure this line is part of an LVM configuration
          ($FAI::device =~ /^VG_/) or
            die "vgcreateopts is invalid in a non LVM-context.\n";
        }

    mdcreateopts: /mdcreateopts="([^"]*)"/ createtuneopt(s?)
        {
          $FAI::partition_pointer->{mdcreateopts} = $1;
        }
        | createtuneopt(s?)

    lv_or_fsopts: /lvcreateopts="([^"]*)"/ createtuneopt(s?)
        {
          $FAI::partition_pointer->{lvcreateopts} = $1;
          ($FAI::device =~ /^VG_/) or
            die "lvcreateopts is invalid in a non LVM-context.\n";
        }
        | createtuneopt(s?)

    createtuneopt: /createopts="([^"]*)"/
        {
          $FAI::partition_pointer->{createopts} = $1;
        }
        | /tuneopts="([^"]*)"/
        {
          $FAI::partition_pointer->{tuneopts} = $1;
        }
}
);

################################################################################
#
# @brief Parse the data from <$IN> using @ref $FAI::Parser
#
# @param IN file handle for input file, may be STDIN
#
################################################################################
sub run_parser {
  my ($IN) = @_;

  # read <$IN> to a single string (not a list), thus $/ has to be unset
  my $ifs = $/;
  undef $/;
  my $input = <$IN>;
  $/ = $ifs;

  # print the contents of <$IN> for debugging purposes
  $FAI::debug and print "Input was:\n" . $input;

  # check for old-style configuration files
  ($input =~ m{(^|\n)[^\n#]+;})
    and die "Error: Old style configuration files are not supported\n";

  # attempt to parse $input - any error will lead to termination
  defined $FAI::Parser->file($input) or die "Syntax error\n";
}

################################################################################
#
# @brief Check for invalid configs (despite correct syntax)
#
################################################################################
sub check_config {

  my %all_mount_pts = ();

  # loop through all configs
  foreach my $config (keys %FAI::configs) {
    if ($config =~ /^PHY_(.+)$/) {
      (scalar(keys %{ $FAI::configs{$config}{partitions} }) > 0) or
        die "Empty disk_config stanza for device $1\n";
      foreach my $p (keys %{ $FAI::configs{$config}{partitions} }) {
        next if (1 == $FAI::configs{$config}{partitions}{$p}{size}{extended});
        defined($FAI::configs{$config}{partitions}{$p}{mountpoint}) or
          &FAI::internal_error("Undefined mountpoint for non-extended partition");
        my $this_mp = $FAI::configs{$config}{partitions}{$p}{mountpoint};
        next if ($this_mp eq "-");
        defined($all_mount_pts{$this_mp}) and die
          "Mount point $this_mp used twice\n";
        defined($FAI::dev_children{&FAI::make_device_name($1, $p)}) and die
          "Mount point $this_mp is shadowed by stacked devices\n";
        ($this_mp eq "none") or $all_mount_pts{$this_mp} = 1;
      }
    } elsif ($config =~ /^VG_(.+)$/) {
      next if ($1 eq "--ANY--");
      (scalar(keys %{ $FAI::configs{$config}{volumes} }) ==
        scalar(@{ $FAI::configs{$config}{ordered_lv_list} })) or
        &FAI::internal_error("Inconsistent LV lists - missing entries");
      defined($FAI::configs{$config}{volumes}{$_}) or
        &FAI::internal_error("Inconsistent LV lists - missing entries")
        foreach (@{ $FAI::configs{$config}{ordered_lv_list} });
      foreach my $p (keys %{ $FAI::configs{$config}{volumes} }) {
        my $this_mp = $FAI::configs{$config}{volumes}{$p}{mountpoint};
        next if ($this_mp eq "-");
        defined($all_mount_pts{$this_mp}) and die
          "Mount point $this_mp used twice\n";
        defined($FAI::dev_children{"/dev/$1/$p"}) and die
          "Mount point $this_mp is shadowed by stacked devices\n";
        ($this_mp eq "none") or $all_mount_pts{$this_mp} = 1;
      }
      next;
    } elsif ($config eq "RAID") {
      (scalar(keys %{ $FAI::configs{$config}{volumes} }) > 0) or
        die "Empty RAID configuration\n";
      foreach my $p (keys %{ $FAI::configs{$config}{volumes} }) {
        my $this_mp = $FAI::configs{$config}{volumes}{$p}{mountpoint};
        next if ($this_mp eq "-");
        defined($all_mount_pts{$this_mp}) and die
          "Mount point $this_mp used twice\n";
        defined($FAI::dev_children{"/dev/md$p"}) and die
          "Mount point $this_mp is shadowed by stacked devices\n";
        ($this_mp eq "none") or $all_mount_pts{$this_mp} = 1;
      }
    } elsif ($config eq "CRYPT") {
      foreach my $p (keys %{ $FAI::configs{$config}{volumes} }) {
        my $this_mp = $FAI::configs{$config}{volumes}{$p}{mountpoint};
        next if ($this_mp eq "-");
        defined($all_mount_pts{$this_mp}) and die
          "Mount point $this_mp used twice\n";
        ($this_mp eq "none") or $all_mount_pts{$this_mp} = 1;
      }
      next;
    } elsif ($config eq "TMPFS") {
      foreach my $p (keys %{ $FAI::configs{$config}{volumes} }) {
        my $this_mp = $FAI::configs{$config}{volumes}{$p}{mountpoint};
        next if ($this_mp eq "-");
        defined($all_mount_pts{$this_mp}) and die
          "Mount point $this_mp used twice\n";
        ($this_mp eq "none") or $all_mount_pts{$this_mp} = 1;
      }
      next;
    } else {
      &FAI::internal_error("Unexpected key $config");
    }
  }
}

1;

