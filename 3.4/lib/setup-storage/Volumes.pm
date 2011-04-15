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
# @file volumes.pm
#
# @brief Parse the current partition table and LVM/RAID configurations
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
# @brief Collect all physical devices reference in the desired configuration
#
################################################################################
sub find_all_phys_devs {

  my @phys_devs = ();

  # loop through all configs
  foreach my $config (keys %FAI::configs) {

    if ($config =~ /^PHY_(.+)$/) {
      push @phys_devs, $1;
    } elsif ($config =~ /^VG_(.+)$/) {
      next if ($1 eq "--ANY--");
      foreach my $d (keys %{ $FAI::configs{$config}{devices} }) {
        my ($i_p_d, $disk, $part_no) = &FAI::phys_dev($d);
        push @phys_devs, $disk if (1 == $i_p_d);
      }
    } elsif ($config eq "RAID") {
      foreach my $r (keys %{ $FAI::configs{$config}{volumes} }) {
        foreach my $d (keys %{ $FAI::configs{$config}{volumes}{$r}{devices} }) {
          my ($i_p_d, $disk, $part_no) = &FAI::phys_dev($d);
          push @phys_devs, $disk if (1 == $i_p_d);
        }
      }
    } elsif ($config eq "CRYPT") {
      # devices must be one of the above already
      next;
    } elsif ($config eq "TMPFS") {
      # no devices
      next;
    } else {
      &FAI::internal_error("Unexpected key $config");
    }
  }

  return \@phys_devs;
}

