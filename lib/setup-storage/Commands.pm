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
# @file commands.pm
#
# @brief Build the required commands in @FAI::commands using the config stored
# in %FAI::configs
#
# $Id$
#
# @author Christian Kern, Michael Tautschnig, Sebastian Hetze, Andreas Schuldei
# @date Sun Jul 23 16:09:36 CEST 2006
#
################################################################################

package FAI;

################################################################################
#
# @brief Build the mkfs commands for the partition pointed to by $partition
#
# @param $device Device name of the target partition
# @param $partition Reference to partition in the config hash
#
################################################################################
sub build_mkfs_commands {

  my ($device, $partition) = @_;

  defined ($partition->{filesystem})
    or &FAI::internal_error("filesystem is undefined");
  my $fs = $partition->{filesystem};

  return if ($fs eq "-");

  my ($create_options) = $partition->{fs_options} =~ m/createopts="([^"]+)"/;
  my ($tune_options)   = $partition->{fs_options} =~ m/tuneopts="([^"]+)"/;

  # this enables the use of all remaining options as create option if
  # you did not specify createopts= Example: -m0 -i0 will then be used
  # as createopts. This fails if you do only specify tuneopts without
  # using createopts. Therefore is disable this feature. IMO this
  # special behaviour is also not documented in setup-storage.8
  # T.Lange
  # $create_options = $partition->{fs_options} unless $create_options;

  # prevent warnings of uninitialized variables
  $create_options = '' unless $create_options;
  $tune_options   = '' unless $tune_options;

  print "$partition->{mountpoint} create_options: $create_options\n" if ($FAI::debug && $create_options);
  print "$partition->{mountpoint} tune_options: $tune_options\n" if ($FAI::debug && $tune_options);

  # check for encryption requests
  $device = &FAI::encrypt_device($device, $partition);

  # create the file system with options
  my $create_tool = "mkfs.$fs";
  ($fs eq "swap") and $create_tool = "mkswap";
  ($fs eq "xfs") and $create_options = "$create_options -f" unless ($create_options =~ m/-f/);
  my $pre_encrypt = "exist_$device";
  $pre_encrypt = "encrypt_$device" if ($partition->{encrypt});
  &FAI::push_command( "$create_tool $create_options $device", $pre_encrypt,
    "has_fs_$device" );

  # possibly tune the file system - this depends on whether the file system
  # supports tuning at all
  return unless $tune_options;
  my $tune_tool;
  ($fs eq "ext2" || $fs eq "ext3") and $tune_tool = "tune2fs";
  ($fs eq "reiserfs") and $tune_tool = "reiserfstune";
  die "Don't know how to tune $fs\n" unless $tune_tool;

  # add the tune command
  &FAI::push_command( "$tune_tool $tune_options $device", "has_fs_$device",
    "has_fs_$device" );
}

################################################################################
#
# @brief Encrypt a device and change the device name before formatting it
#
# @param $device Original device name of the target partition
# @param $partition Reference to partition in the config hash
#
# @return Device name, may be the same as $device
#
################################################################################
sub encrypt_device {

  my ($device, $partition) = @_;

  return $device unless $partition->{encrypt};

  # encryption requested, rewrite the device name
  my $enc_dev_name = $device;
  $enc_dev_name =~ "s#/#_#g";
  my $enc_dev_short_name = "crypt$enc_dev_name";
  $enc_dev_name = "/dev/mapper/$enc_dev_short_name";
  my $keyfile = "$ENV{LOGDIR}/$enc_dev_short_name";

  # generate a key for encryption
  &FAI::push_command( 
    "head -c 2048 /dev/urandom | head -n 47 | tail -n 46 | od | tee $keyfile",
    "", "keyfile_$device" );

  # prepare encryption
  &FAI::push_command(
    "yes YES | cryptsetup luksFormat $device $keyfile -c aes-cbc-essiv:sha256 -s 256",
    "exist_$device,keyfile_$device", "crypt_format_$device" );
  &FAI::push_command(
    "cryptsetup luksOpen $device $enc_dev_short_name --key-file $keyfile",
    "crypt_format_$device", "encrypted_$device" );

  # add entries to crypttab
  push @FAI::crypttab, "$enc_dev_short_name\t$device\t$keyfile\tluks";

  return $enc_dev_name;
}

