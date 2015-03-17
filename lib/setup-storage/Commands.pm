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
# @author Christian Kern, Michael Tautschnig, Sebastian Hetze, Andreas Schuldei
# @date Sun Jul 23 16:09:36 CEST 2006
#
################################################################################

package FAI;

my %partition_table_deps;

################################################################################
#
# @brief Build the mkfs commands for the partition pointed to by $partition
#
# @param $device Device name of the target partition
# @param $partition Reference to partition in the config hash
#
################################################################################

my @preserved_raid = ();

sub build_mkfs_commands {

  my ($device, $partition) = @_;

  # check for old-style encryption requests
  &FAI::handle_oldstyle_encrypt_device($device, $partition);

  defined ($partition->{filesystem})
    or &FAI::internal_error("filesystem is undefined");
  my $fs = $partition->{filesystem};
  my $journal = $partition->{journal_dev};

  return if ($fs eq "-");

  my ($create_options) = $partition->{createopts};
  my ($tune_options)   = $partition->{tuneopts};
  # prevent warnings of uninitialized variables
  $create_options = '' unless $create_options;
  $tune_options   = '' unless $tune_options;

  print "$partition->{mountpoint} FS create_options: $create_options\n" if ($FAI::debug && $create_options);
  print "$partition->{mountpoint} FS tune_options: $tune_options\n" if ($FAI::debug && $tune_options);

  my $prereqs = "exist_$device";
  my $provides;
  my $create_tool;

  # create filesystem journal
  if ($fs =~ m/.*_journal$/) {
      $provides = "journal_preped_$device";
      undef($tune_options);

      if ($fs =~ /ext[34]_journal/) {
	  $create_tool = "mke2fs";
	  $create_options = "-O journal_dev";
      } elsif ($fs eq "xfs_journal") {
	  $create_tool = "/bin/true";
	  $create_options = "";
      } else {
	  &FAI::internal_error("unsupported journal type $fs");
      }
  } else {
      # create regular filesystem
      $provides = "has_fs_$device";
      $create_tool = "mkfs.$fs";

      ($fs eq "swap") and $create_tool = "mkswap";
      ($fs eq "xfs") and $create_options = "$create_options -f" unless ($create_options =~ m/-f/);
      ($fs eq "reiserfs") and $create_options = "$create_options -q" unless ($create_options =~ m/-(f|q|y)/);

      # adjust options for filesystem with external journal
      if (defined($journal)) {
	  $journal =~ s/^journal=//;
	  $prereqs = "$prereqs,journal_preped_$journal";

	  ($fs eq "xfs") and $create_options = "$create_options -l logdev=$journal";
	  ($fs eq "ext3") and $create_options = "$create_options -J device=$journal";
	  ($fs eq "ext4") and $create_options = "$create_options -J device=$journal";
      }
  }

  &FAI::push_command( "$create_tool $create_options $device", $prereqs, $provides);

  # possibly tune the file system - this depends on whether the file system
  # supports tuning at all
  return unless $tune_options;
  my $tune_tool;
  ($fs eq "ext2" || $fs eq "ext3" || $fs eq "ext4") and $tune_tool = "tune2fs";
  ($fs eq "reiserfs") and $tune_tool = "reiserfstune";
  die "Don't know how to tune $fs\n" unless $tune_tool;

  # add the tune command
  &FAI::push_command( "$tune_tool $tune_options $device", "has_fs_$device",
    "has_fs_$device" );
}

################################################################################
#
# @brief Check for encrypt option and prepare corresponding CRYPT entry
#
# If encrypt is set, a corresponding CRYPT entry will be created and filesystem
# and mountpoint get set to -
#
# @param $device Original device name of the target partition
# @param $partition Reference to partition in the config hash
#
################################################################################
sub handle_oldstyle_encrypt_device {

  my ($device, $partition) = @_;

  return unless ($partition->{encrypt});

  if (!defined($FAI::configs{CRYPT}{randinit})) {
    $FAI::configs{CRYPT}{fstabkey} = "device";
    $FAI::configs{CRYPT}{randinit} = 0;
    $FAI::configs{CRYPT}{volumes} = {};
  }

  $FAI::configs{CRYPT}{randinit} = 1 if ($partition->{encrypt} > 1);

  my $vol_id = scalar(keys %{ $FAI::configs{CRYPT}{volumes} });
  $FAI::configs{CRYPT}{volumes}{$vol_id} = {
    device => $device,
    mode => "luks",
    preserve => (defined($partition->{size}) ?
        $partition->{size}->{preserve} : $partition->{preserve}),
    mountpoint => $partition->{mountpoint},
    mount_options => $partition->{mount_options},
    filesystem => $partition->{filesystem},
    createopts => $partition->{createopts},
    tuneopts => $partition->{tuneopts}
  };

  $partition->{mountpoint} = "-";
  $partition->{filesystem} = "-";
}

################################################################################
#
# @brief Set the partition flag $t on a device $d. This is a no-op if $d is not
# a physical device
#
# @param $d Device name
# @param $t Flag (e.g., lvm or raid)
#
################################################################################
sub set_partition_flag_on_phys_dev {

  my ($d, $t) = @_;
  my ($i_p_d, $disk, $part_no) = &FAI::phys_dev($d);
  return 0 unless $i_p_d;
  # make sure this device really exists (we can't check for the partition
  # as that may be created later on
  (-b $disk) or die "Specified disk $disk does not exist in this system!\n";
  # set the raid/lvm unless this is an entire disk flag or a virtual disk
  return 0 if ($part_no == -1 ||
    (defined($FAI::configs{"PHY_$disk"}) && $FAI::configs{"PHY_$disk"}{virtual}));
  my $pre = "exist_$d";
  $pre .= ",cleared2_$disk" if (defined($FAI::configs{"PHY_$disk"}));
  &FAI::push_command( "parted -s $disk set $part_no $t on", $pre, "flag_${t}_$d" );
  if (defined($partition_table_deps{$disk}) &&
    $partition_table_deps{$disk} ne "") {
    $partition_table_deps{$disk} .= ",flag_${t}_$d";
  } else {
    $partition_table_deps{$disk} = "flag_${t}_$d";
  }
  return 1;
}