################################################################################
#
# @brief Collect the current partition information from all disks listed both
# in $FAI::disks and $FAI::configs{PHY_<disk>}
#
################################################################################
sub get_current_disks {

  my %referenced_devs = ();
  @referenced_devs{ @{ &FAI::find_all_phys_devs() } } = ();

  # obtain the current state of all disks
  foreach my $disk (@FAI::disks) {
    # create full paths
    ($disk =~ m{^/}) or $disk = "/dev/$disk";

    exists ($referenced_devs{$disk}) or next;

    # make sure, $disk is a proper block device
    (-b $disk) or die "$disk is not a block special device!\n";

    # init device tree
    $FAI::current_dev_children{$disk} = ();

    # the list to hold the output of parted commands as parsed below
    my @parted_print = ();

    # try to obtain the partition table for $disk
    # it might fail with parted_2 in case the disk has no partition table
    my $error =
        &FAI::execute_ro_command("parted -s $disk unit TiB print", \@parted_print, 0);

    # possible problems
    if (!defined($FAI::configs{"PHY_$disk"}) && $error ne "") {
      warn "Could not determine size and contents of $disk, skipping\n";
      next;
    } elsif (defined($FAI::configs{"PHY_$disk"}) &&
      $FAI::configs{"PHY_$disk"}{preserveparts} == 1 && $error ne "") {
      die "Failed to determine size and contents of $disk, but partitions should have been preserved\n";
    }

    # parted_2 happens when the disk has no disk label, parted_4 means unaligned
    # partitions
    if ($error eq "parted_2" || $error eq "parted_2_new" ||
      $error eq "parted_4" || $error eq "parted_4_new") {

      $FAI::no_dry_run or die 
        "Can't run on test-only mode on this system because there is no disklabel on $disk\n";

      # write the disk label as configured
      my $label = $FAI::configs{"PHY_$disk"}{disklabel};
      $label = "gpt" if ($label eq "gpt-bios");
      $error = &FAI::execute_command("parted -s $disk mklabel $label");
      ($error eq "") or die "Failed to write disk label\n";
      # retry partition-table print
      $error =
        &FAI::execute_ro_command("parted -s $disk unit TiB print", \@parted_print, 0);
    }

    ($error eq "") or die "Failed to read the partition table from $disk\n";

    # disk is usable
    &FAI::push_command( "true", "", "exist_$disk" );

    # initialise the hash
    $FAI::current_config{$disk}{partitions} = {};


# the following code parses the output of parted print, using various units
# (TiB, B, chs)
# the parser is capable of reading the output of parted version 1.7.1, which
# looks like
#
# $ /sbin/parted -s /dev/hda unit B print
# WARNING: You are not superuser.  Watch out for permissions.
#
# Disk /dev/hda: 80026361855B
# Sector size (logical/physical): 512B/512B
# Partition Table: mac
#
# Number  Start         End           Size          File system  Name     Flags
#  1      512B          32767B        32256B                     primary
#  5      32768B        1033215B      1000448B      hfs          primary  boot
#  3      134250496B    32212287487B  32078036992B  hfs+         primary
#  6      32212287488B  46212287487B  14000000000B  ext3         primary
#  2      46212287488B  47212287999B  1000000512B   linux-swap   primary  swap
#  4      47212288000B  80026361855B  32814073856B  ext3         primary
#
# Note that the output contains an additional column on msdos, indicating,
# whether the type of a partition is primary, logical or extended.
#
# $ parted -s /dev/hda unit B print
#
# Disk /dev/hda: 82348277759B
# Sector size (logical/physical): 512B/512B
# Partition Table: msdos
#
# Number  Start         End           Size          Type      File system  Flags
#  1      32256B        24675839B     24643584B     primary   ext3
#  2      24675840B     1077511679B   1052835840B   primary   linux-swap
#  3      1077511680B   13662190079B  12584678400B  primary   ext3         boot
#  4      13662190080B  82343278079B  68681088000B  extended
#  5      13662222336B  14715025919B  1052803584B   logical   ext3
#         14715058176B  30449986559B  15734928384B
#  7      30450018816B  32547432959B  2097414144B   logical   ext3
#  8      32547465216B  82343278079B  49795812864B  logical   ext3
#
# parted 2.2:
# $ parted -s /dev/sda unit TiB print
# Model: ATA VBOX HARDDISK (scsi)
# Disk /dev/sda: 0.06TiB
# Sector size (logical/physical): 512B/512B
# Partition Table: msdos
#
# Number  Start    End      Size     Type      File system     Flags
#  1      0.00TiB  0.00TiB  0.00TiB  primary   ext3            boot
#  2      0.00TiB  0.00TiB  0.00TiB  primary   linux-swap(v1)
#  3      0.00TiB  0.00TiB  0.00TiB  primary   ext3
#  4      0.00TiB  0.06TiB  0.06TiB  extended                  lba
#  5      0.00TiB  0.00TiB  0.00TiB  logical   ext3
#  6      0.00TiB  0.00TiB  0.00TiB  logical   ext3
#  7      0.00TiB  0.00TiB  0.00TiB  logical   ext3
#  8      0.00TiB  0.01TiB  0.00TiB  logical   ext3
#  9      0.01TiB  0.06TiB  0.05TiB  logical                   lvm

    # As shown above, some entries may be blank. Thus the exact column starts
    # and lengths must be parsed from the header line. This is stored in the
    # following hash
    my %cols = ();

    # Parse the output line by line
    foreach my $line (@parted_print) {

      # now we test line by line - some of them may be ignored
      next if ($line =~ /^Disk / || $line =~ /^Model: / || $line =~ /^\s*$/
        || $line =~ /^WARNING: You are not superuser/
        || $line =~ /^Warning: Not all of the space available to/);

      # determine the logical sector size
      if ($line =~ /^Sector size \(logical\/physical\): (\d+)B\/\d+B$/) {
        $FAI::current_config{$disk}{sector_size} = $1;
      }

      # read and store the current disk label
      elsif ($line =~ /^Partition Table: (.+)$/) {
        $FAI::current_config{$disk}{disklabel} = $1;
      }

      # the line containing the table headers
      elsif ($line =~ /^(Number\s+)(\S+\s+)+/) {
        my $col_start = 0;

        # check the length of each heading; note that they might contain spaces
        while ($line =~ /^(\S+( [a-z]\S+)?\s*)([A-Z].*)?$/) {
          my $heading = $1;

          # set the line to the remainder
          $line = "";
          $line = $3 if defined ($3);

          # the width of the column includes any whitespace
          my $col_width = length ($heading);
          $heading =~ s/(\S+)\s*$/$1/;

          # build the hash entry
          # this start counter starts at 0, which is useful below
          $cols{$heading} = {
            "start"  => $col_start,
            "length" => $col_width
          };
          $col_start += $col_width;
        }
      } else { # one of the partitions

        # we must have seen the header, otherwise probably the format has
        # changed
        defined ($cols{"File system"}{"start"})
          or &FAI::internal_error("Table header not yet seen while reading $line");

        # the info for the partition number
        my $num_cols_before = $cols{"Number"}{"start"};
        my $num_col_width   = $cols{"Number"}{"length"};

        # the info for the file system column
        my $fs_cols_before = $cols{"File system"}{"start"};
        my $fs_col_width   = $cols{"File system"}{"length"};

        # get the partition number, if any
        $line =~ /^.{$num_cols_before}(.{$num_col_width})/;
        my $id = $1;
        $id =~ s/\s*//g;

        # if there is no partition number, then it must be free space, so no
        # file system either
        next if ($id eq "");

        # extract the file system information
        my $fs = "";
        if (length ($line) > $fs_cols_before) {
          if (length ($line) >= ($fs_cols_before + $fs_col_width)) {
            $line =~ /^.{$fs_cols_before}(.{$fs_col_width})/;
            $fs = $1;
          } else {
            $line =~ /^.{$fs_cols_before}(.+)$/;
            $fs = $1;
          }
        }

        # remove any trailing space
        $fs =~ s/\s*$//g;

        # store the information in the hash
        $FAI::current_config{$disk}{partitions}{$id}{filesystem} = $fs;
      }
    }

    # reset the output list
    @parted_print = ();

    # obtain the partition table using bytes as units
    $error =
      &FAI::execute_ro_command("parted -s $disk unit B print free", \@parted_print, 0);

    # Parse the output of the byte-wise partition table
    foreach my $line (@parted_print) {

      # the disk size line (Disk /dev/hda: 82348277759B)
      if ($line =~ /Disk \Q$disk\E: (\d+)B$/) {
        $FAI::current_config{$disk}{begin_byte} = 0;
        $FAI::current_config{$disk}{end_byte}   = $1 - 1;
        $FAI::current_config{$disk}{size}       = $1;

        # nothing else to be done
        next;
      }

      # One of the partition lines, see above example
      next unless ($line =~
        /^\s*(\d+)\s+(\d+)B\s+(\d+)B\s+(\d+)B(\s+(primary|logical|extended))?/i);

      # mark the bounds of existing partitions
      $FAI::current_config{$disk}{partitions}{$1}{begin_byte} = $2;
      $FAI::current_config{$disk}{partitions}{$1}{end_byte}   = $3;
      $FAI::current_config{$disk}{partitions}{$1}{count_byte} = $4;

      # is_extended defaults to false/0
      $FAI::current_config{$disk}{partitions}{$1}{is_extended} = 0;

      # but may be true/1 on msdos disk labels
      ( ( $FAI::current_config{$disk}{disklabel} eq "msdos" )
          && ( $6 eq "extended" ) )
        and $FAI::current_config{$disk}{partitions}{$1}{is_extended} = 1;

      # add entry in device tree
      push @{ $FAI::current_dev_children{$disk} }, &FAI::make_device_name($disk, $1);
    }

    # reset the output list
    @parted_print = ();

    # obtain the partition table using bytes as units
    $error =
      &FAI::execute_ro_command(
      "parted -s $disk unit chs print free", \@parted_print, 0);

    # Parse the output of the CHS partition table
    foreach my $line (@parted_print) {

   # find the BIOS geometry that looks like this:
   # BIOS cylinder,head,sector geometry: 10011,255,63.  Each cylinder is 8225kB.
      if ($line =~
        /^BIOS cylinder,head,sector geometry:\s*(\d+),(\d+),(\d+)\.\s*Each cylinder is \d+kB\.$/) {
        $FAI::current_config{$disk}{bios_cylinders}         = $1;
        $FAI::current_config{$disk}{bios_heads}             = $2;
        $FAI::current_config{$disk}{bios_sectors_per_track} = $3;
      }
    }

    # make sure we have determined all the necessary information
    ($FAI::current_config{$disk}{begin_byte} == 0)
      or die "Invalid start byte\n";
    ($FAI::current_config{$disk}{end_byte} > 0) or die "Invalid end byte\n";
    defined ($FAI::current_config{$disk}{size})
      or die "Failed to determine disk size\n";
    defined ($FAI::current_config{$disk}{sector_size})
      or die "Failed to determine sector size\n";
    defined ($FAI::current_config{$disk}{bios_sectors_per_track})
      or die "Failed to determine the number of sectors per track\n";

  }
}