################################################################################
#
# @brief Set the partition type $t on a device $d. This is a no-op if $d is not
# a physical device
#
# @param $d Device name
# @param $t Type (e.g., lvm or raid)
#
################################################################################
sub set_partition_type_on_phys_dev {

  my ($d, $t) = @_;
  my ($i_p_d, $disk, $part_no) = &FAI::phys_dev($d);
  return unless $i_p_d;
  # make sure this device really exists (we can't check for the partition
  # as that may be created later on
  (-b $disk) or die "Specified disk $disk does not exist in this system!\n";
  # set the raid flag
  &FAI::push_command( "parted -s $disk set $part_no $t on", "exist_$d",
    "type_${t}_$d" );
}

################################################################################
#
# @brief Using the configurations from %FAI::configs, a list of commands is
# built to create any RAID devices
#
################################################################################
sub build_raid_commands {

  foreach my $config (keys %FAI::configs) { # loop through all configs
    # no LVM or physical devices here
    next if ($config =~ /^VG_./ || $config =~ /^PHY_./);
    ($config eq "RAID") or &FAI::internal_error("Invalid config $config");

    # create all raid devices
    foreach my $id (&numsort(keys %{ $FAI::configs{$config}{volumes} })) {

      # keep a reference to the current volume
      my $vol = (\%FAI::configs)->{$config}->{volumes}->{$id};
      # the desired RAID level
      my $level = $vol->{mode};

      warn "RAID implementation is incomplete - preserve is not supported\n" if
        ($vol->{preserve});

      # prepend "raid", if the mode is numeric-only
      $level = "raid$level" if ($level =~ /^\d+$/);

      # the list of RAID devices
      my @devs = keys %{ $vol->{devices} };
      my @eff_devs = ();
      my @spares = ();
      my $pre_req;

      # set proper partition types for RAID
      foreach my $d (@devs) {
        if ($vol->{devices}{$d}{missing}) {
          if ($vol->{devices}->{$d}->{spare}) {
            push @spares, "missing";
          } else {
            push @eff_devs, "missing";
          }
          # skip devices marked missing
          next if $vol->{devices}{$d}{missing};
        } else {
          if ($vol->{devices}->{$d}->{spare}) {
            push @spares, $d;
          } else {
            push @eff_devs, $d;
          }
        }
        &FAI::set_partition_type_on_phys_dev($d, "raid");
        if ((&FAI::phys_dev($d))[0]) {
          $pre_req .= ",type_raid_$d";
        } else {
          $pre_req .= ",exist_$d";
        }
      }
      my $pre_req_no_comma = $pre_req;
      $pre_req_no_comma =~ s/^,//;
      # wait for udev to set up all devices
      &FAI::push_command( "udevsettle --timeout=10", $pre_req_no_comma,
        "settle_for_mdadm_create$id" );

      # create the command
      if (0 == $id) {
        $pre_req = "settle_for_mdadm_create$id$pre_req";
      } else {
        $pre_req = "settle_for_mdadm_create$id,exist_/dev/md" . ( $id - 1 ) . $pre_req;
      }
      &FAI::push_command(
        "yes | mdadm --create /dev/md$id --level=$level --force --run --raid-devices="
          . scalar(@eff_devs) . " --spare-devices=" . scalar(@spares) . " "
          . join(" ", @eff_devs) . " " . join(" ", @spares),
        "$pre_req", "run_udev_/dev/md$id" );

      &FAI::push_command( "udevsettle --timeout=10", "run_udev_/dev/md$id",
        "exist_/dev/md$id" );

      # create the filesystem on the volume
      &FAI::build_mkfs_commands("/dev/md$id",
        \%{ $FAI::configs{$config}{volumes}{$id} });
    }
  }
}

################################################################################
#
# @brief Erase the LVM signature from a list of devices that should be prestine
# in order to avoid confusion of the lvm tools
#
################################################################################
sub erase_lvm_signature {

  my ($devices_aref) = @_;
  # first remove the dm_mod module to prevent ghost lvm volumes 
  # from existing
  # push @FAI::commands, "modprobe -r dm_mod";
  # zero out (broken?) lvm signatures
  # push @FAI::commands, "dd if=/dev/zero of=$_ bs=1 count=1"
  #   foreach ( @{$devices_aref} );
  my $device_list = join (" ", @{$devices_aref});
  $FAI::debug and print "Erased devices: $device_list\n"; 
  &FAI::push_command( "pvremove -ff -y $device_list", "", "pv_sigs_removed" );

  # reload module
  # push @FAI::commands, "modprobe dm_mod";
}