################################################################################
#
# @brief Using the configurations from %FAI::configs, a list of commands is
# built to create any encrypted devices
#
################################################################################
sub build_cryptsetup_commands {
  foreach my $config (keys %FAI::configs) { # loop through all configs
    # no LVM or physical devices here
    next if ($config ne "CRYPT");

    # create all encrypted devices
    foreach my $id (&numsort(keys %{ $FAI::configs{$config}{volumes} })) {

      # keep a reference to the current volume
      my $vol = (\%FAI::configs)->{$config}->{volumes}->{$id};
      # the desired encryption mode
      my $mode = $vol->{mode};

      warn "cryptsetup support is incomplete - preserve is not supported\n"
        if ($vol->{preserve});

      # rewrite the device name
      my $real_dev = $vol->{device};
      my $enc_dev_name = &FAI::enc_name($real_dev);
      my $enc_dev_short_name = $enc_dev_name;
      $enc_dev_short_name =~ s#^/dev/mapper/##;

      my $pre_dep = "exist_$real_dev";

      if ($FAI::configs{$config}{randinit}) {
        # ignore exit 1 caused by reaching the end of $real_dev
        &FAI::push_command(
          "dd if=/dev/urandom of=$real_dev || true",
          $pre_dep, "random_init_$real_dev");
        $pre_dep = "random_init_$real_dev";
      }

      if ($mode =~ /^luks(:"([^"]+)")?$/) {
        my $keyfile = "$FAI::DATADIR/$enc_dev_short_name";

        # generate a key for encryption
        &FAI::push_command(
          "head -c 2048 /dev/urandom | od | tee $keyfile",
          "", "keyfile_$real_dev" );
        # encrypt
        &FAI::push_command(
          "yes YES | cryptsetup luksFormat $real_dev $keyfile -c aes-cbc-essiv:sha256 -s 256",
          "$pre_dep,keyfile_$real_dev", "crypt_format_$real_dev" );
        &FAI::push_command(
          "cryptsetup luksOpen $real_dev $enc_dev_short_name --key-file $keyfile",
          "crypt_format_$real_dev", "exist_$enc_dev_name" );

        if (defined($1)) {
          my $passphrase = $2;

          # add user-defined key
          &FAI::push_command(
            "yes '$passphrase' | cryptsetup luksAddKey --key-file $keyfile $real_dev",
            "exist_$enc_dev_name", "newkey_$enc_dev_name");
          # remove previous key
          &FAI::push_command(
            "yes '$passphrase' | cryptsetup luksRemoveKey $real_dev $keyfile",
            "newkey_$enc_dev_name", "removed_key_$enc_dev_name");

          $keyfile = "none";
        }

        # add entries to crypttab
        push @FAI::crypttab, "$enc_dev_short_name\t$real_dev\t$keyfile\tluks";
      } elsif ($mode eq "tmp" || $mode eq "swap") {
        &FAI::push_command(
          "cryptsetup --key-file=/dev/urandom create $enc_dev_short_name $real_dev",
          $pre_dep, "exist_$enc_dev_name");

        # add entries to crypttab
        push @FAI::crypttab, "$enc_dev_short_name\t$real_dev\t/dev/urandom\t$mode";

      }

      # create the filesystem on the volume
      &FAI::build_mkfs_commands($enc_dev_name,
        \%{ $FAI::configs{$config}{volumes}{$id} });
    }
  }

}

################################################################################
#
# @brief Using the configurations from %FAI::configs, a list of commands is
# built to create all BTRFS volumes/raids
#
################################################################################
sub build_btrfs_commands {
  foreach my $config (keys %FAI::configs) { # loop through all configs
    next unless ($config eq "BTRFS");

    #create BTRFS RAIDs
    foreach my $id (&numsort(keys %{ $FAI::configs{$config}{volumes} })) {
    #reference to current btrfs volume
    my $vol = (\%FAI::configs)->{$config}->{volumes}->{$id};

    #the list of BTRFS-RAID devices
    my @devs = keys %{ $vol->{devices} };
    my $raidlevel = $vol->{raidlevel};
    my $mountpoint = $vol->{mountpoint};
    my $mountoptions = $vol->{mount_options};
    ($mountoptions =~ m/subvol=([^,\s]+)/ and my $initial_subvolume= $1) or die "You must define an initial subvolume for your BTRFS RAID";
    my $btrfscreateopts =  $vol->{btrfscreateopts};
    defined($btrfscreateopts) or $btrfscreateopts = "";
    my $createopts = $vol->{createopts};
    defined($createopts) or $createopts = "";
    my $pre_req = "";
    # creates the proper prerequisites for later command ordering
    foreach (@devs) {
      my $tmp = $_;
      $tmp =~ s/\d//;
      $pre_req = "${pre_req}pt_complete_${tmp}," unless ($pre_req =~ m/pt_complete_$tmp/);
    }
    # creates the BTRFS volume/RAID
    if ($raidlevel eq 'single') {
          &FAI::push_command("mkfs.btrfs -d single $createopts ". join(" ",@devs),
                             "$pre_req",
                             "btrfs_built_raid_$id");

        } else {
          &FAI::push_command("mkfs.btrfs -d raid$raidlevel $createopts ". join(" ",@devs),
                             "$pre_req",
                             "btrfs_built_raid_$id");
        }

    # initial mount, required to create the initial subvolume
    &FAI::push_command("mount $devs[0] /mnt",
                       "btrfs_built_raid_$id",
                       "btrfs_mounted_$id");

    # creating initial subvolume
    &FAI::push_command("btrfs subvolume create $btrfscreateopts  /mnt/$initial_subvolume",
                       "btrfs_mounted_$id",
                       "btrfs_created_$initial_subvolume");

    # unmounting the device itself
    &FAI::push_command("umount $devs[0]",
                       "btrfs_created_$initial_subvolume",
                       "");
    }
  }
}