################################################################################
#
# @brief Collect the current LVM configuration
#
################################################################################
sub get_current_lvm {

  use Linux::LVM;
  use Cwd qw(abs_path);

  # get the existing volume groups
  foreach my $vg (get_volume_group_list()) {
    # initialise the hash entry
    $FAI::current_lvm_config{$vg}{physical_volumes} = ();

    # init device tree
    $FAI::current_dev_children{"VG_$vg"} = ();

    # store the vg size in MB
    my %vg_info = get_volume_group_information($vg);
    if (%vg_info) {
      $FAI::current_lvm_config{$vg}{size} = &FAI::convert_unit(
        $vg_info{vg_size} . $vg_info{vg_size_unit});
    } else {
      $FAI::current_lvm_config{$vg}{size} = "0";
    }

    # store the logical volumes and their sizes
    my %lv_info = get_logical_volume_information($vg);
    foreach my $lv_name (sort keys %lv_info) {
      my $short_name = $lv_name;
      $short_name =~ s{/dev/\Q$vg\E/}{};
      $FAI::current_lvm_config{$vg}{volumes}{$short_name}{size} =
        &FAI::convert_unit($lv_info{$lv_name}->{lv_size} .
          $lv_info{$lv_name}->{lv_size_unit});
      # add entry in device tree
      push @{ $FAI::current_dev_children{"VG_$vg"} }, $lv_name;
    }

    # store the physical volumes
    my %pv_info = get_physical_volume_information($vg);
    foreach my $pv_name (sort keys %pv_info) {
      push @{ $FAI::current_lvm_config{$vg}{physical_volumes} },
        abs_path($pv_name);

      # add entry in device tree
      push @{ $FAI::current_dev_children{abs_path($pv_name)} }, "VG_$vg";
    }
  }

}

