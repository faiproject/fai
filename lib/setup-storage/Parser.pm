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

  # split $PATH into its components, search all of its components
  # and test for $cmd being executable
  (-x "$_/$cmd") and return 1 foreach (split (":", $ENV{PATH}));
  # return 0 otherwise
  return 0;
}

################################################################################
#
# @brief Initialise a new entry in @ref $FAI::configs for a physical disk.
#
# Besides creating the entry in the hash, the fully path of the device is
# computed (see @ref $disk) and it is tested, whether this is a block device.
# The device name is then used to define @ref $FAI::device.
#
# @param $disk Either an integer, occurring in the context of, e.g., disk2, or
# a device name. The latter may be fully qualified, such as /dev/hda, or a short
# name, such as sdb, in which case /dev/ is prepended.
#
################################################################################
sub init_disk_config {

  # Initialise $disk
  my ($disk) = @_;

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

  # prepend PHY_
  $FAI::device = "PHY_$disk";

  # test, whether this is the first disk_config stanza to configure $disk
  defined ($FAI::configs{$FAI::device})
    and die "Duplicate configuration for disk $FAI::disks[ $1-1 ]\n";

  # Initialise the entry in $FAI::configs
  $FAI::configs{$FAI::device} = {
    virtual    => 0,
    disklabel  => "msdos",
    bootable   => -1,
    fstabkey   => "device",
    partitions => {}
  };
}