################################################################################
#
# @brief Create the volume group $config, unless it exists already; if the
# latter is the case, only add/remove the physical devices
#
# @param $config Config entry
#
################################################################################
sub create_volume_group {

  my ($config) = @_;
  ($config =~ /^VG_(.+)$/) and ($1 ne "--ANY--") or &FAI::internal_error("Invalid config $config");
  my $vg = $1; # the actual volume group

  # create the volume group, if it doesn't exist already
  if (!defined ($FAI::current_lvm_config{$vg})) {
    # create all the devices
    my @devices = keys %{ $FAI::configs{$config}{devices} };
    &FAI::erase_lvm_signature(\@devices);
    &FAI::push_command( "pvcreate $_", "pv_sigs_removed,exist_$_",
      "pv_done_$_" ) foreach (@devices);
    # create the volume group
    my $pre_dev = "";
    $pre_dev .= ",pv_done_$_" foreach (@devices);
    $pre_dev =~ s/^,//;
    &FAI::push_command( "vgcreate $vg " . join (" ", @devices), "exist_$pre_dev",
      "vg_created_$vg" );
    # we are done
    return;
  }

  # otherwise add or remove the devices for the volume group, run pvcreate
  # where needed
  # the list of devices to be created
  my %new_devs = ();

  # create an undefined entry for each new device
  @new_devs{ keys %{ $FAI::configs{$config}{devices} } } = ();

  my @new_devices = keys %new_devs;

  # &FAI::erase_lvm_signature( \@new_devices );

  # create all the devices
  &FAI::push_command( "pvcreate $_", "exist_$_", "pv_done_$_" ) foreach (@new_devices);

  # extend the volume group by the new devices (includes the current ones)
  my $pre_dev = "";
  $pre_dev .= ",pv_done_$_" foreach (@new_devices);
  $pre_dev =~ s/^,//;
  &FAI::push_command( "vgextend $vg " . join (" ", @new_devices), "$pre_dev",
    "vg_extended_$vg" );

  # the devices to be removed
  my %rm_devs = ();
  @rm_devs{ @{ $FAI::current_lvm_config{$vg}{"physical_volumes"} } } = ();

  # remove remaining devices from the list
  delete $rm_devs{$_} foreach (@new_devices);

  # run vgreduce to get them removed
  if (scalar (keys %rm_devs)) {
    $pre_dev = "";
    $pre_dev .= ",pv_done_$_" foreach (keys %rm_devs);
    &FAI::push_command( "vgreduce $vg " . join (" ", keys %rm_devs),
      "vg_extended_$vg$pre_dev", "vg_created_$vg" );
  } else {
    &FAI::push_command( "true", "vg_extended_$vg", "vg_created_$vg" );
  }
}