################################################################################
#
# @brief Collect the current RAID device information from all partitions
# currently active in the system
#
################################################################################
sub get_current_raid {

  use Cwd qw(abs_path);

  # the list to hold the output of mdadm commands as parsed below
  my @mdadm_print = ();

  # try to obtain the list of existing RAID arrays
  my $error =
    &FAI::execute_ro_command("mdadm --examine --scan --verbose -c partitions",
    \@mdadm_print, 0);

# the expected output is as follows
# $ mdadm --examine --scan --verbose -c partitions
# ARRAY /dev/md0 level=linear num-devices=2 UUID=7e11efd6:93e977fd:b110d941:ce79a4f6
#    devices=/dev/hda1,/dev/hda2
# ARRAY /dev/md1 level=raid0 num-devices=2 UUID=50d7a6ec:4207f0db:b110d941:ce79a4f6
#    devices=/dev/md0,/dev/hda3
# or (newer version of mdadm?)
# kueppers[~]# mdadm --examine --scan --verbose -c partitions
# ARRAY /dev/md0 level=raid0 num-devices=3 metadata=00.90
# UUID=a4553444:0baf31ae:135399f0:a895f15f
#    devices=/dev/sdf2,/dev/sdd2,/dev/sde2
# ARRAY /dev/md1 level=raid0 num-devices=3 metadata=00.90
# UUID=77a22e9f:83fd1276:135399f0:a895f15f
#    devices=/dev/sde3,/dev/sdf3,/dev/sdd3
# and another variant
# ARRAY /dev/md1 level=raid0 metadata=1.2 num-devices=3
# UUID=77a22e9f:83fd1276:135399f0:a895f15f
#    devices=/dev/sde3,/dev/sdf3,/dev/sdd3

  # create a temporary mdadm-from-examine.conf
  open(MDADM_EX, ">$ENV{LOGDIR}/mdadm-from-examine.conf");

  # the id of the RAID
  my $id;

  # parse the output line by line
  foreach my $line (@mdadm_print) {
    print MDADM_EX "$line";
    if ($line =~ /^ARRAY \/dev\/md[\/]?(\d+)\s+/) {
      $id = $1;

      foreach (split (" ", $line)) {
        $FAI::current_raid_config{$id}{mode} = $1 if ($_ =~ /^level=(\S+)/);
      }
    } elsif ($line =~ /^\s*devices=(\S+)$/) {
      defined($id) or
        &FAI::internal_error("mdadm ARRAY line not yet seen -- unexpected mdadm output:\n"
        . join("", @mdadm_print));
      foreach my $d (split (",", $1)) {
        push @{ $FAI::current_raid_config{$id}{devices} }, abs_path($d);

        # add entry in device tree
        push @{ $FAI::current_dev_children{abs_path($d)} }, "/dev/md$id";
      }

      undef($id);
    }
  }

  close(MDADM_EX);
}