################################################################################
#
# @brief Using the configurations from %FAI::configs, a list of commands is
# built to create any RAID devices
#
################################################################################
sub build_raid_commands {

  # check RAID arrays if there are pre-existing ones
  if (scalar(keys %FAI::current_raid_config))
  {
    &FAI::push_command("mdadm --stop --scan", "", "stop_for_assemble");
    &FAI::push_command("mdadm --assemble --scan --config=$FAI::DATADIR/mdadm-from-examine.conf",
      "stop_for_assemble", "mdadm_startall_examined");
  }
  foreach my $id (keys %FAI::current_raid_config) {
    my $md = "/dev/md$id";
    my $pre_deps_cl = "mdadm_startall_examined";
    $pre_deps_cl .= ",self_cleared_" .
      join(",self_cleared_", @{ $FAI::current_dev_children{$md} })
      if (defined($FAI::current_dev_children{$md}) &&
        scalar(@{ $FAI::current_dev_children{$md} }));
    &FAI::push_command( "mdadm -W --stop $md", "$pre_deps_cl", "self_cleared_$md");
  }

  foreach my $config (keys %FAI::configs) { # loop through all configs
    # no encrypted, tmpfs, LVM or physical devices here
    next if ($config eq "BTRFS" || $config eq "CRYPT" || $config eq "TMPFS" || $config =~ /^VG_./ || $config =~ /^PHY_./);
    ($config eq "RAID") or &FAI::internal_error("Invalid config $config");

    # create all raid devices
    foreach my $id (&numsort(keys %{ $FAI::configs{$config}{volumes} })) {

      # keep a reference to the current volume
      my $vol = (\%FAI::configs)->{$config}->{volumes}->{$id};

      # the list of RAID devices
      my @devs = keys %{ $vol->{devices} };
      my @eff_devs = ();
      my @spares = ();
      my $pre_req = "";

      # set proper partition types for RAID
      foreach my $d (@devs) {
        if ($vol->{devices}->{$d}->{missing}) {
          if ($vol->{devices}->{$d}->{spare}) {
            push @spares, "missing";
          } else {
            push @eff_devs, "missing";
          }
          # skip devices marked missing
          next;
        } else {
          if ($vol->{devices}->{$d}->{spare}) {
            push @spares, &FAI::enc_name($d);
          } else {
            push @eff_devs, &FAI::enc_name($d);
          }
        }

        $d = &FAI::enc_name($d);
        my ($i_p_d, $disk, $part_no) = &FAI::phys_dev($d);
        if ($vol->{preserve}) {
          $pre_req .= ($i_p_d && defined($FAI::configs{"PHY_$disk"})) ?
            ",pt_complete_$disk" :
            ",exist_$d";
        } elsif (&FAI::set_partition_flag_on_phys_dev($d, "raid")) {
          $pre_req .= defined($FAI::configs{"PHY_$disk"}) ?
            ",pt_complete_$disk" :
            ",exist_$d";
        } else {
          $pre_req .= ",exist_$d";
        }
      }

      # if it is a volume that has to be preserved, there is not much to be
      # done; its existance has been checked in propagate_and_check_preserve
      if ($vol->{preserve}) {
	$pre_req =~ s/^,//;
        # Assemble the array
        &FAI::push_command(
	    "mdadm --assemble /dev/md$id " . join(" ", grep(!/^missing$/, @eff_devs)),
	    "$pre_req", "exist_/dev/md$id");
        push(@preserved_raid, "/dev/md$id");

        # create the filesystem on the volume, if requested
        &FAI::build_mkfs_commands("/dev/md$id",
          \%{ $FAI::configs{$config}{volumes}{$id} })
          if (1 == $vol->{always_format});
        next;
      }

      # the desired RAID level
      my $level = $vol->{mode};

      # prepend "raid", if the mode is numeric-only
      $level = "raid$level" if ($level =~ /^\d+$/);

      my ($create_options) = $FAI::configs{$config}{volumes}{$id}{mdcreateopts};
      # prevent warnings of uninitialized variables
      $create_options = '' unless $create_options;
      print "/dev/md$id MD create_options: $create_options\n" if ($FAI::debug && $create_options);
      # create the command
      $pre_req = "exist_/dev/md" . ( $id - 1 ) . $pre_req if (0 != $id);
      $pre_req =~ s/^,//;
      &FAI::push_command(
        "yes | mdadm --create $create_options /dev/md$id --level=$level --force --run --raid-devices="
          . scalar(@eff_devs) . (scalar(@spares) !=0 ? " --spare-devices=" . scalar(@spares) : "") . " "
          . join(" ", @eff_devs) . " " . join(" ", @spares),
        "$pre_req", "exist_/dev/md$id" );

      # create the filesystem on the volume
      &FAI::build_mkfs_commands("/dev/md$id",
        \%{ $FAI::configs{$config}{volumes}{$id} });
    }
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
sub create_volume_group {

  my ($config) = @_;
  ($config =~ /^VG_(.+)$/) and ($1 ne "--ANY--") or &FAI::internal_error("Invalid config $config");
  my $vg = $1; # the actual volume group

  my ($pv_create_options) = $FAI::configs{$config}{pvcreateopts};
  my ($vg_create_options) = $FAI::configs{$config}{vgcreateopts};
  # prevent warnings of uninitialized variables
  $pv_create_options = '' unless $pv_create_options;
  $vg_create_options = '' unless $vg_create_options;
  print "/dev/$vg PV create_options: $pv_create_options\n" if ($FAI::debug && $pv_create_options);
  print "/dev/$vg VG create_options: $vg_create_options\n" if ($FAI::debug && $vg_create_options);

  # create the volume group, if it doesn't exist already
  if (!defined($FAI::configs{"VG_$vg"}{exists})) {
    my $pre_dev = "";
    my $devs = "";
    # create all the devices
    foreach my $d (keys %{ $FAI::configs{$config}{devices} }) {
      $d = &FAI::enc_name($d);
      my $pre = "exist_$d";
      my ($i_p_d, $disk, $part_no) = &FAI::phys_dev($d);
      $pre .= ",pt_complete_$disk"
        if (&FAI::set_partition_flag_on_phys_dev($d, "lvm") &&
          defined($FAI::configs{"PHY_$disk"}));

      &FAI::push_command( "pvcreate -ff -y $pv_create_options $d",
        "$pre", "pv_done_$d");
      $devs .= " $d";
      $pre_dev .= ",pv_done_$d";
    }
    $pre_dev =~ s/^,//;

    # create the volume group
    &FAI::push_command( "vgcreate $vg_create_options $vg $devs",
      "$pre_dev", "vg_created_$vg" );

    # we are done
    return;
  }

  # otherwise add or remove the devices for the volume group, run pvcreate
  # where needed
  # the devices to be removed later on
  my %rm_devs = ();
  @rm_devs{ @{ $FAI::current_lvm_config{$vg}{"physical_volumes"} } } = ();

  # all devices of this VG
  my @all_devices = ();

  # the list of devices to be created
  my @new_devices = ();

  # create an undefined entry for each device
  my $pre_dev = "vg_exists_$vg";
  foreach my $d (keys %{ $FAI::configs{$config}{devices} }) {
    my $denc = &FAI::enc_name($d);
    push @all_devices, $denc;
    if (exists($rm_devs{$denc})) {
      my ($i_p_d, $disk, $part_no) = &FAI::phys_dev($denc);
      $pre_dev .= ($i_p_d && defined($FAI::configs{"PHY_$disk"})) ?
        ",pt_complete_$disk" : ",exist_$denc";
    } else {
      push @new_devices, $denc;
    }
  }

  # remove remaining devices from the list
  delete $rm_devs{$_} foreach (@all_devices);

  # create all the devices
  foreach my $dev (@new_devices) {
    my $pre = "exist_$dev";
    my ($i_p_d, $disk, $part_no) = &FAI::phys_dev($dev);
    $pre .= ",pt_complete_$disk"
      if (&FAI::set_partition_flag_on_phys_dev($dev, "lvm") &&
        defined($FAI::configs{"PHY_$disk"}));

    &FAI::push_command( "pvcreate -ff -y $pv_create_options $dev",
      "$pre", "pv_done_$dev");
    $pre_dev .= ",pv_done_$dev";
  }
  $pre_dev =~ s/^,//;


  # extend the volume group by the new devices
  if (scalar (@new_devices)) {
    &FAI::push_command( "vgextend $vg " . join (" ", @new_devices), "$pre_dev",
      "vg_extended_$vg" );
  } else {
    &FAI::push_command( "true", "self_cleared_VG_$vg,$pre_dev", "vg_extended_$vg" );
  }

  # run vgreduce to get them removed
  if (scalar (keys %rm_devs)) {
    $pre_dev = "";
    $pre_dev .= ",exist_$_" foreach (keys %rm_devs);
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

  # now create or resize the configured logical volumes
  foreach my $lv (@{ $FAI::configs{$config}{ordered_lv_list} }) {
    # reference to the size of the current logical volume
    my $lv_size = (\%FAI::configs)->{$config}->{volumes}->{$lv}->{size};
    # skip preserved partitions, but ensure that they exist
    if ($lv_size->{preserve}) {
      defined ($FAI::current_lvm_config{$vg}{volumes}{$lv})
        or die "Preserved volume $vg/$lv does not exist\n";
      warn "$vg/$lv will be preserved\n";
      # create the filesystem on the volume, if requested
      &FAI::build_mkfs_commands("/dev/$vg/$lv",
        \%{ $FAI::configs{$config}{volumes}{$lv} })
        if (1 == $lv_size->{always_format});
      next;
    }

    # resize the volume
    if ($lv_size->{resize}) {
      defined ($FAI::current_lvm_config{$vg}{volumes}{$lv})
        or die "Resized volume $vg/$lv does not exist\n";
      warn "$vg/$lv will be resized\n";

      use POSIX qw(floor);

      my $lvsize_mib = &FAI::convert_unit($lv_size->{eff_size} . "B");
      if ($lvsize_mib < $FAI::current_lvm_config{$vg}{volumes}{$lv}{size})
      {
        if (($FAI::configs{$config}{volumes}{$lv}{filesystem} =~
            /^ext[23]$/) && &FAI::in_path("resize2fs")) {
          my $block_count = POSIX::floor($lv_size->{eff_size} / 512);
          &FAI::push_command( "e2fsck -p -f /dev/$vg/$lv",
            "vg_enabled_$vg,exist_/dev/$vg/$lv", "e2fsck_f_resize_$vg/$lv" );
          &FAI::push_command( "resize2fs /dev/$vg/$lv ${block_count}s",
            "e2fsck_f_resize_$vg/$lv", "lv_shrink_$vg/$lv" );
        } else {
          &FAI::push_command( "parted -s /dev/$vg/$lv resize 1 0 " . $lv_size->{eff_size} .  "B",
            "vg_enabled_$vg", "lv_shrink_$vg/$lv" );
        }
        &FAI::push_command( "lvresize -L $lvsize_mib $vg/$lv",
          "vg_enabled_$vg,lv_shrink_$vg/$lv", "lv_created_$vg/$lv" );
      } else {
        &FAI::push_command( "lvresize -L $lvsize_mib $vg/$lv",
          "vg_enabled_$vg,exist_/dev/$vg/$lv", "lv_grow_$vg/$lv" );
        if (($FAI::configs{$config}{volumes}{$lv}{filesystem} =~
            /^ext[23]$/) && &FAI::in_path("resize2fs")) {
          my $block_count = POSIX::floor($lv_size->{eff_size} / 512);
          &FAI::push_command( "e2fsck -p -f /dev/$vg/$lv",
            "vg_enabled_$vg,lv_grow_$vg/$lv", "e2fsck_f_resize_$vg/$lv" );
          &FAI::push_command( "resize2fs /dev/$vg/$lv ${block_count}s",
            "e2fsck_f_resize_$vg/$lv", "exist_/dev/$vg/$lv" );
        } else {
          &FAI::push_command( "parted -s /dev/$vg/$lv resize 1 0 " . $lv_size->{eff_size} .  "B",
            "vg_enabled_$vg,lv_grow_$vg/$lv", "exist_/dev/$vg/$lv" );
        }
      }

      # create the filesystem on the volume, if requested
      &FAI::build_mkfs_commands("/dev/$vg/$lv",
        \%{ $FAI::configs{$config}{volumes}{$lv} })
        if (1 == $lv_size->{always_format});
      next;
    }

    my ($create_options) = $FAI::configs{$config}{volumes}{$lv}{lvcreateopts};
    # prevent warnings of uninitialized variables
    $create_options = '' unless $create_options;
    print "/dev/$vg/$lv LV create_options: $create_options\n" if ($FAI::debug && $create_options);
    # create a new volume
    &FAI::push_command( "lvcreate $create_options -n $lv -L " .
      &FAI::convert_unit($lv_size->{eff_size} . "B") . " $vg", "vg_enabled_$vg",
      "exist_/dev/$vg/$lv" );

    # create the filesystem on the volume
    &FAI::build_mkfs_commands("/dev/$vg/$lv",
      \%{ $FAI::configs{$config}{volumes}{$lv} });
  }
}

################################################################################
#
# @brief Remove existing volume group if underlying devices will be modified,
# otherwise add proper exist_ preconditions
#
################################################################################
sub cleanup_vg {

  my ($vg) = @_;
  my $clear_vg = 0;

  foreach my $dev (@{ $FAI::current_lvm_config{$vg}{"physical_volumes"} }) {
    my ($i_p_d, $disk, $part_no) = &FAI::phys_dev($dev);
    if ($i_p_d) {
      defined ($FAI::configs{"PHY_$disk"}) or next;
      defined ($FAI::configs{"PHY_$disk"}{partitions}{$part_no}) and
        ($FAI::configs{"PHY_$disk"}{partitions}{$part_no}{size}{preserve}) and
        next;
    } elsif ($dev =~ m{^/dev/md[\/]?(\d+)$}) {
      my $vol = $1;
      defined ($FAI::configs{RAID}) or next;
      defined ($FAI::configs{RAID}{volumes}{$vol}) or next;
      next if (1 == $FAI::configs{RAID}{volumes}{$vol}{preserve});
    } elsif ($dev =~ m{^/dev/([^/\s]+)/([^/\s]+)$}) {
      my $ivg = $1;
      my $lv = $2;
      defined($FAI::configs{"VG_$ivg"}) or next;
      defined($FAI::configs{"VG_$ivg"}{volumes}{$lv}) or next;
      next if (1 == $FAI::configs{"VG_$ivg"}{volumes}{$lv}{size}{preserve});
    } else {
      warn "Don't know how to check preservation of $dev\n";
      next;
    }
    $clear_vg = 1;
    last;
  }
  #following block responsible for lv/vg preservation
  if (0 == $clear_vg) {
    my $vg_setup_pre = "vgchange_a_n_VG_$vg";
    if (defined($FAI::configs{"VG_$vg"})) {
      $FAI::configs{"VG_$vg"}{exists} = 1;

      # remove all volumes that do not exist anymore or need not be preserved
      foreach my $lv (keys %{ $FAI::current_lvm_config{$vg}{volumes} }) {
        my $pre_deps_cl = "";
        $pre_deps_cl = "self_cleared_" .
          join(",self_cleared_", @{ $FAI::current_dev_children{"/dev/$vg/$lv"} })
            if (defined($FAI::current_dev_children{"/dev/$vg/$lv"}) &&
              scalar(@{ $FAI::current_dev_children{"/dev/$vg/$lv"} }));
        # skip preserved/resized volumes
        if (defined ( $FAI::configs{"VG_$vg"}{volumes}{$lv})) {
          if ($FAI::configs{"VG_$vg"}{volumes}{$lv}{size}{preserve} == 1 ||
            $FAI::configs{"VG_$vg"}{volumes}{$lv}{size}{resize} == 1) {
            &FAI::push_command("true", "vgchange_a_n_VG_$vg,$pre_deps_cl",
              "exist_/dev/$vg/$lv,self_cleared_/dev/$vg/$lv");
            next;
          }
        }

        &FAI::push_command( "vgchange -a y $vg",
          "",
          "pre_wipe_$vg");
        &FAI::push_command( "wipefs -a /dev/$vg/$lv",
          "pre_wipe_$vg,$pre_deps_cl",
          "wipefs_$vg/$lv");
        &FAI::push_command( "lvremove -f /dev/$vg/$lv",
          "wipefs_$vg/$lv",
          "lv_rm_$vg/$lv,self_cleared_/dev/$vg/$lv");
        $vg_setup_pre .= ",lv_rm_$vg/$lv";
      }
    } else {
      &FAI::push_command("true", "vgchange_a_n_VG_$vg",
        "exist_/dev/$vg/$_,self_cleared_/dev/$vg/$_") foreach
        (keys %{ $FAI::current_lvm_config{$vg}{volumes} });
    }
    &FAI::push_command("true", $vg_setup_pre, "vg_exists_$vg");
    &FAI::push_command( "vgchange -a n $vg",
      "",
      "$vg_setup_pre");
    return 0;
  }

  my $vg_destroy_pre = "vgchange_a_n_VG_$vg";
  foreach my $lv (keys %{ $FAI::current_lvm_config{$vg}{volumes} }) {
    my $pre_deps_cl = "";
    $pre_deps_cl = "self_cleared_" .
      join(",self_cleared_", @{ $FAI::current_dev_children{"/dev/$vg/$lv"} })
        if (defined($FAI::current_dev_children{"/dev/$vg/$lv"}) &&
          scalar(@{ $FAI::current_dev_children{"/dev/$vg/$lv"} }));

    &FAI::push_command( "vgchange -a y $vg",
      "",
      "pre_wipe_$vg");
    &FAI::push_command( "wipefs -a /dev/$vg/$lv",
      "pre_wipe_$vg,$pre_deps_cl",
      "wipefs_$vg/$lv");
    &FAI::push_command( "lvremove -f /dev/$vg/$lv",
      "wipefs_$vg/$lv",
      "lv_rm_$vg/$lv,self_cleared_/dev/$vg/$lv");
    $vg_destroy_pre .= ",lv_rm_$vg/$lv";
  }
  &FAI::push_command( "vgremove $vg", "$vg_destroy_pre", "vg_removed_$vg");

  # clear all the devices
  my $devices = "";
  $devices .= " " . &FAI::enc_name($_) foreach
    (@{ $FAI::current_lvm_config{$vg}{physical_volumes} });
  ($devices =~ /^\s*$/) and &FAI::internal_error("Empty PV device set");
  $FAI::debug and print "Erased devices:$devices\n";
  &FAI::push_command( "pvremove $devices", "vg_removed_$vg", "pvremove_$vg");
  my $post_wipe = "pvremove_$vg";
  foreach my $d (split (" ", $devices)) {
    $post_wipe .= ",pv_sigs_removed_wipe_${d}_$vg";
    &FAI::push_command( "wipefs -a $d", "pvremove_$vg", "pv_sigs_removed_wipe_${d}_$vg");
  }
  &FAI::push_command( "true", $post_wipe, "pv_sigs_removed_$vg" );
  return 1;
}

################################################################################
#
# @brief Using the configurations from %FAI::configs, a list of commands is
# built to setup the LVM
# creates the volume groups, the logical volumes and the filesystems
#
################################################################################
sub build_lvm_commands {

  # disable volumes if there are pre-existing ones
  foreach my $d (keys %FAI::current_dev_children) {
    next unless ($d =~ /^VG_(.+)$/);
    my $vg = $1;
    my $vg_pre = "vgchange_a_n_VG_$vg";
    my $pre_deps_vgc = "";
    my $preserved = 0;

    $pre_deps_vgc = ",self_cleared_" .
     join(",self_cleared_", @{ $FAI::current_dev_children{$d} })
     if (defined($FAI::current_dev_children{$d}) &&
       scalar(@{ $FAI::current_dev_children{$d} }));
    $pre_deps_vgc =~ s/^,//;

    foreach my $raid (@preserved_raid) {
      my $tmp_vg = `pvdisplay $raid | grep "VG Name"`;
      chomp $tmp_vg;
      $tmp_vg = $1 if $tmp_vg =~ /(\S+)$/;
      $preserved = 1 if ($tmp_vg eq $vg);
    }
    &FAI::push_command("vgchange -a n $vg", "$pre_deps_vgc", $vg_pre)
      unless $preserved;

    $vg_pre .= ",pv_sigs_removed_$vg" if (&FAI::cleanup_vg($vg));
    my $pre_deps_cl = "";
    $pre_deps_cl = ",self_cleared_" .
      join(",self_cleared_", @{ $FAI::current_dev_children{$d} })
      if (scalar(@{ $FAI::current_dev_children{$d} }));
    &FAI::push_command("true", "$vg_pre$pre_deps_cl", "self_cleared_VG_$vg");
  }

  # loop through all configs
  foreach my $config (keys %FAI::configs) {

    # no physical devices, RAID, encrypted or tmpfs here
    next if ($config eq "BTRFS" || $config =~ /^PHY_./ || $config eq "RAID" || $config eq "CRYPT" || $config eq "TMPFS");
    ($config =~ /^VG_(.+)$/) or &FAI::internal_error("Invalid config $config");
    next if ($1 eq "--ANY--");
    my $vg = $1; # the volume group

    # create the volume group or add/remove devices
    &FAI::create_volume_group($config);
    # enable the volume group
    &FAI::push_command( "vgchange -a y $vg",
      "vg_created_$vg", "vg_enabled_$vg" );

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

    # build a parted command to create the partition
    my $dn = &FAI::make_device_name($disk, $part_nr);
    &FAI::push_command( "parted -s $disk mkpart $part_type \"$fs\" ${start}B ${end}B",
      "cleared1_$disk", "prep1_$dn" );
    my $post = "exist_$dn";
    $post .= ",rebuilt_$dn" if
      $FAI::configs{$config}{partitions}{$part_id}{size}{resize};
    my $cmd = "true";
    $cmd = "losetup -o $start $dn $disk" if ((&FAI::loopback_dev($disk))[0]);
    &FAI::push_command($cmd, "prep1_$dn", $post);
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
  # resize needed?
  my $needs_resize = 0;
  foreach my $part_id (@to_preserve) {
    $needs_resize = 1 if ($FAI::configs{$config}{partitions}{$part_id}{size}{resize});
    last if ($needs_resize);
  }

  my $label = $FAI::configs{$config}{disklabel};
  $label = "gpt" if ($label eq "gpt-bios");
  # A new disk label may only be written if no partitions need to be
  # preserved
  (($label eq $FAI::current_config{$disk}{disklabel})
    || (scalar (@to_preserve) == 0))
    or die "Can't change disklabel, partitions are to be preserved\n";

  # write the disklabel to drop the previous partition table
  my $pre_deps = "";
  foreach my $c (@{ $FAI::current_dev_children{$disk} }) {
    $pre_deps .= ",self_cleared_" .
    join(",self_cleared_", @{ $FAI::current_dev_children{$c} })
    if (defined($FAI::current_dev_children{$c}) &&
      scalar(@{ $FAI::current_dev_children{$c} }));
    my ($i_p_d, $d, $part_no) = &FAI::phys_dev($c);
    ($i_p_d && $d eq $disk) or &FAI::internal_error("Invalid dev children entry");
    my $wipe_cmd = "wipefs -a $c";
    foreach my $part_id (@to_preserve) {
      # get the existing id
      my $mapped_id = $FAI::configs{$config}{partitions}{$part_id}{maps_to_existing};
      $wipe_cmd = "true" if ($mapped_id == $part_no);
    }
    $wipe_cmd = "true" if
      ($FAI::current_config{$disk}{partitions}{$part_no}{is_extended});
    &FAI::push_command($wipe_cmd, "exist_$disk$pre_deps", "wipefs_$c");
    $pre_deps .= ",wipefs_$c";
  }
  &FAI::push_command( ($needs_resize ? "parted -s $disk mklabel $label" : "true"),
    "exist_$disk$pre_deps", "cleared1_$disk" );

  &FAI::rebuild_preserved_partitions($config, \@to_preserve) if ($needs_resize);

  my $pre_all_resize = "";

  # resize partitions while checking for dependencies
  foreach my $part_id (reverse &numsort(@to_preserve)) {
    # reference to the current partition
    my $part = (\%FAI::configs)->{$config}->{partitions}->{$part_id};
    # get the existing id
    my $mapped_id = $part->{maps_to_existing};
    # get the intermediate partition id; only available if
    # rebuild_preserved_partitions was done
    my $p = undef;
    if ($needs_resize) {
      $p = $FAI::current_config{$disk}{partitions}{$mapped_id}{new_id};
      # anything to be done?
      $pre_all_resize .= ",exist_" . &FAI::make_device_name($disk, $p) unless
        $part->{size}->{resize};
    }
    if ($part->{size}->{resize}) {
      warn &FAI::make_device_name($disk, $mapped_id) . " will be resized\n";
    } else {
      warn &FAI::make_device_name($disk, $mapped_id) . " will be preserved\n";
      next;
    }

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

    # ntfs/ext2,3 partition can't be moved
    ($start == $FAI::current_config{$disk}{partitions}{$mapped_id}{begin_byte})
      or &FAI::internal_error(
        $FAI::current_config{$disk}{partitions}{$mapped_id}{filesystem}
          . " partition start supposed to move, which is not allowed") if
      ($FAI::current_config{$disk}{partitions}{$mapped_id}{filesystem} =~
        /^(ntfs|ext[23])$/);

    # build an appropriate command
    # ntfs requires specific care
    if ($FAI::current_config{$disk}{partitions}{$mapped_id}{filesystem} eq
      "ntfs") {
      # check, whether ntfsresize is available
      &FAI::in_path("ntfsresize") or die "ntfsresize not found in PATH\n";

      &FAI::push_command( "yes | ntfsresize -s " . $part->{size}->{eff_size} . " " .
        &FAI::make_device_name($disk, $p), "rebuilt_" .
        &FAI::make_device_name($disk, $p) . $deps, "ntfs_ready_for_rm_" .
        &FAI::make_device_name($disk, $p) );
      # TODO this is just a hack, we would really need support for resize
      # without data resize in parted, which will be added in some parted
      # version > 2.1
      &FAI::push_command( "parted -s $disk rm $p", "ntfs_ready_for_rm_" .
        &FAI::make_device_name($disk, $p), "resized_" .
        &FAI::make_device_name($disk, $p) );
    ## } elsif (($FAI::current_config{$disk}{partitions}{$mapped_id}{filesystem} =~
    ##     /^ext[23]$/) && &FAI::in_path("resize2fs")) {
    ##   TODO: BROKEN needs more checks, enlarge partition table before resize, just as
    ##   NTFS case
    ##   my $block_count = $part->{size}->{eff_size} / 512;
    ##   &FAI::push_command( "e2fsck -p -f " . &FAI::make_device_name($disk, $p),
    ##     "rebuilt_" . &FAI::make_device_name($disk, $p) . $deps,
    ##     "e2fsck_f_resize_" .  &FAI::make_device_name($disk, $p) );
    ##   &FAI::push_command( "resize2fs " . &FAI::make_device_name($disk, $p) .
    ##     " ${block_count}s", "e2fsck_f_resize_" . &FAI::make_device_name($disk, $p),
    ##     "resized_" .  &FAI::make_device_name($disk, $p) );
    } else {
      &FAI::push_command( "parted -s $disk resize $p ${start}B ${end}B",
        "rebuilt_" . &FAI::make_device_name($disk, $p) . $deps, "resized_" .
        &FAI::make_device_name($disk, $p) );
    }

  }

  # write the disklabel again to drop the partition table and create a new one
  # that has the proper ids
  &FAI::push_command( "parted -s $disk mklabel $label",
    "cleared1_$disk$pre_all_resize", "cleared2_$disk" );

  my $boot_disk;
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

    # if /boot exists, set $boot_disk
    if (defined $part->{mountpoint} && $part->{mountpoint} eq "/boot") {
      $boot_disk=$disk;
    }

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

    my $fs = (defined($part->{filesystem}) && $part->{filesystem} =~ /\S+/) ?
      $part->{filesystem} : "-";
    ($fs) = split(/:/, $fs);
    $fs = "linux-swap" if ($fs eq "swap");
    $fs = "fat32" if ($fs eq "vfat");
    $fs = "fat16" if ($fs eq "msdos");
    $fs = "ext3" if ($fs eq "ext4");
    $fs = "" if ($fs =~ m/.*_journal$/);
    $fs = $FAI::current_config{$disk}{partitions}{$mapped_id}{filesystem}
      if ($part->{size}->{preserve} || $part->{size}->{resize});
    $fs = "" if ($fs eq "-");

    my $pre = "cleared2_$disk";
    $pre .= ",exist_" . &FAI::make_device_name($disk, $prev_id) if ($prev_id > -1);
    # build a parted command to create the partition
    my $dn = &FAI::make_device_name($disk, $part_id);
    &FAI::push_command( "parted -s $disk mkpart $part_type \"$fs\" ${start}B ${end}B",
      $pre, "prep2_$dn");
    my $cmd = "true";
    $cmd = "losetup -o $start $dn $disk" if ((&FAI::loopback_dev($disk))[0]);
    &FAI::push_command($cmd, "prep2_$dn", "exist_$dn");

    # (re-)set all flags
    my $flags = "";
    $flags = $FAI::current_config{$disk}{partitions}{$mapped_id}{flags}
      if ($part->{size}->{preserve} || $part->{size}->{resize});
    # set the bootable flag, if requested at all
    $flags .= ",boot" if($FAI::configs{$config}{bootable} == $part_id);
    # set the bios_grub flag on BIOS compatible GPT tables
    $flags .= ",bios_grub" if($FAI::configs{$config}{disklabel} eq "gpt-bios"
      && $FAI::configs{$config}{gpt_bios_part} == $part_id);
	  $flags =~ s/^,//;
    &FAI::set_partition_flag_on_phys_dev($dn, $_)
      foreach (split(',', $flags));

    $prev_id = $part_id;
  }

  &FAI::push_command("echo ,,,* | sfdisk --force $boot_disk -N1",
    "pt_complete_$disk", "gpt_bios_fake_bootable")
    if($FAI::configs{$config}{disklabel} eq "gpt-bios" and $boot_disk);

  ($prev_id > -1) or &FAI::internal_error("No partitions created");
  $partition_table_deps{$disk} = "cleared2_$disk,exist_"
    . &FAI::make_device_name($disk, $prev_id);
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
    # no RAID, encrypted, tmpfs or LVM devices here
    next if ($config eq "BTRFS" || $config eq "RAID" || $config eq "CRYPT" || $config eq "TMPFS" || $config =~ /^VG_./);
    ($config =~ /^PHY_(.+)$/) or &FAI::internal_error("Invalid config $config");
    my $disk = $1; # the device to be configured

    if ($FAI::configs{$config}{virtual}) {
      foreach my $part_id (&numsort(keys %{ $FAI::configs{$config}{partitions} })) {
        # virtual disks always exist
        &FAI::push_command( "true", "",
          "exist_" . &FAI::make_device_name($disk, $part_id) );
        # no partition table operations
        $partition_table_deps{$disk} = "";
      }
    } elsif (defined($FAI::configs{$config}{partitions}{0})) {
      # no partition table operations
      $partition_table_deps{$disk} = "";
   } elsif (defined($FAI::configs{$config}{opts_all}{preserve})) {
     foreach my $part_id (&numsort(keys %{ $FAI::configs{$config}{partitions} })) {
       # all partitions exist
       &FAI::push_command( "true", "",
         "exist_" . &FAI::make_device_name($disk, $part_id) );
       # no partition table operations
       $partition_table_deps{$disk} = "";
     }
     # no changes on this disk
     $partition_table_deps{$disk} = "";
    } else {
      # create partitions on non-virtual configs
      &FAI::setup_partitions($config);
    }

    # generate the commands for creating all filesystems
    foreach my $part_id (&numsort(keys %{ $FAI::configs{$config}{partitions} })) {
      # reference to the current partition
      my $part = (\%FAI::configs)->{$config}->{partitions}->{$part_id};

      # skip preserved/resized/extended partitions
      next if (($part->{size}->{always_format} == 0 &&
          ($part->{size}->{preserve} == 1 || $part->{size}->{resize} == 1))
        || $part->{size}->{extended} == 1);

      # create the filesystem on the device
      &FAI::build_mkfs_commands( 0 == $part_id ? $disk : &FAI::make_device_name($disk, $part_id), $part );
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
      &FAI::execute_command("parted -s $disk mkpart $part_type \"$fs\" ${start}B ${end}B");

      # re-set all flags
      &FAI::execute_command("parted -s $disk set $part_id $_ on")
        foreach (split(',', $curr_part->{flags}));
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
  # first add partition-table-is-complete
  &FAI::push_command("true", $partition_table_deps{$_}, "pt_complete_$_")
    foreach (keys %partition_table_deps);

  my @pre_deps = ();
  my $i = 1;
  my $pushed = -1;

  while ($i < $FAI::n_c_i) {
    if ($FAI::debug) {
      print "Trying to add CMD: " . $FAI::commands{$i}{cmd} . "\n";
      defined($FAI::commands{$i}{pre}) and print "PRE: " .  $FAI::commands{$i}{pre} . "\n";
      defined($FAI::commands{$i}{post}) and print "POST: " .  $FAI::commands{$i}{post} . "\n";
    }
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