################################################################################
#
# @brief Initialise the entry of a partition in @ref $FAI::configs
#
# @param $type The type of the partition. It must be either primary or logical.
#
################################################################################
sub init_part_config {

  # the type of the partition to be created
  my ($type) = @_;

  # type must either be primary or logical, nothing else may be accepted by the
  # parser
  ($type eq "primary" || $type eq "logical") or 
    &FAI::internal_error("invalid type $type");

  # check that a physical device is being configured; logical partitions are
  # only supported on msdos disk labels.
  ($FAI::device =~ /^PHY_/ && ($type ne "logical"
      || $FAI::configs{$FAI::device}{disklabel} eq "msdos")) or 
    die "Syntax error: invalid partition type";

  # the index of the new partition
  my $part_number = 0;

  # create a primary partition
  if ($type eq "primary") {

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
  } else {

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
        or die "Too many primary partitions while creating extended\n";

      # initialize the entry
      (\%FAI::configs)->{$FAI::device}->{partitions}->{$extended} = {
        size => {}
      };

      my $part_size =
        (\%FAI::configs)->{$FAI::device}->{partitions}->{$extended}->{size};

      # mark the entry as an extended partition
      $part_size->{extended} = 1;

      # add the preserve = 0 flag, if it doesn't exist already
      defined ($part_size->{preserve})
        or $part_size->{preserve} = 0;

      # add the resize = 0 flag, if it doesn't exist already
      defined ($part_size->{resize}) or $part_size->{resize} = 0;
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

  # as we can't compute the index from the reference, we need to store the
  # $part_number explicitly
  $FAI::partition_pointer->{number} = $part_number;

  # the partition is not an extended one
  $FAI::partition_pointer->{size}->{extended} = 0;

  # add the preserve = 0 flag, if it doesn't exist already
  defined ($FAI::partition_pointer->{size}->{preserve})
    or $FAI::partition_pointer->{size}->{preserve} = 0;

  # add the resize = 0 flag, if it doesn't exist already
  defined ($FAI::partition_pointer->{size}->{resize})
    or $FAI::partition_pointer->{size}->{resize} = 0;
}

################################################################################
#
# @brief This function converts different sizes to Mbyte
#
# @param $val is the number with its unit
#
################################################################################
sub convert_unit
{
  my ($val) = @_;
  ($val =~ /^(\d+(\.\d+)?)([kMGTP%]?)(B)?\s*$/) or
    &FAI::internal_error("convert_unit $val");
  $val = $1 * (1 / 1024) * (1 / 1024) if ($3 eq "" && defined ($4) && $4 eq "B");
  $val = $1 * (1 / 1024) if ($3 eq "k");
  $val = $1 if ($3 eq "M");
  $val = $1 * 1024 if ($3 eq "G");
  $val = $1 * (1024 * 1024) if ($3 eq "T");
  $val = $1 * (1024 * 1024 * 1024) if ($3 eq "P");
  # % is returned as is
  return $val;
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
        | <error>

    line: <skip: qr/[ \t]*/> "\\n"
        | <skip: qr/[ \t]*/> comment "\\n"
        | <skip: qr/[ \t]*/> config "\\n"

    comment: /^\s*#.*/

    config: 'disk_config' disk_config_arg
        | volume

    disk_config_arg: 'raid'
        {
          # check, whether raid tools are available
          &FAI::in_path("mdadm") or die "mdadm not found in PATH\n";
          $FAI::device = "RAID";
          $FAI::configs{$FAI::device}{fstabkey} = "device";
        }
        raid_option(s?)
        | /^lvm/
        {

          # check, whether lvm tools are available
          &FAI::in_path("lvcreate") or die "LVM tools not found in PATH\n";
          # initialise $FAI::device to inform the following lines about the LVM
          # being configured
          $FAI::device = "VG_";
          $FAI::configs{"VG_--ANY--"}{fstabkey} = "device";
        }
        lvm_option(s?)
        | 'end'
        {
          # exit config mode
          $FAI::device = "";
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

    raid_option: /^preserve_always:(\d+(,\d+)*)/
        {
          # set the preserve flag for all ids in all cases
          $FAI::configs{RAID}{volumes}{$_}{preserve} = 1 foreach (split (",", $1));
        }
        | /^preserve_reinstall:(\d+(,\d+)*)/
        {
          # set the preserve flag for all ids if $FAI::reinstall is set
          if ($FAI::reinstall) {
            $FAI::configs{RAID}{volumes}{$_}{preserve} = 1 foreach (split(",", $1));
          }
        }
        | /^fstabkey:(device|label|uuid)/
        {
          # the information preferred for fstab device identifieres
          $FAI::configs{$FAI::device}{fstabkey} = $1;
        }

    lvm_option: m{^preserve_always:([^/,\s\-]+-[^/,\s\-]+(,[^/,\s\-]+-[^/,\s\-]+)*)}
        {
          # set the preserve flag for all ids in all cases
          foreach (split (",", $1)) {
            (m{^([^/,\s\-]+)-([^/,\s\-]+)\s+}) or 
              die &FAI::internal_error("VG re-parse failed");
            $FAI::configs{"VG_$1"}{volumes}{$2}{size}{preserve} = 1 
          }
        }
        | m{^preserve_reinstall:([^/,\s\-]+-[^/,\s\-]+(,[^/,\s\-]+-[^/,\s\-]+)*)}
        {
          # set the preserve flag for all ids if $FAI::reinstall is set
          if ($FAI::reinstall) {
            foreach (split (",", $1)) {
              (m{^([^/,\s\-]+)-([^/,\s\-]+)\s+}) or 
                die &FAI::internal_error("VG re-parse failed");
              $FAI::configs{"VG_$1"}{volumes}{$2}{size}{preserve} = 1 
            }
          }
        }
        | m{^resize:([^/,\s\-]+-[^/,\s\-]+(,[^/,\s\-]+-[^/,\s\-]+)*)}
        {
          # set the resize flag for all ids
          foreach (split (",", $1)) {
            (m{^([^/,\s\-]+)-([^/,\s\-]+)\s+}) or 
              die &FAI::internal_error("VG re-parse failed");
            $FAI::configs{"VG_$1"}{volumes}{$2}{size}{resize} = 1 
          }
        }
        | /^fstabkey:(device|label|uuid)/
        {
          # the information preferred for fstab device identifieres
          $FAI::configs{"VG_--ANY--"}{fstabkey} = $1;
        }

    option: /^preserve_always:(\d+(,\d+)*)/
        {
          # set the preserve flag for all ids in all cases
          $FAI::configs{$FAI::device}{partitions}{$_}{size}{preserve} = 1 foreach (split (",", $1));
        }
        | /^preserve_reinstall:(\d+(,\d+)*)/
        {
          # set the preserve flag for all ids if $FAI::reinstall is set
          if ($FAI::reinstall) {
            $FAI::configs{$FAI::device}{partitions}{$_}{size}{preserve} = 1 foreach (split(",", $1));
          }
        }
        | /^resize:(\d+(,\d+)*)/
        {
          # set the resize flag for all ids
          $FAI::configs{$FAI::device}{partitions}{$_}{size}{resize} = 1 foreach (split(",", $1));
        }
        | /^disklabel:(msdos|gpt)/
        {
          # set the disk label - actually not only the above, but all types 
          # supported by parted could be allowed, but others are not implemented
          # yet
          $FAI::configs{$FAI::device}{disklabel} = $1;
        }
        | /^bootable:(\d+)/
        {
          # specify a partition that should get the bootable flag set
          $FAI::configs{$FAI::device}{bootable} = $1;
          ($FAI::device =~ /^PHY_(.+)$/) or
            &FAI::internal_error("unexpected device name");
          $FAI::disk_var{BOOT_DEVICE} .= " $1"; 
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

    volume: /^vg\s+/ name devices
        | /^raid([0156])\s+/
        {
          # make sure that this is a RAID configuration
          ($FAI::device eq "RAID") or die "RAID entry invalid in this context\n";
          # initialise RAID entry, if it doesn't exist already
          defined ($FAI::configs{RAID}) or $FAI::configs{RAID}{volumes} = {};
          # compute the next available index - the size of the entry
          my $vol_id = scalar (keys %{ $FAI::configs{RAID}{volumes} });
          # set the RAID type of this volume
          $FAI::configs{RAID}{volumes}{$vol_id}{mode} = $1;
          # initialise the hash of devices
          $FAI::configs{RAID}{volumes}{$vol_id}{devices} = {};
          # set the reference to the current volume
          # the reference is used by all further processing of this config line
          $FAI::partition_pointer = (\%FAI::configs)->{RAID}->{volumes}->{$vol_id};
        }
        mountpoint devices filesystem mount_options fs_options
        | type mountpoint size filesystem mount_options fs_options

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
        | m{^([^/,\s\-]+)-([^/,\s\-]+)\s+}
        {
          # set $FAI::device to VG_$1
          $FAI::device = "VG_$1";
          # make sure, the volume group $1 has been defined before
          defined ($FAI::configs{$FAI::device}) or 
            die "Volume group $1 has not been declared yet.\n";
          # make sure, $2 has not been defined already
          defined ($FAI::configs{$FAI::device}{volumes}{$2}{size}{range}) and 
            die "Logical volume $2 has been defined already.\n";
          # initialise the new hash
          defined($FAI::configs{$FAI::device}{volumes}{$2}) or
            $FAI::configs{$FAI::device}{volumes}{$2} = {};
          # initialise the preserve and resize flags
          defined($FAI::configs{$FAI::device}{volumes}{$2}{size}{preserve}) or
            $FAI::configs{$FAI::device}{volumes}{$2}{size}{preserve} = 0;
          defined($FAI::configs{$FAI::device}{volumes}{$2}{size}{resize}) or
            $FAI::configs{$FAI::device}{volumes}{$2}{size}{resize} = 0;
          # set the reference to the current volume
          # the reference is used by all further processing of this config line
          $FAI::partition_pointer = (\%FAI::configs)->{$FAI::device}->{volumes}->{$2};
        }

    mountpoint: '-'
        {
          # this partition should not be mounted
          $FAI::partition_pointer->{mountpoint} = "-";
          $FAI::partition_pointer->{encrypt} = 0;
        }
        | 'swap'
        {
          # this partition is swap space, not mounted
          $FAI::partition_pointer->{mountpoint} = "none";
          $FAI::partition_pointer->{encrypt} = 0;
        }
        | m{^/\S*}
        {
          # set the mount point, may include encryption-request
          if ($item[ 1 ] =~ m{^(/[^:]*):encrypt$}) {
            &FAI::in_path("cryptsetup") or die "cryptsetup not found in PATH\n";
            $FAI::partition_pointer->{mountpoint} = $1;
            $FAI::partition_pointer->{encrypt} = 1;
          } else {
            $FAI::partition_pointer->{mountpoint} = $item[ 1 ];
            $FAI::partition_pointer->{encrypt} = 0;
          }
        }

    name: m{^([^/,\s\-]+)}
        {
          # set the device name to VG_ and the name of the volume group
          $FAI::device = "VG_$1";
          # make sure, the volume group $1 not has been defined already
          defined ($FAI::configs{$FAI::device}) and
            die "Volume group $1 has been defined already.\n";
          # make sure this line is part of an LVM configuration
          ($FAI::device =~ /^VG_/) or
            die "vg is invalid in a non LVM-context.\n";
          # initialise the new hash
          $FAI::configs{$FAI::device}{volumes} = {};
          # initialise the list of physical devices
          $FAI::configs{$FAI::device}{devices} = ();
          # the rule must not return undef
          1;
        }

    size: /^(\d+[kMGTP%]?(-(\d+[kMGTP%]?)?)?)(:resize)?\s+/
        {
          # complete the size specification to be a range in all cases
          my $range = $1;
          # the size is fixed
          if (!defined ($2))
          {
            # make it a range of the form x-x
            $range = "$range-$1";
          }
          elsif (!defined ($3))
          {
            # range has no upper limit, assume the whole disk
            $range = "${range}100%";
          } 

          # convert the units, if necessary
          my ($min, $max) = split (/-/, $range);
          $min   = &FAI::convert_unit($min);
          $max   = &FAI::convert_unit($max);
          $range = "$min-$max";
          # enter the range into the hash
          $FAI::partition_pointer->{size}->{range} = $range;
          # set the resize flag, if required
          defined ($4) and $FAI::partition_pointer->{size}->{resize} = 1;
        }
        | /^(-\d+[kMGTP%]?)(:resize)?\s+/
        {
          # complete the range by assuming 0 as the lower limit 
          my $range = "0$1";
          # convert the units, if necessary
          my ($min, $max) = split (/-/, $range);
          $min   = &FAI::convert_unit($min);
          $max   = &FAI::convert_unit($max);
          $range = "$min-$max";
          # enter the range into the hash
          $FAI::partition_pointer->{size}->{range} = $range;
          # set the resize flag, if required
          defined( $2 ) and $FAI::partition_pointer->{size}->{resize} = 1;
        }
        | <error: invalid partition size near "$text">

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
            # make $dev a full path name; can't validate device name yet as it
            # might be created later on
            unless ($dev =~ m{^/}) {
              if ($dev =~ m/^disk(\d+)\.(\d+)/) {
                $dev = &FAI::make_device_name("/dev/" . $FAI::disks[ $1 - 1 ], $2);
              } else {
                $dev = "/dev/$dev";
              }
            }
            # options are only valid for RAID
            defined ($2) and ($FAI::device ne "RAID") and die "Option $2 invalid in a non-RAID context\n";
            if ($FAI::device eq "RAID") {
              # parse all options
              my $spare = 0;
              my $missing = 0;
              if (defined ($2)) {
                ($2 =~ /spare/) and $spare = 1;
                ($2 =~ /missing/) and $missing = 1;
              }
              # each device may only appear once
              defined ($FAI::partition_pointer->{devices}->{$dev}) and 
                die "$dev is already part of the RAID volume\n";
              # set the options
              $FAI::partition_pointer->{devices}->{$dev}->{options} = {
                "spare" => $spare,
                "missing" => $missing
              };
            } else {
              # create an empty hash for each device
              $FAI::configs{$FAI::device}{devices}{$dev} = {};
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
          &FAI::in_path("mkfs.$item[1]") or 
            die "unknown/invalid filesystem type $item[1] (mkfs.$item[1] not found in PATH)\n";
          $FAI::partition_pointer->{filesystem} = $item[ 1 ];
        }

    fs_options: /[^;\n]*/
        {
          $FAI::partition_pointer->{fs_options} = $item[ 1 ];
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

1;