################################################################################
#
# @brief Set the appropriate preserve flag for $device_name
#
# @param device_name Full device path
#
################################################################################
sub mark_preserve {
  my ($device_name, $missing) = @_;
  my ($i_p_d, $disk, $part_no) = &FAI::phys_dev($device_name);

  if (1 == $i_p_d) {
    if (defined($FAI::configs{"PHY_$disk"}) &&
        defined($FAI::configs{"PHY_$disk"}{partitions}{$part_no})) {
      defined ($FAI::current_config{$disk}{partitions}{$part_no}) or die
        "Can't preserve $device_name because it does not exist\n";
      $FAI::configs{"PHY_$disk"}{partitions}{$part_no}{size}{preserve} = 1;
      $FAI::configs{"PHY_$disk"}{preserveparts} = 1;
    } elsif (0 == $missing) {
      defined ($FAI::current_config{$disk}{partitions}{$part_no}) or die
        "Can't preserve $device_name because it does not exist\n";
    }
  } elsif ($device_name =~ m{^/dev/md[\/]?(\d+)$}) {
    my $vol = $1;
    if (defined($FAI::configs{RAID}) &&
        defined($FAI::configs{RAID}{volumes}{$vol})) {
      defined ($FAI::current_raid_config{$vol}) or die
        "Can't preserve $device_name because it does not exist\n";
      if ($FAI::configs{RAID}{volumes}{$vol}{preserve} != 1) {
        $FAI::configs{RAID}{volumes}{$vol}{preserve} = 1;
        &FAI::mark_preserve($_, $FAI::configs{RAID}{volumes}{$vol}{devices}{$_}{missing})
          foreach (keys %{ $FAI::configs{RAID}{volumes}{$vol}{devices} });
      }
    } elsif (0 == $missing) {
      defined ($FAI::current_raid_config{$vol}) or die
        "Can't preserve $device_name because it does not exist\n";
    }
  } elsif ($device_name =~ m{^/dev/([^/\s]+)/([^/\s]+)$}) {
    my $vg = $1;
    my $lv = $2;
    if (defined($FAI::configs{"VG_$vg"}) &&
        defined($FAI::configs{"VG_$vg"}{volumes}{$lv})) {
      defined ($FAI::current_lvm_config{$vg}{volumes}{$lv}) or die
        "Can't preserve $device_name because it does not exist\n";
      if ($FAI::configs{"VG_$vg"}{volumes}{$lv}{size}{preserve} != 1) {
        $FAI::configs{"VG_$vg"}{volumes}{$lv}{size}{preserve} = 1;
        &FAI::mark_preserve($_, $missing) foreach (keys %{ $FAI::configs{"VG_$vg"}{devices} });
      }
    } elsif (0 == $missing) {
      defined ($FAI::current_lvm_config{$vg}{volumes}{$lv}) or die
        "Can't preserve $device_name because it does not exist\n";
    }
  } else {
    warn "Don't know how to mark $device_name for preserve\n";
  }
}