################################################################################
#
# @brief Create the volume group $config, unless it exists already; if the
# latter is the case, only add/remove the physical devices
#
# @param $config Config entry
#
################################################################################
sub setup_logical_volumes {

  my ($config) = @_;
  ($config =~ /^VG_(.+)$/) and ($1 ne "--ANY--") or &FAI::internal_error("Invalid config $config");
  my $vg = $1; # the actual volume group

  my $lv_rm_pre = "";
  my $lv_resize_pre = "";
  # remove, resize, create the logical volumes
  # remove all volumes that do not exist anymore or need not be preserved
  foreach my $lv (keys %{ $FAI::current_lvm_config{$vg}{volumes} }) {
    # skip preserved/resized volumes
    if (defined ( $FAI::configs{$config}{volumes}{$lv})
      && ($FAI::configs{$config}{volumes}{$lv}{size}{preserve} == 1)) {
      $lv_resize_pre .= ",lv_resize_$vg/$lv" if
        $FAI::configs{$config}{volumes}{$lv}{size}{resize};
      next;
    }

    &FAI::push_command( "lvremove -f $vg/$lv", "vg_enabled_$vg", "lv_rm_$vg/$lv");
    $lv_rm_pre .= ",lv_rm_$vg/$lv";
  }
  $lv_rm_pre =~ s/^,//;
  $lv_resize_pre =~ s/^,//;

  # now create or resize the configured logical volumes
  foreach my $lv (keys %{ $FAI::configs{$config}{volumes} }) {
    # reference to the size of the current logical volume
    my $lv_size = (\%FAI::configs)->{$config}->{volumes}->{$lv}->{size};
    # skip preserved partitions, but ensure that they exist
    if ($lv_size->{preserve}) {
      defined ($FAI::current_lvm_config{$vg}{volumes}{$lv})
        or die "Preserved volume $vg/$lv does not exist\n";
      next;
    }

    # resize the volume
    if ($lv_size->{resize}) {
      defined ($FAI::current_lvm_config{$vg}{volumes}{$lv})
        or die "Resized volume $vg/$lv does not exist\n";

      if ($lv_size->{eff_size} <
        $FAI::current_lvm_config{$vg}{volumes}{$lv}{size})
      {
        &FAI::push_command( "parted -s /dev/$vg/$lv resize 1 0 " . $lv_size->{eff_size} .  "B",
          "vg_enabled_$vg,$lv_rm_pre", "lv_shrink_$vg/$lv" );
        &FAI::push_command( "lvresize -L " . $lv_size->{eff_size} . " $vg/$lv",
          "vg_enabled_$vg,$lv_rm_pre,lv_shrink_$vg/$lv", "lv_created_$vg/$lv" );
      } else {
        &FAI::push_command( "lvresize -L " . $lv_size->{eff_size} . " $vg/$lv",
          "vg_enabled_$vg,$lv_rm_pre", "lv_grow_$vg/$lv" );
        &FAI::push_command( "parted -s /dev/$vg/$lv resize 1 0 " . $lv_size->{eff_size} .  "B",
          "vg_enabled_$vg,$lv_rm_pre,lv_grow_$vg/$lv", "exist_/dev/$vg/$lv" );
      }

      next;
    }

    # create a new volume
    &FAI::push_command( "lvcreate -n $lv -L " . $lv_size->{eff_size} . " $vg",
      "vg_enabled_$vg,$lv_rm_pre", "run_udev_/dev/$vg/$lv" );
    &FAI::push_command( "udevsettle --timeout=10", "run_udev_/dev/$vg/$lv",
      "exist_/dev/$vg/$lv" );

    # create the filesystem on the volume
    &FAI::build_mkfs_commands("/dev/$vg/$lv",
      \%{ $FAI::configs{$config}{volumes}{$lv} });
  }
}

################################################################################
#
# @brief Using the configurations from %FAI::configs, a list of commands is
# built to setup the LVM
# creates the volume groups, the logical volumes and the filesystems
#
################################################################################
sub build_lvm_commands {

  # loop through all configs
  foreach my $config (keys %FAI::configs) {

    # no physical devices or RAID here
    next if ($config =~ /^PHY_./ || $config eq "RAID");
    ($config =~ /^VG_(.+)$/) or &FAI::internal_error("Invalid config $config");
    next if ($1 eq "--ANY--");
    my $vg = $1; # the volume group

    # set proper partition types for LVM
    &FAI::set_partition_type_on_phys_dev($_, "lvm")
      foreach (keys %{ $FAI::configs{$config}{devices} });
    my $type_pre = "";
    foreach my $d (keys %{ $FAI::configs{$config}{devices} }) {
      if ((&FAI::phys_dev($d))[0]) {
        $type_pre .= ",type_lvm_$d"
      } else {
        $type_pre .= ",exist_$d"
      }
    }
    $type_pre =~ s/^,//;
    # wait for udev to set up all devices
    &FAI::push_command( "udevsettle --timeout=10", "$type_pre",
      "settle_for_vgchange_$vg" );

    # create the volume group or add/remove devices
    &FAI::create_volume_group($config);
    # enable the volume group
    &FAI::push_command( "vgchange -a y $vg",
      "settle_for_vgchange_$vg,vg_created_$vg", "vg_enabled_$vg" );

    # perform all necessary operations on the underlying logical volumes
    &FAI::setup_logical_volumes($config);
  }
}

