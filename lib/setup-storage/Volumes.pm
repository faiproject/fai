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
# @author Christian Kern, Michael Tautschnig, Thomas Lange
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
    } elsif ($config eq "BTRFS") {
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
    } elsif ($config eq "NFS") {
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

  # following creates an array of full paths to disks
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
      &FAI::execute_ro_command("parted -sm $disk unit B print", \@parted_print, 0);

      if ($error eq 'parted_3_2') {
          # Ignore this
          print "Ignoring error $error\n";
          $error = '';
      }

    # possible problems
    if (!defined($FAI::configs{"PHY_$disk"}) && $error ne "") {
      warn "Could not determine size and contents of $disk, skipping\n";
      next;
    } elsif (defined($FAI::configs{"PHY_$disk"}) &&
	     $FAI::configs{"PHY_$disk"}{preserveparts} == 1 && $error ne "") {
      die "Failed to determine size and contents of $disk, but partitions should have been preserved\n";
    }

    # write a fresh disklabel if no useable data was found and dry_run is not
    # set
    if ($error ne "" && $FAI::no_dry_run) {
      # write the disk label as configured
      my $label = $FAI::configs{"PHY_$disk"}{disklabel};
      $label = "gpt" if ($label eq "gpt-bios");
      $error = &FAI::execute_command("parted -s $disk mklabel $label");
      ($error eq "") or die "Failed to write disk label\n";
      # retry partition-table print
      $error =
        &FAI::execute_ro_command("parted -sm $disk unit B print", \@parted_print, 0);
    }

    ($error ne "" && $FAI::no_dry_run) &&
      die "Failed to read the partition table from $disk\n";

    # disk is usable
    &FAI::push_command( "true", "", "exist_$disk" );

    # initialise the hash
    $FAI::current_config{$disk}{partitions} = {};

    shift @parted_print; # ignore first line
    my ($devpath,$end,$transport,$sector_size,$phy_sec,$disklabel) =
      split(':',shift @parted_print);

    $end =~ s/B$//;
    $FAI::current_config{$disk}{begin_byte} = 0;
    $FAI::current_config{$disk}{end_byte}   = $end - 1;
    $FAI::current_config{$disk}{size}       = $end;

    # determine the logical sector size
    $FAI::current_config{$disk}{sector_size} = $sector_size;
    # read and store the current disk label
    $FAI::current_config{$disk}{disklabel} = $disklabel;

    # Parse the output of the byte-wise partition table
    foreach my $line (@parted_print) {
      chomp $line;
      my ($n,$begin_byte,$end_byte,$count_byte,$fstype,$ptlabel,$flags) = split(':', $line);
      $begin_byte =~ s/B$//;
      $end_byte   =~ s/B$//;
      $count_byte =~ s/B$//;
      $flags      =~ s/;$//;

      # mark the bounds of existing partitions
      $FAI::current_config{$disk}{partitions}{$n}{begin_byte} = $begin_byte;
      $FAI::current_config{$disk}{partitions}{$n}{end_byte}   = $end_byte;
      $FAI::current_config{$disk}{partitions}{$n}{count_byte} = $count_byte;
      $FAI::current_config{$disk}{partitions}{$n}{ptlabel}    = $ptlabel;
      $FAI::current_config{$disk}{partitions}{$n}{filesystem} = $fstype;
      $FAI::current_config{$disk}{partitions}{$n}{flags}      = $flags;

      # is_extended defaults to false/0
      $FAI::current_config{$disk}{partitions}{$n}{is_extended} = 0;

      # add entry in device tree
      push @{ $FAI::current_dev_children{$disk} }, &FAI::make_device_name($disk, $n);
    }

    @parted_print = ();
    # obtain the partition table using bytes as units
    $error =
      &FAI::execute_ro_command("parted -s $disk unit chs print free", \@parted_print, 0);

    # Parse the output of the CHS partition table
    foreach my $line (@parted_print) {

      # find the BIOS geometry that looks like this:
      # BIOS cylinder,head,sector geometry: 10011,255,63.  Each cylinder is 8225kB.
      if ($line =~
	  /^BIOS cylinder,head,sector geometry:\s*(\d+),(\d+),(\d+)\.\s*Each cylinder is \d+(\.\d+)?kB\.$/) {
        $FAI::current_config{$disk}{bios_cylinders}         = $1;
        $FAI::current_config{$disk}{bios_heads}             = $2;
        $FAI::current_config{$disk}{bios_sectors_per_track} = $3;
      }

      # check for extended partition on msdos disk labels
      if ( $FAI::current_config{$disk}{disklabel} eq "msdos" &&
           $line =~ /\s*(\d+)\s+[\d,]+\s+[\d,]+\s+extended/) {
	$FAI::current_config{$disk}{partitions}{$1}{is_extended} = 1;
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
# use enviroment variable SS_IGNORE_VG to ignore a list of volume groups
################################################################################
sub get_current_lvm {

  use Linux::LVM;
  Linux::LVM->units('H');
  use Cwd qw(abs_path);

  # create hash of vgs to be ignored
  my %vgignore = ();
  if (defined $ENV{"SS_IGNORE_VG"}) {
    %vgignore = map { $_ , 1} split ' ',$ENV{"SS_IGNORE_VG"};
  }

  # get the existing volume groups
  foreach my $vg (get_volume_group_list()) {
    if ($vgignore{$vg}) {
      warn "Ignoring volume group: $vg\n";
      next;
    }

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
  open(MDADM_EX, ">$FAI::DATADIR/mdadm-from-examine.conf");

  # the id of the RAID
  my $id;

  # container
  my $container;
  my $container_devices;

  # parse the output line by line
  foreach my $line (@mdadm_print) {
    print MDADM_EX "$line";
    if ($line =~ /^ARRAY \/dev\/md[\/]?([\w-]+)\s+/) {
      $id = $1;

      foreach (split (" ", $line)) {
        $FAI::current_raid_config{$id}{mode} = $1 if ($_ =~ /^level=(\S+)/);
      }

    # WORK-AROUND
    } elsif ($line =~ /^ARRAY metadata=([a-z]+) UUID=([a-z0-9:]+)/) {
      $container = $2;

    # WORK-AROUND
    } elsif ($line =~ /^ARRAY \/dev\/md(\/\w+\d+) container=([a-z0-9:]+) member=([0-9]+) UUID=([a-z0-9:]+)/) {
      if ($1 =~ /\w+\d+/) {
        $id = $1 . "_0";
      } else {
        $id = $1 . "0";
      }

      if (defined($container) and defined($container_devices) and "$2" eq "$container") {
        $FAI::current_raid_config{$id}{mode} = "raid1";
        foreach my $d (split (",", $container_devices)) {
          push @{ $FAI::current_raid_config{$id}{devices} }, abs_path($d);

          # add entry in device tree
          push @{ $FAI::current_dev_children{abs_path($d)} }, "/dev/md$id";
        }
      }
      undef($id);
      undef($container);
      undef($container_devices);

    } elsif ($line =~ /^\s*devices=(\S+)$/) {
      if (defined($id)) {
        foreach my $d (split (",", $1)) {
          push @{ $FAI::current_raid_config{$id}{devices} }, abs_path($d);

          # add entry in device tree
          push @{ $FAI::current_dev_children{abs_path($d)} }, "/dev/md$id";
        }

      # WORK-AROUND
      } elsif (defined($container)) {
        $container_devices = $1;

      } else {
        &FAI::internal_error("mdadm ARRAY line not yet seen -- unexpected mdadm output:\n"
        . join("", @mdadm_print));
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
      (defined ($FAI::current_config{$disk}) &&
        defined ($FAI::current_config{$disk}{partitions}{$part_no})) or die
        "Can't preserve $device_name because it does not exist\n";
      $FAI::configs{"PHY_$disk"}{partitions}{$part_no}{size}{preserve} = 1;
      $FAI::configs{"PHY_$disk"}{preserveparts} = 1;
    } elsif (0 == $missing) {
      (defined ($FAI::current_config{$disk}) &&
        defined ($FAI::current_config{$disk}{partitions}{$part_no})) or die
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
      defined ($FAI::current_config{$1}) or
        die "Device $1 was not specified in \$disklist\n";
      defined ($FAI::current_config{$1}{partitions}) or
        &FAI::internal_error("Missing key \"partitions\"");

      foreach my $part_id (&numsort(keys %{ $FAI::configs{$config}{partitions} })) {
        my $part = (\%FAI::configs)->{$config}->{partitions}->{$part_id};
        $part->{size}->{preserve} =
          (defined($FAI::current_config{$1}{partitions}{$part_id}) ? 1 : 0)
          if (2 == $part->{size}->{preserve});
        next unless ($part->{size}->{preserve} || $part->{size}->{resize});
        ($part->{size}->{extended}) and die
          "Preserving extended partitions is not supported; mark all logical partitions instead\n";
        if (0 != $part_id) {
          defined ($FAI::current_config{$1}{partitions}{$part_id}) or die
            "Can't preserve ". &FAI::make_device_name($1, $part_id)
              . " because it does not exist\n";
          defined ($part->{size}->{range}) or die
            "Can't preserve ". &FAI::make_device_name($1, $part_id)
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
    } elsif ($config eq "BTRFS") {
      #no preserve, yet
    } elsif ($config eq "CRYPT") {
      # We don't do preserve for encrypted partitions
      next;
    } elsif ($config eq "TMPFS") {
      # We don't do preserve for tmpfs
      next;
    } elsif ($config eq "NFS") {
      # We don't do preserve for nfs
      next;
    } else {
      &FAI::internal_error("Unexpected key $config");
    }
  }
}


1;