################################################################################
#
# @brief Mark devices as preserve, in case an LVM volume or RAID device shall be
# preserved and check that only defined devices are marked preserve
#
################################################################################
sub propagate_and_check_preserve {

  # loop through all configs
  foreach my $config (keys %FAI::configs) {

    if ($config =~ /^PHY_(.+)$/) {
      foreach my $part_id (&numsort(keys %{ $FAI::configs{$config}{partitions} })) {
        my $part = (\%FAI::configs)->{$config}->{partitions}->{$part_id};
        $part->{size}->{preserve} =
          ((defined($FAI::current_config{$1}) &&
              defined($FAI::current_config{$1}{partitions}{$part_id})) ? 1 : 0)
          if (2 == $part->{size}->{preserve});
        next unless ($part->{size}->{preserve} || $part->{size}->{resize});
        ($part->{size}->{extended}) and die
          "Preserving extended partitions is not supported; mark all logical partitions instead\n";
        if (0 == $part_id) {
          defined ($FAI::current_config{$1}) or die
            "Can't preserve $1 because it does not exist\n";
        } else {
          defined ($FAI::current_config{$1}) or die
            "Can't preserve partition on $1 because $1 does not exist\n";
          defined ($FAI::current_config{$1}{partitions}{$part_id}) or die
            "Can't preserve ". &FAI::make_device_name($1, $part->{number})
              . " because it does not exist\n";
          defined ($part->{size}->{range}) or die
            "Can't preserve ". &FAI::make_device_name($1, $part->{number})
              . " because it is not defined in the current config\n";
        }
      }
    } elsif ($config =~ /^VG_(.+)$/) {
      next if ($1 eq "--ANY--");
      # check for logical volumes that need to be preserved and preserve the
      # underlying devices recursively
      foreach my $l (keys %{ $FAI::configs{$config}{volumes} }) {
        $FAI::configs{$config}{volumes}{$l}{size}{preserve} =
          ((defined($FAI::current_lvm_config{$1}) &&
              defined($FAI::current_lvm_config{$1}{volumes}{$l})) ? 1 : 0)
          if (2 == $FAI::configs{$config}{volumes}{$l}{size}{preserve});
        next unless ($FAI::configs{$config}{volumes}{$l}{size}{preserve} == 1 ||
          $FAI::configs{$config}{volumes}{$l}{size}{resize} == 1);
        defined ($FAI::current_lvm_config{$1}{volumes}{$l}) or die
          "Can't preserve /dev/$1/$l because it does not exist\n";
        defined ($FAI::configs{$config}{volumes}{$l}{size}{range}) or die
          "Can't preserve /dev/$1/$l because it is not defined in the current config\n";
        &FAI::mark_preserve($_, 0) foreach (keys %{ $FAI::configs{$config}{devices} });
      }
    } elsif ($config eq "RAID") {
      # check for volumes that need to be preserved and preserve the underlying
      # devices recursively
      foreach my $r (keys %{ $FAI::configs{$config}{volumes} }) {
        $FAI::configs{$config}{volumes}{$r}{preserve} =
          (defined($FAI::current_raid_config{$r}) ? 1 : 0)
          if (2 == $FAI::configs{$config}{volumes}{$r}{preserve});
        next unless ($FAI::configs{$config}{volumes}{$r}{preserve} == 1);
        defined ($FAI::current_raid_config{$r}) or die
          "Can't preserve /dev/md$r because it does not exist\n";
        defined ($FAI::configs{$config}{volumes}{$r}{devices}) or die
          "Can't preserve /dev/md$r because it is not defined in the current config\n";
        &FAI::mark_preserve($_, $FAI::configs{$config}{volumes}{$r}{devices}{$_}{missing})
          foreach (keys %{ $FAI::configs{$config}{volumes}{$r}{devices} });
      }
    } elsif ($config eq "CRYPT") {
      # We don't do preserve for encrypted partitions
      next;
    } elsif ($config eq "TMPFS") {
      # We don't do preserve for tmpfs
      next;
    } else {
      &FAI::internal_error("Unexpected key $config");
    }
  }
}


1;