################################################################################
#
# @brief Return an ordered list of partitions that must be preserved
#
# @param $config Config entry
#
################################################################################
sub get_preserved_partitions {

  my ($config) = @_;
  ($config =~ /^PHY_(.+)$/) or &FAI::internal_error("Invalid config $config");
  my $disk = $1; # the device to be configured

  # the list of partitions that must be preserved
  my @to_preserve = ();

  # find partitions that should be preserved or resized
  foreach my $part_id (&numsort(keys %{ $FAI::configs{$config}{partitions} })) {
    # reference to the current partition
    my $part = (\%FAI::configs)->{$config}->{partitions}->{$part_id};
    next unless ($part->{size}->{preserve} || $part->{size}->{resize});

    # preserved or resized partitions must exist already
    defined( $FAI::current_config{$disk}{partitions}{$part_id} )
      or die "$part_id can't be preserved, it does not exist.\n";

    # add a mapping from the configured partition to the existing one
    # (identical here, may change for extended partitions below)
    $part->{maps_to_existing} = $part_id;

    # add $part_id to the list of preserved partitions
    push @to_preserve, $part_id;

  }

  # sort the list of preserved partitions
  @to_preserve = &numsort(@to_preserve);

  # add the extended partition as well, if logical partitions must be
  # preserved; and mark it as resize
  if ($FAI::configs{$config}{disklabel} eq "msdos") {
    # we assume there are no logical partitions
    my $has_logical = 0;
    my $extended    = -1;

    # now check all entries; the array is sorted
    foreach my $part_id (@to_preserve) {
      # the extended partition may already be listed; then, the id of the
      # extended partition must not change
      if ($FAI::current_config{$disk}{partitions}{$part_id}{is_extended}) {
        (defined ($FAI::configs{$config}{partitions}{$extended}{size}{extended})
          && defined ($FAI::current_config{$disk}{partitions}{$extended}{is_extended})
          && $FAI::configs{$config}{partitions}{$extended}{size}{extended}
          && $FAI::current_config{$disk}{partitions}{$extended}{is_extended}) 
          or die "ID of extended partition changes\n";

        # make sure resize is set
        $FAI::configs{$config}{partitions}{$part_id}{size}{resize} = 1;
        $extended = $part_id;
        last;
      }

      # there is some logical partition
      if ($part_id > 4) {
        $has_logical = 1;
        last;
      }
    }

    # if the extended partition is not listed yet, find and add it now; note
    # that we need to add the existing one
    if ($has_logical && -1 == $extended) {
      foreach my $part_id (&numsort(keys %{ $FAI::current_config{$disk}{partitions} })) {

        # no extended partition
        next unless
          $FAI::current_config{$disk}{partitions}{$part_id}{is_extended};

        # find the configured extended partition to set the mapping
        foreach my $p (&numsort(keys %{ $FAI::configs{$config}{partitions} })) {
          # reference to the current partition
          my $part = (\%FAI::configs)->{$config}->{partitions}->{$p};
          next unless $part->{size}->{extended};

          # make sure resize is set
          $part->{size}->{resize} = 1;

          # store the id for further checks
          $extended = $p;

          # add a mapping entry to the existing extended partition
          $part->{maps_to_existing} = $part_id;

          # add it to the preserved partitions
          push @to_preserve, $p;

          last;
        }

        # sort the list of preserved partitions (again)
        @to_preserve = &numsort(@to_preserve);

        last;
      }
    }

    # a sanity check: if there are logical partitions, the extended must
    # have been added
    (0 == $has_logical || -1 != $extended) 
      or &FAI::internal_error("Required extended partition not detected for preserve");
  }

  return @to_preserve;
}

################################################################################
#
# @brief Recreate the preserved partitions once the partition table has been
# flushed
#
# @param $config Config entry
# @param $to_preserve Reference to list of preserved/resized partitions
#
################################################################################
sub rebuild_preserved_partitions {

  my ($config, $to_preserve) = @_;
  ($config =~ /^PHY_(.+)$/) or &FAI::internal_error("Invalid config $config");
  my $disk = $1; # the device to be configured

  # once we rebuild partitions, their ids are likely to change; this counter
  # helps keeping track of this
  my $part_nr = 0;

  # now rebuild all preserved partitions
  foreach my $part_id (@{$to_preserve}) {
    # get the existing id
    my $mapped_id =
    $FAI::configs{$config}{partitions}{$part_id}{maps_to_existing};

    # get the original starts and ends
    my $start =
      $FAI::current_config{$disk}{partitions}{$mapped_id}{begin_byte};
    my $end =
      $FAI::current_config{$disk}{partitions}{$mapped_id}{end_byte};

    # the type of the partition defaults to primary
    my $part_type = "primary";
    if ( $FAI::configs{$config}{disklabel} eq "msdos" ) {

      # change the partition type to extended or logical as appropriate
      if ( $FAI::configs{$config}{partitions}{$part_id}{size}{extended} == 1 ) {
        $part_type = "extended";
      } elsif ( $part_id > 4 ) {
        $part_type = "logical";
        $part_nr = 4 if ( $part_nr < 4 );
      }
    }

    # restore the partition type, if any
    my $fs =
      $FAI::current_config{$disk}{partitions}{$mapped_id}{filesystem};

    # increase the partition counter for the partition created next and
    # write it to the configuration
    $part_nr++;
    $FAI::current_config{$disk}{partitions}{$mapped_id}{new_id} = $part_nr;

    my $post = "run_udev_" . &FAI::make_device_name($disk, $part_nr);
    $post .= ",rebuilt_" . &FAI::make_device_name($disk, $part_nr) if
      $FAI::configs{$config}{partitions}{$part_id}{size}{resize};
    # build a parted command to create the partition
    &FAI::push_command( "parted -s $disk mkpart $part_type $fs ${start}B ${end}B",
      "cleared1_$disk", $post );
    &FAI::push_command( "udevsettle --timeout=10", "run_udev_" .
      &FAI::make_device_name($disk, $part_nr), "exist_" .
      &FAI::make_device_name($disk, $part_nr) );
  }
}

################################################################################
#
# @brief Set up physical partitions
#
# @param $config Config entry
#
################################################################################
sub setup_partitions {

  my ($config) = @_;
  ($config =~ /^PHY_(.+)$/) or &FAI::internal_error("Invalid config $config");
  my $disk = $1; # the device to be configured

  # the list of partitions that must be preserved
  my @to_preserve = &FAI::get_preserved_partitions($config);

  # A new disk label may only be written if no partitions need to be
  # preserved
  (($FAI::configs{$config}{disklabel} eq
      $FAI::current_config{$disk}{disklabel})
    || (scalar (@to_preserve) == 0)) 
    or die "Can't change disklabel, partitions are to be preserved\n";

  # write the disklabel to drop the previous partition table
  &FAI::push_command( "parted -s $disk mklabel " .
    $FAI::configs{$config}{disklabel}, "exist_$disk", "cleared1_$disk" );

  &FAI::rebuild_preserved_partitions($config, \@to_preserve);

  my $pre_all_resize = "";

  # resize partitions while checking for dependencies
  foreach my $part_id (reverse &numsort(@to_preserve)) {
    # reference to the current partition
    my $part = (\%FAI::configs)->{$config}->{partitions}->{$part_id};
    # get the existing id
    my $mapped_id = $part->{maps_to_existing};
    # get the intermediate partition id
    my $p = $FAI::current_config{$disk}{partitions}{$mapped_id}{new_id};
    # anything to be done?
    $pre_all_resize .= ",exist_" . &FAI::make_device_name($disk, $p) unless
      $part->{size}->{resize};
    next unless $part->{size}->{resize};

    $pre_all_resize .= ",resized_" . &FAI::make_device_name($disk, $p);
    my $deps = "";
    # now walk all other partitions requiring a resize to check for overlaps
    foreach my $part_other (reverse &numsort(@to_preserve)) {
      # don't compare to self
      next if ($part_id == $part_other);
      # reference to the current partition
      my $part_other_ref = (\%FAI::configs)->{$config}->{partitions}->{$part_other};
      # anything to be done?
      next unless $part_other_ref->{size}->{resize};
      # get the existing id
      my $mapped_id_other = $part_other_ref->{maps_to_existing};
      # get the intermediate partition id
      my $p_other = $FAI::current_config{$disk}{partitions}{$mapped_id_other}{new_id};
      # check for overlap
      next if($part->{start_byte} >
        $FAI::current_config{$disk}{partitions}{$mapped_id_other}{end_byte});
      next if($part->{end_byte} <
        $FAI::current_config{$disk}{partitions}{$mapped_id_other}{begin_byte});
      # overlap detected - add dependency, but handle extended<->logical with
      # special care, even though this does not catch all cases (sometimes it
      # will fail nevertheless
      if ($part->{size}->{extended} && $part_other > 4) {
        if($part->{start_byte} >
          $FAI::current_config{$disk}{partitions}{$mapped_id_other}{begin_byte}) {
          $deps .= ",resized_" . &FAI::make_device_name($disk, $p_other);
        }
        elsif($part->{end_byte} <
          $FAI::current_config{$disk}{partitions}{$mapped_id_other}{end_byte}) {
          $deps .= ",resized_" . &FAI::make_device_name($disk, $p_other);
        }
      }
      elsif ($part_id > 4 && $part_other_ref->{size}->{extended}) {
        if($part->{start_byte} <
          $FAI::current_config{$disk}{partitions}{$mapped_id_other}{begin_byte}) {
          $deps .= ",resized_" . &FAI::make_device_name($disk, $p_other);
        }
        elsif($part->{end_byte} >
          $FAI::current_config{$disk}{partitions}{$mapped_id_other}{end_byte}) {
          $deps .= ",resized_" . &FAI::make_device_name($disk, $p_other);
        }
      } else {
        $deps .= ",resized_" . &FAI::make_device_name($disk, $p_other);
      }
    }

    # get the new starts and ends
    my $start = $part->{start_byte};
    my $end = $part->{end_byte};

    # build an appropriate command
    # ntfs requires specific care
    if ($FAI::current_config{$disk}{partitions}{$mapped_id}{filesystem} eq
      "ntfs") {
      # check, whether ntfsresize is available
      &FAI::in_path("ntfsresize") or die "ntfsresize not found in PATH\n";
      # ntfs partition can't be moved
      ($start == $FAI::current_config{$disk}{partitions}{$mapped_id}{begin_byte}) 
        or &FAI::internal_error("ntfs partition supposed to move");
      # ntfsresize requires device names
      my $eff_size = $part->{size}->{eff_size};

      # wait for udev to set up all devices
      &FAI::push_command( "udevsettle --timeout=10", "rebuilt_" .
        &FAI::make_device_name($disk, $p) . $deps, "settle_for_resize_" .
        &FAI::make_device_name($disk, $p) );
      &FAI::push_command( "yes | ntfsresize -s $eff_size " .
        &FAI::make_device_name($disk, $p), "settle_for_resize_" .
        &FAI::make_device_name($disk, $p), "ntfs_ready_for_rm_" .
        &FAI::make_device_name($disk, $p) );
      &FAI::push_command( "parted -s $disk rm $p", "ntfs_ready_for_rm_" .
        &FAI::make_device_name($disk, $p), "resized_" .
        &FAI::make_device_name($disk, $p) );
    } else {
      &FAI::push_command( "parted -s $disk resize $p ${start}B ${end}B",
        "rebuilt_" . &FAI::make_device_name($disk, $p) . $deps, "resized_" .
        &FAI::make_device_name($disk, $p) );
    }

  }

  # write the disklabel again to drop the partition table and create a new one
  # that has the proper ids
  &FAI::push_command( "parted -s $disk mklabel " .
    $FAI::configs{$config}{disklabel}, "cleared1_$disk$pre_all_resize",
    "cleared2_$disk" );

  my $prev_id = -1;
  # generate the commands for creating all partitions
  foreach my $part_id (&numsort(keys %{ $FAI::configs{$config}{partitions} })) {
    # reference to the current partition
    my $part = (\%FAI::configs)->{$config}->{partitions}->{$part_id};
    # get the existing id
    my $mapped_id = $part->{maps_to_existing};

    # get the new starts and ends
    my $start = $part->{start_byte};
    my $end = $part->{end_byte};

    # the type of the partition defaults to primary
    my $part_type = "primary";
    if ($FAI::configs{$config}{disklabel} eq "msdos") {

      # change the partition type to extended or logical as appropriate
      if ($part->{size}->{extended} == 1) {
        $part_type = "extended";
      } elsif ($part_id > 4) {
        $part_type = "logical";
      }
    }

    my $fs = $part->{filesystem};
    $fs = "" unless defined($fs);
    $fs = "linux-swap" if ($fs eq "swap");
    $fs = "fat32" if ($fs eq "vfat");
    $fs = "fat16" if ($fs eq "msdos");
    $fs = $FAI::current_config{$disk}{partitions}{$mapped_id}{filesystem}
      if ($part->{size}->{preserve} || $part->{size}->{resize});
    $fs = "" if ($fs eq "-");

    my $pre = "";
    $pre = ",exist_" . &FAI::make_device_name($disk, $prev_id) if ($prev_id > -1);
    # build a parted command to create the partition
    &FAI::push_command( "parted -s $disk mkpart $part_type $fs ${start}B ${end}B",
      "cleared2_$disk$pre", "run_udev_" . &FAI::make_device_name($disk, $part_id) );
    &FAI::push_command( "udevsettle --timeout=10", "run_udev_" . 
      &FAI::make_device_name($disk, $part_id), "exist_" . 
      &FAI::make_device_name($disk, $part_id) );
    $prev_id = $part_id;
  }

  # set the bootable flag, if requested at all
  if ($FAI::configs{$config}{bootable} > -1) {
    &FAI::push_command( "parted -s $disk set " .
      $FAI::configs{$config}{bootable} . " boot on", "exist_" .
      &FAI::make_device_name($disk, $FAI::configs{$config}{bootable}),
      "boot_set_$disk" );
  }
}


################################################################################
#
# @brief Using the configurations from %FAI::configs, a list of commands is
# built to setup the partitions
#
################################################################################
sub build_disk_commands {

  # loop through all configs
  foreach my $config ( keys %FAI::configs ) {
    # no RAID or LVM devices here
    next if ($config eq "RAID" || $config =~ /^VG_./);
    ($config =~ /^PHY_(.+)$/) or &FAI::internal_error("Invalid config $config");
    my $disk = $1; # the device to be configured

    # create partitions on non-virtual configs
    &FAI::setup_partitions($config) unless ($FAI::configs{$config}{virtual});

    # generate the commands for creating all filesystems
    foreach my $part_id (&numsort(keys %{ $FAI::configs{$config}{partitions} })) {
      # reference to the current partition
      my $part = (\%FAI::configs)->{$config}->{partitions}->{$part_id};

      # skip preserved/resized/extended partitions
      next if ($part->{size}->{preserve} == 1
        || $part->{size}->{resize} == 1 || $part->{size}->{extended} == 1);

      # create the filesystem on the device
      &FAI::build_mkfs_commands( &FAI::make_device_name($disk, $part_id), $part );
    }
  }
}

################################################################################
#
# @brief Whatever happened, write the previous partition table to the disk again
#
################################################################################
sub restore_partition_table {

  # loop through all existing configs
  foreach my $disk (keys %FAI::current_config) {

    # write the disklabel again to drop the partition table
    &FAI::execute_command("parted -s $disk mklabel "
        . $FAI::current_config{$disk}{disklabel}, 0, 0);

    # generate the commands for creating all partitions
    foreach my $part_id (&numsort(keys %{ $FAI::current_config{$disk}{partitions} })) {
      # reference to the current partition
      my $curr_part = (\%FAI::current_config)->{$disk}->{partitions}->{$part_id};

      # get the starts and ends
      my $start = $curr_part->{begin_byte};
      my $end = $curr_part->{end_byte};

      # the type of the partition defaults to primary
      my $part_type = "primary";
      if ($FAI::current_config{$disk}{disklabel} eq "msdos") {

        # change the partition type to extended or logical as appropriate
        if ($curr_part->{is_extended}) {
          $part_type = "extended";
        } elsif ($part_id > 4) {
          $part_type = "logical";
        }
      }

      # restore the partition type, if any
      my $fs = $curr_part->{filesystem};

      # build a parted command to create the partition
      &FAI::execute_command("parted -s $disk mkpart $part_type $fs ${start}B ${end}B");
    }
    warn "Partition table of disk $disk has been restored\n";
  }

  die "setup-storage failed, but the partition tables have been restored\n";
}

################################################################################
#
# @brief Try to order the queued commands to satisfy all dependencies
#
################################################################################
sub order_commands {
  my @pre_deps = ();
  my $i = 1;
  my $pushed = -1;

  while ($i < $FAI::n_c_i) {
    my $all_matched = 1;
    if (defined($FAI::commands{$i}{pre})) {
      foreach (split(/,/, $FAI::commands{$i}{pre})) {
        my $cur = $_;
        next if scalar(grep(m{^$cur$}, @pre_deps));
        $all_matched = 0;
        last;
      }
    }
    if ($all_matched) {
      defined($FAI::commands{$i}{post}) and push @pre_deps, split(/,/, $FAI::commands{$i}{post});
      $pushed = -1;
      $i++;
      next;
    }
    if (-1 == $pushed) {
      $pushed = $FAI::n_c_i;
    }
    elsif ($i == $pushed) {
      die "Cannot satisfy pre-depends for " . $FAI::commands{$i}{cmd} . ": " .
        $FAI::commands{$i}{pre} . " -- system left untouched.\n";
    }
    &FAI::push_command( $FAI::commands{$i}{cmd}, $FAI::commands{$i}{pre},
      $FAI::commands{$i}{post} );
    delete $FAI::commands{$i};
    $i++;
  }
}

1;

