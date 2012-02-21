#!/usr/bin/perl
package FAI;

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
use warnings FATAL => qw(uninitialized);

use base 'Exporter';

our @EXPORT = qw(in_path run_parser check_config get_current_disks get_current_lvm get_current_raid propagate_and_check_preserve compute_partition_sizes compute_lv_sizes build_disk_commands build_raid_commands build_lvm_commands build_cryptsetup_commands order_commands  internal_error execute_command generate_fstab $debug $DATADIR $VERSION $no_dry_run $check_only @disks %configs $udev_settle %dev_children %current_config %current_lvm_config %commands $n_c_i %disk_var @crypttab %current_raid_config %current_dev_children);

our $VERSION = "1.3";

################################################################################
#
# @file init.pm
#
# @brief Initialize all variables and acquire the set of disks of the system.
#
# The layout of the data structures is documented in the wiki:
# http://wiki.fai-project.org/index.php/Setup-storage
#
# $Id$
#
# @author Christian Kern, Michael Tautschnig
# @date Sun Jul 23 16:09:36 CEST 2006
#
################################################################################

################################################################################
#
# @brief Enable debugging by setting $debug to a value greater than 0
#
################################################################################
our $debug = 0;
defined ($ENV{debug}) and $debug = $ENV{debug};

################################################################################
#
# @brief Directory to store generated files such as fstab, crypttab
#
################################################################################
our $DATADIR = "/tmp/fai";
defined ($ENV{LOGDIR}) and $DATADIR = $ENV{LOGDIR};

################################################################################
#
# @brief Write changes to disk only if set to 1
#
################################################################################
our $no_dry_run = 0;

################################################################################
#
# @brief Perform syntactic checks only if set to 1
#
################################################################################
our $check_only = 0;

################################################################################
#
# @brief The command to tell udev to settle (udevsettle or udevadm settle)
#
################################################################################
our $udev_settle = undef;

################################################################################
#
# @brief The lists of disks of the system
#
################################################################################
our @disks = ();

################################################################################
#
# @brief The variables later written to disk_var.sh
#
################################################################################
our %disk_var = ();
$disk_var{SWAPLIST} = "";
$disk_var{BOOT_DEVICE} = "";

################################################################################
#
# @brief The contents later written to crypttab, if any
#
################################################################################
our @crypttab = ();

################################################################################
#
# @brief A flag to tell our script that the system is not installed for the
# first time
#
################################################################################
our $reinstall = 1;
defined( $ENV{flag_initial} ) and $reinstall = 0;

################################################################################
#
# @brief The hash of all configurations specified in the disk_config file
#
################################################################################
our %configs = ();

################################################################################
#
# @brief The current disk configuration
#
################################################################################
our %current_config = ();

################################################################################
#
# @brief The current LVM configuration
#
################################################################################
our %current_lvm_config = ();

################################################################################
#
# @brief The current RAID configuration
#
################################################################################
our %current_raid_config = ();

################################################################################
#
# @brief The commands to be executed
#
################################################################################
our %commands = ();

################################################################################
#
# @brief Each command is associated with a unique id -- this one aids in
# counting (next_command_index)
#
################################################################################
our $n_c_i = 1;

################################################################################
#
# @brief Device alias names
#
################################################################################
our %dev_alias = ();

################################################################################
#
# @brief Dependencies to be fulfilled before a disk is ready for use
#
################################################################################
our %partition_table_deps = ();

################################################################################
#
# @brief Map from devices to volumes stacked on top of them
#
################################################################################
our %dev_children = ();
our %current_dev_children = ();


my $partition_pointer;
my $partition_pointer_dev_name;

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

  $commands{$n_c_i} = {
    cmd => $cmd,
    pre => $pre,
    post => $post
  };
  $n_c_i++;
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
  if ($dev =~ m{^/dev/(i2o/hd[a-z]|sd[a-z]{1,2}|hd[a-z]|vd[a-z]|xvd[a-z])(\d+)?$})
  {
    defined($2) or return (1, "/dev/$1", -1);
    return (1, "/dev/$1", $2);
  }
  elsif ($dev =~
    m{^/dev/(cciss/c\dd\d|ida/c\dd\d|rd/c\dd\d|ataraid/d\d|etherd/e\d+\.\d+)(p(\d+))?$})
  {
    defined($2) or return (1, "/dev/$1", -1);
    return (1, "/dev/$1", $3);
  }
  elsif ((&loopback_dev($dev))[0])
  {
    # we can't tell whether this is a disk of its own or a partition
    return (1, $dev, -1);
  }
  return (0, "", -2);
}

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
  my ($i_p_d, $disk, $part_no) = &phys_dev($dev);
  if ($i_p_d) {
    defined ($configs{"PHY_$disk"}) or return $dev;
    defined ($configs{"PHY_$disk"}{partitions}{$part_no}) or return $dev;
    return $dev unless
      ($configs{"PHY_$disk"}{partitions}{$part_no}{encrypt});
  } elsif ($dev =~ /^\/dev\/md(\d+)$/) {
    defined ($configs{RAID}) or return $dev;
    defined ($configs{RAID}{volumes}{$1}) or return $dev;
    return $dev unless ($configs{RAID}{volumes}{$1}{encrypt});
  } elsif ($dev =~ /^\/dev\/([^\/]+)\/([^\/]+)$/) {
    defined ($configs{"VG_$1"}) or return $dev;
    defined ($configs{"VG_$1"}{volumes}{$2}) or return $dev;
    return $dev unless ($configs{"VG_$1"}{volumes}{$2}{encrypt});
  } else {
    return $dev;
  }

  &mark_encrypted($dev);

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
    m{^/dev/(cciss/c\dd\d|ida/c\dd\d|rd/c\dd\d|ataraid/d\d|etherd/e\d+\.\d+)$});
  if ((&loopback_dev($dev))[0])
  {
    $p += (&loopback_dev($dev))[1];
    $dev = "/dev/loop"
  }
  $dev .= $p;
  internal_error("Invalid device $dev") unless (&phys_dev($dev))[0];
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


################################################################################
#
# @FILE commands.pm
#
# @brief Build the required commands in @commands using the config stored
# in %configs
#
# $Id$
#
# @author Christian Kern, Michael Tautschnig, Sebastian Hetze, Andreas Schuldei
# @date Sun Jul 23 16:09:36 CEST 2006
#
################################################################################



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

  # check for old-style encryption requests
  &handle_oldstyle_encrypt_device($device, $partition);

  defined ($partition->{filesystem})
    or &internal_error("filesystem is undefined");
  my $fs = $partition->{filesystem};
  my $journal = $partition->{journal_dev};

  return if ($fs eq "-");

  my ($create_options) = $partition->{createopts};
  my ($tune_options)   = $partition->{tuneopts};
  # prevent warnings of uninitialized variables
  $create_options = '' unless $create_options;
  $tune_options   = '' unless $tune_options;

  print "$partition->{mountpoint} FS create_options: $create_options\n" if ($debug && $create_options);
  print "$partition->{mountpoint} FS tune_options: $tune_options\n" if ($debug && $tune_options);

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
	  &internal_error("unsupported journal type $fs");
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

  &push_command( "$create_tool $create_options $device", $prereqs, $provides);

  # possibly tune the file system - this depends on whether the file system
  # supports tuning at all
  return unless $tune_options;
  my $tune_tool;
  ($fs eq "ext2" || $fs eq "ext3" || $fs eq "ext4") and $tune_tool = "tune2fs";
  ($fs eq "reiserfs") and $tune_tool = "reiserfstune";
  die "Don't know how to tune $fs\n" unless $tune_tool;

  # add the tune command
  &push_command( "$tune_tool $tune_options $device", "has_fs_$device",
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

  if (!defined($configs{CRYPT}{randinit})) {
    $configs{CRYPT}{fstabkey} = "device";
    $configs{CRYPT}{randinit} = 0;
    $configs{CRYPT}{volumes} = {};
  }

  $configs{CRYPT}{randinit} = 1 if ($partition->{encrypt} > 1);

  my $vol_id = scalar(keys %{ $configs{CRYPT}{volumes} });
  $configs{CRYPT}{volumes}{$vol_id} = {
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
  my ($i_p_d, $disk, $part_no) = &phys_dev($d);
  return 0 unless $i_p_d;
  # make sure this device really exists (we can't check for the partition
  # as that may be created later on
  (-b $disk) or die "Specified disk $disk does not exist in this system!\n";
  # set the raid/lvm unless this is an entire disk flag or a virtual disk
  return 0 if ($part_no == -1 ||
    (defined($configs{"PHY_$disk"}) && $configs{"PHY_$disk"}{virtual}));
  my $pre = "exist_$d";
  $pre .= ",cleared2_$disk" if (defined($configs{"PHY_$disk"}));
  &push_command( "parted -s $disk set $part_no $t on", $pre, "flag_${t}_$d" );
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
# @brief Using the configurations from %configs, a list of commands is
# built to create any encrypted devices
#
################################################################################
sub build_cryptsetup_commands {
  foreach my $config (keys %configs) { # loop through all configs
    # no LVM or physical devices here
    next if ($config ne "CRYPT");

    # create all encrypted devices
    foreach my $id (&numsort(keys %{ $configs{$config}{volumes} })) {

      # keep a reference to the current volume
      my $vol = (\%configs)->{$config}->{volumes}->{$id};
      # the desired encryption mode
      my $mode = $vol->{mode};

      warn "cryptsetup support is incomplete - preserve is not supported\n"
        if ($vol->{preserve});

      # rewrite the device name
      my $real_dev = $vol->{device};
      my $enc_dev_name = &enc_name($real_dev);
      my $enc_dev_short_name = $enc_dev_name;
      $enc_dev_short_name =~ s#^/dev/mapper/##;

      my $pre_dep = "exist_$real_dev";

      if ($configs{$config}{randinit}) {
        # ignore exit 1 caused by reaching the end of $real_dev
        &push_command(
          "dd if=/dev/urandom of=$real_dev || true",
          $pre_dep, "random_init_$real_dev");
        $pre_dep = "random_init_$real_dev";
      }

      if ($mode =~ /^luks(:"([^"]+)")?$/) {
        my $keyfile = "$DATADIR/$enc_dev_short_name";

        # generate a key for encryption
        &push_command(
          "head -c 2048 /dev/urandom | head -n 47 | tail -n 46 | od | tee $keyfile",
          "", "keyfile_$real_dev" );
        # encrypt
        &push_command(
          "yes YES | cryptsetup luksFormat $real_dev $keyfile -c aes-cbc-essiv:sha256 -s 256",
          "$pre_dep,keyfile_$real_dev", "crypt_format_$real_dev" );
        &push_command(
          "cryptsetup luksOpen $real_dev $enc_dev_short_name --key-file $keyfile",
          "crypt_format_$real_dev", "exist_$enc_dev_name" );

        if (defined($1)) {
          my $passphrase = $2;

          # add user-defined key
          &push_command(
            "yes '$passphrase' | cryptsetup luksAddKey --key-file $keyfile $real_dev",
            "exist_$enc_dev_name", "newkey_$enc_dev_name");
          # remove previous key
          &push_command(
            "yes '$passphrase' | cryptsetup luksRemoveKey $real_dev $keyfile",
            "newkey_$enc_dev_name", "removed_key_$enc_dev_name");

          $keyfile = "none";
        }

        # add entries to crypttab
        push @crypttab, "$enc_dev_short_name\t$real_dev\t$keyfile\tluks";
      } elsif ($mode eq "tmp" || $mode eq "swap") {
        &push_command(
          "cryptsetup --key-file=/dev/urandom create $enc_dev_short_name $real_dev",
          $pre_dep, "exist_$enc_dev_name");

        # add entries to crypttab
        push @crypttab, "$enc_dev_short_name\t$real_dev\t/dev/urandom\t$mode";

      }

      # create the filesystem on the volume
      &build_mkfs_commands($enc_dev_name,
        \%{ $configs{$config}{volumes}{$id} });
    }
  }

}

################################################################################
#
# @brief Using the configurations from %configs, a list of commands is
# built to create any RAID devices
#
################################################################################
sub build_raid_commands {

  # check RAID arrays if there are pre-existing ones
  if (scalar(keys %current_raid_config))
  {
    &push_command("mdadm --stop --scan", "", "stop_for_assemble");
    &push_command("mdadm --assemble --scan --config=$DATADIR/mdadm-from-examine.conf",
      "stop_for_assemble", "mdadm_startall_examined");
  }
  foreach my $id (keys %current_raid_config) {
    my $md = "/dev/md$id";
    my $pre_deps_cl = "mdadm_startall_examined";
    $pre_deps_cl .= ",self_cleared_" .
      join(",self_cleared_", @{ $current_dev_children{$md} })
      if (defined($current_dev_children{$md}) &&
        scalar(@{ $current_dev_children{$md} }));
    &push_command( "mdadm -W --stop $md", "$pre_deps_cl", "self_cleared_$md");
  }

  foreach my $config (keys %configs) { # loop through all configs
    # no encrypted, tmpfs, LVM or physical devices here
    next if ($config eq "CRYPT" || $config eq "TMPFS" || $config =~ /^VG_./ || $config =~ /^PHY_./);
    ($config eq "RAID") or &internal_error("Invalid config $config");

    # create all raid devices
    foreach my $id (&numsort(keys %{ $configs{$config}{volumes} })) {

      # keep a reference to the current volume
      my $vol = (\%configs)->{$config}->{volumes}->{$id};

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
            push @spares, &enc_name($d);
          } else {
            push @eff_devs, &enc_name($d);
          }
        }

        $d = &enc_name($d);
        my ($i_p_d, $disk, $part_no) = &phys_dev($d);
        if ($vol->{preserve}) {
          $pre_req .= ($i_p_d && defined($configs{"PHY_$disk"})) ?
            ",pt_complete_$disk" :
            ",exist_$d";
        } elsif (&set_partition_flag_on_phys_dev($d, "raid")) {
          $pre_req .= defined($configs{"PHY_$disk"}) ?
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
        &push_command(
	    "mdadm --assemble /dev/md$id " . join(" ", grep(!/^missing$/, @eff_devs)),
	    "$pre_req", "exist_/dev/md$id");

        # create the filesystem on the volume, if requested
        &build_mkfs_commands("/dev/md$id",
          \%{ $configs{$config}{volumes}{$id} })
          if (1 == $vol->{always_format});
        next;
      }

      # the desired RAID level
      my $level = $vol->{mode};

      # prepend "raid", if the mode is numeric-only
      $level = "raid$level" if ($level =~ /^\d+$/);

      my ($create_options) = $configs{$config}{volumes}{$id}{mdcreateopts};
      # prevent warnings of uninitialized variables
      $create_options = '' unless $create_options;
      print "/dev/md$id MD create_options: $create_options\n" if ($debug && $create_options);
      # create the command
      $pre_req = "exist_/dev/md" . ( $id - 1 ) . $pre_req if (0 != $id);
      $pre_req =~ s/^,//;
      &push_command(
        "yes | mdadm --create $create_options /dev/md$id --level=$level --force --run --raid-devices="
          . scalar(@eff_devs) . (scalar(@spares) !=0 ? " --spare-devices=" . scalar(@spares) : "") . " "
          . join(" ", @eff_devs) . " " . join(" ", @spares),
        "$pre_req", "exist_/dev/md$id" );

      # create the filesystem on the volume
      &build_mkfs_commands("/dev/md$id",
        \%{ $configs{$config}{volumes}{$id} });
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
  ($config =~ /^VG_(.+)$/) and ($1 ne "--ANY--") or &internal_error("Invalid config $config");
  my $vg = $1; # the actual volume group

  my ($pv_create_options) = $configs{$config}{pvcreateopts};
  my ($vg_create_options) = $configs{$config}{vgcreateopts};
  # prevent warnings of uninitialized variables
  $pv_create_options = '' unless $pv_create_options;
  $vg_create_options = '' unless $vg_create_options;
  print "/dev/$vg PV create_options: $pv_create_options\n" if ($debug && $pv_create_options);
  print "/dev/$vg VG create_options: $vg_create_options\n" if ($debug && $vg_create_options);

  # create the volume group, if it doesn't exist already
  if (!defined($configs{"VG_$vg"}{exists})) {
    my $pre_dev = "";
    my $devs = "";
    # create all the devices
    foreach my $d (keys %{ $configs{$config}{devices} }) {
      $d = &enc_name($d);
      my $pre = "exist_$d";
      my ($i_p_d, $disk, $part_no) = &phys_dev($d);
      $pre .= ",pt_complete_$disk"
        if (&set_partition_flag_on_phys_dev($d, "lvm") &&
          defined($configs{"PHY_$disk"}));

      &push_command( "pvcreate -ff -y $pv_create_options $d",
        "$pre", "pv_done_$d");
      $devs .= " $d";
      $pre_dev .= ",pv_done_$d";
    }
    $pre_dev =~ s/^,//;

    # create the volume group
    &push_command( "vgcreate $vg_create_options $vg $devs",
      "$pre_dev", "vg_created_$vg" );

    # we are done
    return;
  }

  # otherwise add or remove the devices for the volume group, run pvcreate
  # where needed
  # the devices to be removed later on
  my %rm_devs = ();
  @rm_devs{ @{ $current_lvm_config{$vg}{"physical_volumes"} } } = ();

  # all devices of this VG
  my @all_devices = ();

  # the list of devices to be created
  my @new_devices = ();

  # create an undefined entry for each device
  my $pre_dev = "vg_exists_$vg";
  foreach my $d (keys %{ $configs{$config}{devices} }) {
    my $denc = &enc_name($d);
    push @all_devices, $denc;
    if (exists($rm_devs{$denc})) {
      my ($i_p_d, $disk, $part_no) = &phys_dev($denc);
      $pre_dev .= ($i_p_d && defined($configs{"PHY_$disk"})) ?
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
    my ($i_p_d, $disk, $part_no) = &phys_dev($dev);
    $pre .= ",pt_complete_$disk"
      if (&set_partition_flag_on_phys_dev($dev, "lvm") &&
        defined($configs{"PHY_$disk"}));

    &push_command( "pvcreate -ff -y $pv_create_options $dev",
      "$pre", "pv_done_$dev");
    $pre_dev .= ",pv_done_$dev";
  }
  $pre_dev =~ s/^,//;


  # extend the volume group by the new devices
  if (scalar (@new_devices)) {
    &push_command( "vgextend $vg " . join (" ", @new_devices), "$pre_dev",
      "vg_extended_$vg" );
  } else {
    &push_command( "true", "self_cleared_VG_$vg,$pre_dev", "vg_extended_$vg" );
  }

  # run vgreduce to get them removed
  if (scalar (keys %rm_devs)) {
    $pre_dev = "";
    $pre_dev .= ",exist_$_" foreach (keys %rm_devs);
    &push_command( "vgreduce $vg " . join (" ", keys %rm_devs),
      "vg_extended_$vg$pre_dev", "vg_created_$vg" );
  } else {
    &push_command( "true", "vg_extended_$vg", "vg_created_$vg" );
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
  ($config =~ /^VG_(.+)$/) and ($1 ne "--ANY--") or &internal_error("Invalid config $config");
  my $vg = $1; # the actual volume group

  # now create or resize the configured logical volumes
  foreach my $lv (@{ $configs{$config}{ordered_lv_list} }) {
    # reference to the size of the current logical volume
    my $lv_size = (\%configs)->{$config}->{volumes}->{$lv}->{size};
    # skip preserved partitions, but ensure that they exist
    if ($lv_size->{preserve}) {
      defined ($current_lvm_config{$vg}{volumes}{$lv})
        or die "Preserved volume $vg/$lv does not exist\n";
      warn "$vg/$lv will be preserved\n";
      # create the filesystem on the volume, if requested
      &build_mkfs_commands("/dev/$vg/$lv",
        \%{ $configs{$config}{volumes}{$lv} })
        if (1 == $lv_size->{always_format});
      next;
    }

    # resize the volume
    if ($lv_size->{resize}) {
      defined ($current_lvm_config{$vg}{volumes}{$lv})
        or die "Resized volume $vg/$lv does not exist\n";
      warn "$vg/$lv will be resized\n";

      use POSIX qw(floor);

      my $lvsize_mib = &convert_unit($lv_size->{eff_size} . "B");
      if ($lvsize_mib < $current_lvm_config{$vg}{volumes}{$lv}{size})
      {
        if (($configs{$config}{volumes}{$lv}{filesystem} =~
            /^ext[23]$/) && &in_path("resize2fs")) {
          my $block_count = POSIX::floor($lv_size->{eff_size} / 512);
          &push_command( "e2fsck -p -f /dev/$vg/$lv",
            "vg_enabled_$vg,exist_/dev/$vg/$lv", "e2fsck_f_resize_$vg/$lv" );
          &push_command( "resize2fs /dev/$vg/$lv ${block_count}s",
            "e2fsck_f_resize_$vg/$lv", "lv_shrink_$vg/$lv" );
        } else {
          &push_command( "parted -s /dev/$vg/$lv resize 1 0 " . $lv_size->{eff_size} .  "B",
            "vg_enabled_$vg", "lv_shrink_$vg/$lv" );
        }
        &push_command( "lvresize -L $lvsize_mib $vg/$lv",
          "vg_enabled_$vg,lv_shrink_$vg/$lv", "lv_created_$vg/$lv" );
      } else {
        &push_command( "lvresize -L $lvsize_mib $vg/$lv",
          "vg_enabled_$vg,exist_/dev/$vg/$lv", "lv_grow_$vg/$lv" );
        if (($configs{$config}{volumes}{$lv}{filesystem} =~
            /^ext[23]$/) && &in_path("resize2fs")) {
          my $block_count = POSIX::floor($lv_size->{eff_size} / 512);
          &push_command( "e2fsck -p -f /dev/$vg/$lv",
            "vg_enabled_$vg,lv_grow_$vg/$lv", "e2fsck_f_resize_$vg/$lv" );
          &push_command( "resize2fs /dev/$vg/$lv ${block_count}s",
            "e2fsck_f_resize_$vg/$lv", "exist_/dev/$vg/$lv" );
        } else {
          &push_command( "parted -s /dev/$vg/$lv resize 1 0 " . $lv_size->{eff_size} .  "B",
            "vg_enabled_$vg,lv_grow_$vg/$lv", "exist_/dev/$vg/$lv" );
        }
      }

      # create the filesystem on the volume, if requested
      &build_mkfs_commands("/dev/$vg/$lv",
        \%{ $configs{$config}{volumes}{$lv} })
        if (1 == $lv_size->{always_format});
      next;
    }

    my ($create_options) = $configs{$config}{volumes}{$lv}{lvcreateopts};
    # prevent warnings of uninitialized variables
    $create_options = '' unless $create_options;
    print "/dev/$vg/$lv LV create_options: $create_options\n" if ($debug && $create_options);
    # create a new volume
    &push_command( "lvcreate $create_options -n $lv -L " .
      &convert_unit($lv_size->{eff_size} . "B") . " $vg", "vg_enabled_$vg",
      "exist_/dev/$vg/$lv" );

    # create the filesystem on the volume
    &build_mkfs_commands("/dev/$vg/$lv",
      \%{ $configs{$config}{volumes}{$lv} });
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

  foreach my $dev (@{ $current_lvm_config{$vg}{"physical_volumes"} }) {
    my ($i_p_d, $disk, $part_no) = &phys_dev($dev);
    if ($i_p_d) {
      defined ($configs{"PHY_$disk"}) or next;
      defined ($configs{"PHY_$disk"}{partitions}{$part_no}) and
        ($configs{"PHY_$disk"}{partitions}{$part_no}{size}{preserve}) and
        next;
    } elsif ($dev =~ m{^/dev/md[\/]?(\d+)$}) {
      my $vol = $1;
      defined ($configs{RAID}) or next;
      defined ($configs{RAID}{volumes}{$vol}) or next;
      next if (1 == $configs{RAID}{volumes}{$vol}{preserve});
    } elsif ($dev =~ m{^/dev/([^/\s]+)/([^/\s]+)$}) {
      my $ivg = $1;
      my $lv = $2;
      defined($configs{"VG_$ivg"}) or next;
      defined($configs{"VG_$ivg"}{volumes}{$lv}) or next;
      next if (1 == $configs{"VG_$ivg"}{volumes}{$lv}{size}{preserve});
    } else {
      warn "Don't know how to check preservation of $dev\n";
      next;
    }
    $clear_vg = 1;
    last;
  }

  if (0 == $clear_vg) {
    my $vg_setup_pre = "vgchange_a_n_VG_$vg";
    if (defined($configs{"VG_$vg"})) {
      $configs{"VG_$vg"}{exists} = 1;

      # remove all volumes that do not exist anymore or need not be preserved
      foreach my $lv (keys %{ $current_lvm_config{$vg}{volumes} }) {
        my $pre_deps_cl = "";
        $pre_deps_cl = ",self_cleared_" .
          join(",self_cleared_", @{ $current_dev_children{"/dev/$vg/$lv"} })
            if (defined($current_dev_children{"/dev/$vg/$lv"}) &&
              scalar(@{ $current_dev_children{"/dev/$vg/$lv"} }));
        # skip preserved/resized volumes
        if (defined ( $configs{"VG_$vg"}{volumes}{$lv})) {
          if ($configs{"VG_$vg"}{volumes}{$lv}{size}{preserve} == 1 ||
            $configs{"VG_$vg"}{volumes}{$lv}{size}{resize} == 1) {
            &push_command("true", "vgchange_a_n_VG_$vg$pre_deps_cl",
              "exist_/dev/$vg/$lv,self_cleared_/dev/$vg/$lv");
            next;
          }
        }

        &push_command( "wipefs -a $vg/$lv",
          "vgchange_a_n_VG_$vg$pre_deps_cl",
          "wipefs_$vg/$lv");
        &push_command( "lvremove -f $vg/$lv",
          "wipefs_$vg/$lv",
          "lv_rm_$vg/$lv,self_cleared_/dev/$vg/$lv");
        $vg_setup_pre .= ",lv_rm_$vg/$lv";
      }
    } else {
      &push_command("true", "vgchange_a_n_VG_$vg",
        "exist_/dev/$vg/$_,self_cleared_/dev/$vg/$_") foreach
        (keys %{ $current_lvm_config{$vg}{volumes} });
    }
    &push_command("true", $vg_setup_pre, "vg_exists_$vg");

    return 0;
  }

  my $vg_destroy_pre = "vgchange_a_n_VG_$vg";
  foreach my $lv (keys %{ $current_lvm_config{$vg}{volumes} }) {
    my $pre_deps_cl = "";
    $pre_deps_cl = ",self_cleared_" .
      join(",self_cleared_", @{ $current_dev_children{"/dev/$vg/$lv"} })
        if (defined($current_dev_children{"/dev/$vg/$lv"}) &&
          scalar(@{ $current_dev_children{"/dev/$vg/$lv"} }));
    &push_command( "wipefs -a $vg/$lv",
      "vgchange_a_n_VG_$vg$pre_deps_cl",
      "wipefs_$vg/$lv");
    &push_command( "lvremove -f $vg/$lv",
      "wipefs_$vg/$lv",
      "lv_rm_$vg/$lv,self_cleared_/dev/$vg/$lv");
    $vg_destroy_pre .= ",lv_rm_$vg/$lv";
  }
  &push_command( "vgremove $vg", "$vg_destroy_pre", "vg_removed_$vg");

  # clear all the devices
  my $devices = "";
  $devices .= " " . &enc_name($_) foreach
    (@{ $current_lvm_config{$vg}{physical_volumes} });
  ($devices =~ /^\s*$/) and &internal_error("Empty PV device set");
  $debug and print "Erased devices:$devices\n";
  &push_command( "pvremove $devices", "vg_removed_$vg", "pvremove_$vg");
  my $post_wipe = "pvremove_$vg";
  foreach my $d (split (" ", $devices)) {
    $post_wipe .= ",pv_sigs_removed_wipe_${d}_$vg";
    &push_command( "wipefs -a $d", "pvremove_$vg", "pv_sigs_removed_wipe_${d}_$vg");
  }
  &push_command( "true", $post_wipe, "pv_sigs_removed_$vg" );
  return 1;
}

################################################################################
#
# @brief Using the configurations from %configs, a list of commands is
# built to setup the LVM
# creates the volume groups, the logical volumes and the filesystems
#
################################################################################
sub build_lvm_commands {

  # disable volumes if there are pre-existing ones
  foreach my $d (keys %current_dev_children) {
    next unless ($d =~ /^VG_(.+)$/);
    my $vg = $1;
    my $vg_pre = "vgchange_a_n_VG_$vg";
    my $pre_deps_vgc = "";
    foreach my $c (@{ $current_dev_children{$d} }) {
      $pre_deps_vgc = ",self_cleared_" .
        join(",self_cleared_", @{ $current_dev_children{$c} })
        if (defined($current_dev_children{$c}) &&
          scalar(@{ $current_dev_children{$c} }));
    }
    $pre_deps_vgc =~ s/^,//;
    &push_command("vgchange -a n $1", "$pre_deps_vgc", $vg_pre);
    $vg_pre .= ",pv_sigs_removed_$vg" if (&cleanup_vg($vg));
    my $pre_deps_cl = "";
    $pre_deps_cl = ",self_cleared_" .
      join(",self_cleared_", @{ $current_dev_children{$d} })
      if (scalar(@{ $current_dev_children{$d} }));
    &push_command("true", "$vg_pre$pre_deps_cl", "self_cleared_VG_$vg");
  }

  # loop through all configs
  foreach my $config (keys %configs) {

    # no physical devices, RAID, encrypted or tmpfs here
    next if ($config =~ /^PHY_./ || $config eq "RAID" || $config eq "CRYPT" || $config eq "TMPFS");
    ($config =~ /^VG_(.+)$/) or &internal_error("Invalid config $config");
    next if ($1 eq "--ANY--");
    my $vg = $1; # the volume group

    # create the volume group or add/remove devices
    &create_volume_group($config);
    # enable the volume group
    &push_command( "vgchange -a y $vg",
      "vg_created_$vg", "vg_enabled_$vg" );

    # perform all necessary operations on the underlying logical volumes
    &setup_logical_volumes($config);
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
  ($config =~ /^PHY_(.+)$/) or &internal_error("Invalid config $config");
  my $disk = $1; # the device to be configured

  # the list of partitions that must be preserved
  my @to_preserve = ();

  # find partitions that should be preserved or resized
  foreach my $part_id (&numsort(keys %{ $configs{$config}{partitions} })) {
    # reference to the current partition
    my $part = (\%configs)->{$config}->{partitions}->{$part_id};
    next unless ($part->{size}->{preserve} || $part->{size}->{resize});

    # preserved or resized partitions must exist already
    defined( $current_config{$disk}{partitions}{$part_id} )
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
  if ($configs{$config}{disklabel} eq "msdos") {
    # we assume there are no logical partitions
    my $has_logical = 0;
    my $extended    = -1;

    # now check all entries; the array is sorted
    foreach my $part_id (@to_preserve) {
      # the extended partition may already be listed; then, the id of the
      # extended partition must not change
      if ($current_config{$disk}{partitions}{$part_id}{is_extended}) {
        (defined ($configs{$config}{partitions}{$extended}{size}{extended})
          && defined ($current_config{$disk}{partitions}{$extended}{is_extended})
          && $configs{$config}{partitions}{$extended}{size}{extended}
          && $current_config{$disk}{partitions}{$extended}{is_extended}) 
          or die "ID of extended partition changes\n";

        # make sure resize is set
        $configs{$config}{partitions}{$part_id}{size}{resize} = 1;
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
      foreach my $part_id (&numsort(keys %{ $current_config{$disk}{partitions} })) {

        # no extended partition
        next unless
          $current_config{$disk}{partitions}{$part_id}{is_extended};

        # find the configured extended partition to set the mapping
        foreach my $p (&numsort(keys %{ $configs{$config}{partitions} })) {
          # reference to the current partition
          my $part = (\%configs)->{$config}->{partitions}->{$p};
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
      or &internal_error("Required extended partition not detected for preserve");
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
  ($config =~ /^PHY_(.+)$/) or &internal_error("Invalid config $config");
  my $disk = $1; # the device to be configured

  # once we rebuild partitions, their ids are likely to change; this counter
  # helps keeping track of this
  my $part_nr = 0;

  # now rebuild all preserved partitions
  foreach my $part_id (@{$to_preserve}) {
    # get the existing id
    my $mapped_id =
    $configs{$config}{partitions}{$part_id}{maps_to_existing};

    # get the original starts and ends
    my $start =
      $current_config{$disk}{partitions}{$mapped_id}{begin_byte};
    my $end =
      $current_config{$disk}{partitions}{$mapped_id}{end_byte};

    # the type of the partition defaults to primary
    my $part_type = "primary";
    if ( $configs{$config}{disklabel} eq "msdos" ) {

      # change the partition type to extended or logical as appropriate
      if ( $configs{$config}{partitions}{$part_id}{size}{extended} == 1 ) {
        $part_type = "extended";
      } elsif ( $part_id > 4 ) {
        $part_type = "logical";
        $part_nr = 4 if ( $part_nr < 4 );
      }
    }

    # restore the partition type, if any
    my $fs =
      $current_config{$disk}{partitions}{$mapped_id}{filesystem};

    # increase the partition counter for the partition created next and
    # write it to the configuration
    $part_nr++;
    $current_config{$disk}{partitions}{$mapped_id}{new_id} = $part_nr;

    # build a parted command to create the partition
    my $dn = &make_device_name($disk, $part_nr);
    &push_command( "parted -s $disk mkpart $part_type \"$fs\" ${start}B ${end}B",
      "cleared1_$disk", "prep1_$dn" );
    my $post = "exist_$dn";
    $post .= ",rebuilt_$dn" if
      $configs{$config}{partitions}{$part_id}{size}{resize};
    my $cmd = "true";
    $cmd = "losetup -o $start $dn $disk" if ((&loopback_dev($disk))[0]);
    &push_command($cmd, "prep1_$dn", $post);
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
  ($config =~ /^PHY_(.+)$/) or &internal_error("Invalid config $config");
  my $disk = $1; # the device to be configured

  # the list of partitions that must be preserved
  my @to_preserve = &get_preserved_partitions($config);
  # resize needed?
  my $needs_resize = 0;
  foreach my $part_id (@to_preserve) {
    $needs_resize = 1 if ($configs{$config}{partitions}{$part_id}{size}{resize});
    last if ($needs_resize);
  }

  my $label = $configs{$config}{disklabel};
  $label = "gpt" if ($label eq "gpt-bios");
  # A new disk label may only be written if no partitions need to be
  # preserved
  (($label eq $current_config{$disk}{disklabel})
    || (scalar (@to_preserve) == 0))
    or die "Can't change disklabel, partitions are to be preserved\n";

  # write the disklabel to drop the previous partition table
  my $pre_deps = "";
  foreach my $c (@{ $current_dev_children{$disk} }) {
    $pre_deps .= ",self_cleared_" .
    join(",self_cleared_", @{ $current_dev_children{$c} })
    if (defined($current_dev_children{$c}) &&
      scalar(@{ $current_dev_children{$c} }));
    my ($i_p_d, $d, $part_no) = &phys_dev($c);
    ($i_p_d && $d eq $disk) or &internal_error("Invalid dev children entry");
    my $wipe_cmd = "wipefs -a $c";
    foreach my $part_id (@to_preserve) {
      # get the existing id
      my $mapped_id = $configs{$config}{partitions}{$part_id}{maps_to_existing};
      $wipe_cmd = "true" if ($mapped_id == $part_no);
    }
    $wipe_cmd = "true" if
      ($current_config{$disk}{partitions}{$part_no}{is_extended});
    &push_command($wipe_cmd, "exist_$disk$pre_deps", "wipefs_$c");
    $pre_deps .= ",wipefs_$c";
  }
  &push_command( ($needs_resize ? "parted -s $disk mklabel $label" : "true"),
    "exist_$disk$pre_deps", "cleared1_$disk" );

  &rebuild_preserved_partitions($config, \@to_preserve) if ($needs_resize);

  my $pre_all_resize = "";

  # resize partitions while checking for dependencies
  foreach my $part_id (reverse &numsort(@to_preserve)) {
    # reference to the current partition
    my $part = (\%configs)->{$config}->{partitions}->{$part_id};
    # get the existing id
    my $mapped_id = $part->{maps_to_existing};
    # get the intermediate partition id; only available if
    # rebuild_preserved_partitions was done
    my $p = undef;
    if ($needs_resize) {
      $p = $current_config{$disk}{partitions}{$mapped_id}{new_id};
      # anything to be done?
      $pre_all_resize .= ",exist_" . &make_device_name($disk, $p) unless
        $part->{size}->{resize};
    }
    if ($part->{size}->{resize}) {
      warn &make_device_name($disk, $mapped_id) . " will be resized\n";
    } else {
      warn &make_device_name($disk, $mapped_id) . " will be preserved\n";
      next;
    }

    $pre_all_resize .= ",resized_" . &make_device_name($disk, $p);
    my $deps = "";
    # now walk all other partitions requiring a resize to check for overlaps
    foreach my $part_other (reverse &numsort(@to_preserve)) {
      # don't compare to self
      next if ($part_id == $part_other);
      # reference to the current partition
      my $part_other_ref = (\%configs)->{$config}->{partitions}->{$part_other};
      # anything to be done?
      next unless $part_other_ref->{size}->{resize};
      # get the existing id
      my $mapped_id_other = $part_other_ref->{maps_to_existing};
      # get the intermediate partition id
      my $p_other = $current_config{$disk}{partitions}{$mapped_id_other}{new_id};
      # check for overlap
      next if($part->{start_byte} >
        $current_config{$disk}{partitions}{$mapped_id_other}{end_byte});
      next if($part->{end_byte} <
        $current_config{$disk}{partitions}{$mapped_id_other}{begin_byte});
      # overlap detected - add dependency, but handle extended<->logical with
      # special care, even though this does not catch all cases (sometimes it
      # will fail nevertheless
      if ($part->{size}->{extended} && $part_other > 4) {
        if($part->{start_byte} >
          $current_config{$disk}{partitions}{$mapped_id_other}{begin_byte}) {
          $deps .= ",resized_" . &make_device_name($disk, $p_other);
        }
        elsif($part->{end_byte} <
          $current_config{$disk}{partitions}{$mapped_id_other}{end_byte}) {
          $deps .= ",resized_" . &make_device_name($disk, $p_other);
        }
      }
      elsif ($part_id > 4 && $part_other_ref->{size}->{extended}) {
        if($part->{start_byte} <
          $current_config{$disk}{partitions}{$mapped_id_other}{begin_byte}) {
          $deps .= ",resized_" . &make_device_name($disk, $p_other);
        }
        elsif($part->{end_byte} >
          $current_config{$disk}{partitions}{$mapped_id_other}{end_byte}) {
          $deps .= ",resized_" . &make_device_name($disk, $p_other);
        }
      } else {
        $deps .= ",resized_" . &make_device_name($disk, $p_other);
      }
    }

    # get the new starts and ends
    my $start = $part->{start_byte};
    my $end = $part->{end_byte};

    # ntfs/ext2,3 partition can't be moved
    ($start == $current_config{$disk}{partitions}{$mapped_id}{begin_byte})
      or &internal_error(
        $current_config{$disk}{partitions}{$mapped_id}{filesystem}
          . " partition start supposed to move, which is not allowed") if
      ($current_config{$disk}{partitions}{$mapped_id}{filesystem} =~
        /^(ntfs|ext[23])$/);

    # build an appropriate command
    # ntfs requires specific care
    if ($current_config{$disk}{partitions}{$mapped_id}{filesystem} eq
      "ntfs") {
      # check, whether ntfsresize is available
      &in_path("ntfsresize") or die "ntfsresize not found in PATH\n";

      &push_command( "yes | ntfsresize -s " . $part->{size}->{eff_size} .
        &make_device_name($disk, $p), "rebuilt_" .
        &make_device_name($disk, $p) . $deps, "ntfs_ready_for_rm_" .
        &make_device_name($disk, $p) );
      # TODO this is just a hack, we would really need support for resize
      # without data resize in parted, which will be added in some parted
      # version > 2.1
      &push_command( "parted -s $disk rm $p", "ntfs_ready_for_rm_" .
        &make_device_name($disk, $p), "resized_" .
        &make_device_name($disk, $p) );
    ## } elsif (($current_config{$disk}{partitions}{$mapped_id}{filesystem} =~
    ##     /^ext[23]$/) && &in_path("resize2fs")) {
    ##   TODO: BROKEN needs more checks, enlarge partition table before resize, just as
    ##   NTFS case
    ##   my $block_count = $part->{size}->{eff_size} / 512;
    ##   &push_command( "e2fsck -p -f " . &make_device_name($disk, $p),
    ##     "rebuilt_" . &make_device_name($disk, $p) . $deps,
    ##     "e2fsck_f_resize_" .  &make_device_name($disk, $p) );
    ##   &push_command( "resize2fs " . &make_device_name($disk, $p) .
    ##     " ${block_count}s", "e2fsck_f_resize_" . &make_device_name($disk, $p),
    ##     "resized_" .  &make_device_name($disk, $p) );
    } else {
      &push_command( "parted -s $disk resize $p ${start}B ${end}B",
        "rebuilt_" . &make_device_name($disk, $p) . $deps, "resized_" .
        &make_device_name($disk, $p) );
    }

  }

  # write the disklabel again to drop the partition table and create a new one
  # that has the proper ids
  &push_command( "parted -s $disk mklabel $label",
    "cleared1_$disk$pre_all_resize", "cleared2_$disk" );

  my $prev_id = -1;
  # generate the commands for creating all partitions
  foreach my $part_id (&numsort(keys %{ $configs{$config}{partitions} })) {
    # reference to the current partition
    my $part = (\%configs)->{$config}->{partitions}->{$part_id};
    # get the existing id
    my $mapped_id = $part->{maps_to_existing};

    # get the new starts and ends
    my $start = $part->{start_byte};
    my $end = $part->{end_byte};

    # the type of the partition defaults to primary
    my $part_type = "primary";
    if ($configs{$config}{disklabel} eq "msdos") {

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
    $fs = $current_config{$disk}{partitions}{$mapped_id}{filesystem}
      if ($part->{size}->{preserve} || $part->{size}->{resize});
    $fs = "" if ($fs eq "-");

    my $pre = "cleared2_$disk";
    $pre .= ",exist_" . &make_device_name($disk, $prev_id) if ($prev_id > -1);
    # build a parted command to create the partition
    my $dn = &make_device_name($disk, $part_id);
    &push_command( "parted -s $disk mkpart $part_type \"$fs\" ${start}B ${end}B",
      $pre, "prep2_$dn");
    my $cmd = "true";
    $cmd = "losetup -o $start $dn $disk" if ((&loopback_dev($disk))[0]);
    &push_command($cmd, "prep2_$dn", "exist_$dn");

    # (re-)set all flags
    my $flags = "";
    $flags = $current_config{$disk}{partitions}{$mapped_id}{flags}
      if ($part->{size}->{preserve} || $part->{size}->{resize});
    # set the bootable flag, if requested at all
    $flags .= ",boot" if($configs{$config}{bootable} == $part_id);
    # set the bios_grub flag on BIOS compatible GPT tables
    $flags .= ",bios_grub" if($configs{$config}{disklabel} eq "gpt-bios"
      && $configs{$config}{gpt_bios_part} == $part_id);
	  $flags =~ s/^,//;
    &set_partition_flag_on_phys_dev($dn, $_)
      foreach (split(',', $flags));

    $prev_id = $part_id;
  }

  &push_command("echo ,,,* | sfdisk --force $disk -N1",
    "pt_complete_$disk", "gpt_bios_fake_bootable")
    if($configs{$config}{disklabel} eq "gpt-bios");

  ($prev_id > -1) or &internal_error("No partitions created");
  $partition_table_deps{$disk} = "cleared2_$disk,exist_"
    . &make_device_name($disk, $prev_id);
}


################################################################################
#
# @brief Using the configurations from %configs, a list of commands is
# built to setup the partitions
#
################################################################################
sub build_disk_commands {

  # loop through all configs
  foreach my $config ( keys %configs ) {
    # no RAID, encrypted, tmpfs or LVM devices here
    next if ($config eq "RAID" || $config eq "CRYPT" || $config eq "TMPFS" || $config =~ /^VG_./);
    ($config =~ /^PHY_(.+)$/) or &internal_error("Invalid config $config");
    my $disk = $1; # the device to be configured

    if ($configs{$config}{virtual}) {
      foreach my $part_id (&numsort(keys %{ $configs{$config}{partitions} })) {
        # virtual disks always exist
        &push_command( "true", "",
          "exist_" . &make_device_name($disk, $part_id) );
        # no partition table operations
        $partition_table_deps{$disk} = "";
      }
    } elsif (defined($configs{$config}{partitions}{0})) {
      # no partition table operations
      $partition_table_deps{$disk} = "";
   } elsif (defined($configs{$config}{opts_all}{preserve})) {
     foreach my $part_id (&numsort(keys %{ $configs{$config}{partitions} })) {
       # all partitions exist
       &push_command( "true", "",
         "exist_" . &make_device_name($disk, $part_id) );
       # no partition table operations
       $partition_table_deps{$disk} = "";
     }
     # no changes on this disk
     $partition_table_deps{$disk} = "";
    } else {
      # create partitions on non-virtual configs
      &setup_partitions($config);
    }

    # generate the commands for creating all filesystems
    foreach my $part_id (&numsort(keys %{ $configs{$config}{partitions} })) {
      # reference to the current partition
      my $part = (\%configs)->{$config}->{partitions}->{$part_id};

      # skip preserved/resized/extended partitions
      next if (($part->{size}->{always_format} == 0 &&
          ($part->{size}->{preserve} == 1 || $part->{size}->{resize} == 1))
        || $part->{size}->{extended} == 1);

      # create the filesystem on the device
      &build_mkfs_commands( 0 == $part_id ? $disk : &make_device_name($disk, $part_id), $part );
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
  foreach my $disk (keys %current_config) {

    # write the disklabel again to drop the partition table
    &execute_command("parted -s $disk mklabel "
        . $current_config{$disk}{disklabel}, 0, 0);

    # generate the commands for creating all partitions
    foreach my $part_id (&numsort(keys %{ $current_config{$disk}{partitions} })) {
      # reference to the current partition
      my $curr_part = (\%current_config)->{$disk}->{partitions}->{$part_id};

      # get the starts and ends
      my $start = $curr_part->{begin_byte};
      my $end = $curr_part->{end_byte};

      # the type of the partition defaults to primary
      my $part_type = "primary";
      if ($current_config{$disk}{disklabel} eq "msdos") {

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
      &execute_command("parted -s $disk mkpart $part_type \"$fs\" ${start}B ${end}B");

      # re-set all flags
      &execute_command("parted -s $disk set $part_id $_ on")
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
  &push_command("true", $partition_table_deps{$_}, "pt_complete_$_")
    foreach (keys %partition_table_deps);

  my @pre_deps = ();
  my $i = 1;
  my $pushed = -1;

  while ($i < $n_c_i) {
    if ($debug) {
      print "Trying to add CMD: " . $commands{$i}{cmd} . "\n";
      defined($commands{$i}{pre}) and print "PRE: " .  $commands{$i}{pre} . "\n";
      defined($commands{$i}{post}) and print "POST: " .  $commands{$i}{post} . "\n";
    }
    my $all_matched = 1;
    if (defined($commands{$i}{pre})) {
      foreach (split(/,/, $commands{$i}{pre})) {
        my $cur = $_;
        next if scalar(grep(m{^$cur$}, @pre_deps));
        $all_matched = 0;
        last;
      }
    }
    if ($all_matched) {
      defined($commands{$i}{post}) and push @pre_deps, split(/,/, $commands{$i}{post});
      $pushed = -1;
      $i++;
      next;
    }
    if (-1 == $pushed) {
      $pushed = $n_c_i;
    }
    elsif ($i == $pushed) {
      die "Cannot satisfy pre-depends for " . $commands{$i}{cmd} . ": " .
        $commands{$i}{pre} . " -- system left untouched.\n";
    }
    &push_command( $commands{$i}{cmd}, $commands{$i}{pre},
      $commands{$i}{post} );
    delete $commands{$i};
    $i++;
  }
}

################################################################################
#
# @file exec.pm
#
# @brief functions to execute system commands
#
# $Id$
#
# @author Christian Kern, Michael Tautschnig
# @date Sun Jul 23 16:09:36 CEST 2006
#
################################################################################

use File::Temp;

################################################################################
#
# @brief hash, defined: errors, descriptions, actions on error
#
# @scalar error error
# @scalar message our errormessage
# @scalar stderr_regex regex to recognize the error message on stderr output of the bash
# @scalar stdout_regex regex to recognize the error message on stdout output of the bash
# @scalar program the program this error message can come from
# @scalar response default action on this error.
#
################################################################################
my $error_codes = [
  {
    error   => "parted_1",
    message => "Parted failed to open the device\n",
    stderr_regex => "Error: Could not stat device .* - No such file or directory",
    stdout_regex => "",
    program      => "parted",
    response     => "die",
    exit_codes   => [0..255],
  },
  {
    error   => "parted_1_new",
    message => "Parted failed to open the device\n",
    stderr_regex => "",
    stdout_regex => "Error: Could not stat device .* - No such file or directory",
    program      => "parted",
    response     => "die",
    exit_codes   => [0..255],
  },
  {
    error        => "parted_2",
    message      => "Parted could not read a disk label (new disk?)\n",
    stderr_regex => "Error: Unable to open .* - unrecognised disk label",
    stdout_regex => "",
    program      => "parted -s \\S+ unit TiB print",
    response     => "warn",
    exit_codes   => [1],
  },
  {
    error        => "parted_2_new",
    message      => "Parted could not read a disk label (new disk?)\n",
    stderr_regex => "",
    stdout_regex => "Error: .* unrecognised disk label",
    program      => "parted -s \\S+ unit TiB print",
    response     => "warn",
    exit_codes   => [1],
  },
  ## {
  ##   error        => "parted_3",
  ##   message      => "Parted was unable to create the partition\n",
  ##   stderr_regex => "Warning: You requested a partition from .* to .*\\.\$",
  ##   stdout_regex => "",
  ##   program      => "parted",
  ##   response     => \&restore_partition_table,
  ##   exit_codes   => [0..255],
  ## },
  {
    error        => "parted_4",
    message      => "Parted was unable to read the partition table\n",
    stderr_regex => "No Implementation: Partition \\d+ isn't aligned to cylinder boundaries",
    stdout_regex => "",
    program      => "parted",
    response     => "die",
    exit_codes   => [0..255],
  },
  {
    error        => "parted_4_new",
    message      => "Parted was unable to read the partition table\n",
    stderr_regex => "",
    stdout_regex => "No Implementation: Partition \\d+ isn't aligned to cylinder boundaries",
    program      => "parted",
    response     => "die",
    exit_codes   => [0..255],
  },
  {
    error        => "parted_5",
    message      => "Parted failed to resize due to a setup-storage internal error\n",
    stderr_regex => "Error: Can't have overlapping partitions",
    stdout_regex => "",
    program      => "parted",
    response     => "die",
    exit_codes   => [0..255],
  },
  {
    error        => "parted_5_new",
    message      => "Parted failed to resize due to a setup-storage internal error\n",
    stderr_regex => "",
    stdout_regex => "Error: Can't have overlapping partitions",
    program      => "parted",
    response     => "die",
    exit_codes   => [0..255],
  },
  {
    error        => "parted_6",
    message      => "Parted failed to resize the partition (is it too small?)\n",
    stderr_regex => "Error: Unable to satisfy all constraints on the partition",
    stdout_regex => "",
    program      => "parted",
    response     => "die",
    exit_codes   => [0..255],
  },
  {
    error        => "parted_6_new",
    message      => "Parted failed to resize the partition (is it too small?)\n",
    stderr_regex => "",
    stdout_regex => "Error: Unable to satisfy all constraints on the partition",
    program      => "parted",
    response     => "die",
    exit_codes   => [0..255],
  },
  {
    error   => "cmd_parted_1",
    message => "parted not found\n",
    stderr_regex => "(parted: command not found|/sbin/parted: No such file or directory)",
    stdout_regex => "",
    program      => "parted",
    response     => "die",
    exit_codes   => [0..255],
  },
  {
    error => "mkfs.xfs_1",
    message => "mkfs.xfs refused to create a filesystem. Probably you should add -f to the mkfs options in your disk_config file.\n",
    stderr_regex => "mkfs.xfs: /dev/.* appears to contain an existing filesystem",
    stdout_regex => "",
    program      => "mkfs.xfs",
    response     => "die",
    exit_codes   => [0..255],
  },
  {
    error        => "ntfsresize_1",
    message      => "NTFS resize cannot proceed\n",
    stderr_regex => "(Error|ERROR)",
    stdout_regex => "",
    program      => "ntfsresize",
    response     => "die",
    exit_codes   => [0..255],
  },
  {
    error        => "mdadm_assemble",
    message      => "mdadm tried to assemble arrays but failed, ignoring as arrays might be running already\n",
    stderr_regex => '^$',
    stdout_regex => '^$',
    program      => "mdadm --assemble --scan --config=$DATADIR/mdadm-from-examine.conf",
    response     => "warn",
    exit_codes   => [2],
  },
  {
    error        => "catch_all_nonzero_exit_code",
    message      => "Command had non-zero exit code\n",
    stderr_regex => "",
    stdout_regex => "",
    program      => ".*",
    response     => "die",
    exit_codes   => [1..255],
  },
];

################################################################################
#
# @brief returns the error message associated with an error
#
# @param error identifier of an error
#
# @return our interpretation of the error as string
#
################################################################################
sub get_error_message {

  my ($error) = @_;
  my @treffer = grep { $_->{error} eq "$error" } @$error_codes;

  # returns the first found error message.
  return $treffer[0]->{'message'};
}

################################################################################
#
# @brief gets any part of the error struct associated with an error
#
# @param error identifier of an error
# @param field field of the error struct as string, example: "stderr_regex"
#
# @return the associated value
#
################################################################################
sub get_error {

  my ($error, $field) = @_;
  my @treffer = grep { $_->{error} eq "$error" } @$error_codes;

  # returns the first found error message.
  return $treffer[0]->{$field};
}
################################################################################
#
# @brief execute a shell command, given as string. also catch stderr and
# stdout, to be passed to the caller function, and also used for error
# recognition. This execute function does execute the in the error struct
# defined action, when an error occurs.
#
# @param command bash command to be executed as string
# @reference stdout reference to a list, that should contain the standard
# output of the bash command
#
# @reference stderr reference to a list, that should contain the standard
# errer output of the bash command
#
# @return the identifier of the error
#
################################################################################
sub execute_command {

  my ($command, $stdout, $stderr) = @_;

  my $err = &execute_command_internal($command, $stdout, $stderr);

  if ($err ne "") {
    my $response = &get_error($err, "response");
    my $message  = &get_error($err, "message");

    $response->() if (ref ($response));

    die $message if ($response eq "die");

    warn $message if ($response eq "warn");

    return $err;
  }
  return "";
}

################################################################################
#
# @brief Execute a command that is known to be read-only and thus acceptable to
# be run despite dry_run mode
#
# @return the identifier of the error
#
################################################################################
sub execute_ro_command {
  my ($command, $stdout, $stderr) = @_;

  # backup value of $no_dry_run
  my $no_dry_run = $no_dry_run;

  # set no_dry_run to perform read-only commands always
  $no_dry_run = 1;

  my $err = &execute_command_internal($command, $stdout, $stderr);

  # reset no_dry_run
  $no_dry_run = $no_dry_run;

  if ($err ne "") {
    my $response = &get_error($err, "response");
    my $message  = &get_error($err, "message");

    $response->() if (ref ($response));

    die $message if ($response eq "die");

    warn $message if ($response eq "warn");

    return $err;
  }
  return "";
}


################################################################################
#
# @brief execute a /bin/bash command, given as string. also catch stderr and
# stdout, to be passed to the caller function, and also used for error
# recognition. This caller function must handle the error.
#
# @param command bash command to be executed as string
# @reference stdout_ref reference to a list, that should contain the standard
# output of the bash command
#
# @reference stderr_ref reference to a list, that should contain the standard
# error output of the bash command
#
# @return the identifier of the error
#
################################################################################
sub execute_command_internal {

  my ($command, $stdout_ref, $stderr_ref) = @_;

  my @stderr      = ();
  my @stdout      = ();
  my $stderr_line = "";
  my $stdout_line = "";
  my $exit_code   = 0;

  #make tempfile, get perl filehandle and filename of the file
  my ($stderr_fh, $stderr_filename) = File::Temp::tempfile(UNLINK => 1);
  my ($stdout_fh, $stdout_filename) = File::Temp::tempfile(UNLINK => 1);

  # do only execute the given command, when in no_dry_mode
  if ($no_dry_run) {

    $debug
      and print "(CMD) $command 1> $stdout_filename 2> $stderr_filename\n";

    # execute the bash command, write stderr and stdout into the testfiles
    print "Executing: $command\n";
    `$command 1> $stdout_filename 2> $stderr_filename`;
    $exit_code = ($?>>8);
  } else {
    print "would run command $command; to have it executed, use -X \n";
    return "";
  }

  # read the tempfile into lists, each element of the list one line
  @stderr = <$stderr_fh>;
  @stdout = <$stdout_fh>;

  #when closing the files, the tempfiles are removed too
  close ($stderr_fh);
  close ($stdout_fh);

  $debug and print "(STDERR) $_" foreach (@stderr);
  $debug and print "(STDOUT) $_" foreach (@stdout);

  #if the stderr contains information, get the first line for error recognition
  $stderr_line = $stderr[0] if (scalar (@stderr));

  #see last comment
  $stdout_line = $stdout[0] if (scalar (@stdout));

  #if an array is passed to the function, it is filled with the stdout
  @$stdout_ref = @stdout if ('ARRAY' eq ref ($stdout_ref));

  #see above
  @$stderr_ref = @stderr if ('ARRAY' eq ref ($stderr_ref));

  #get the error, if there was any
  foreach my $err (@$error_codes) {
    return $err->{error} if
      (($err->{stdout_regex} eq "" || $stdout_line =~ /$err->{stdout_regex}/)
        && ($err->{stderr_regex} eq "" || $stderr_line =~ /$err->{stderr_regex}/)
        && ($err->{program} eq "" || $command =~ /$err->{program}/)
        && (grep {$_ == $exit_code} @{ $err->{exit_codes} }));
  }

}

################################################################################
#
# @file fstab.pm
#
# @brief Generate an fstab file as appropriate for the configuration
#
# $Id$
#
# @author Christian Kern, Michael Tautschnig
# @date Sun Jul 23 16:09:36 CEST 2006
#
################################################################################

################################################################################
#
# @brief Create a line for /etc/fstab
#
# @reference $d_ref Device reference
# @param $name Device name used as a key in /etc/fstab
# @param $dev_name Real (current) device name to be used in SWAPLIST
#
# @return fstab line
#
################################################################################
sub create_fstab_line {
  my ($d_ref, $name, $dev_name) = @_;

  my @fstab_line = ();

  # start with the device key
  push @fstab_line, $name;

  # add mount information, never dump, order of filesystem checks
  push @fstab_line, ($d_ref->{mountpoint}, $d_ref->{filesystem},
    $d_ref->{mount_options}, 0, 2);
  # order of filesystem checks: the root filesystem gets a 1, the others
  # get 2, swap and tmpfs get 0
  $fstab_line[-1] = 1 if ($d_ref->{mountpoint} eq "/");
  $fstab_line[-1] = 0 if ($d_ref->{filesystem} eq "swap");
  $fstab_line[-1] = 0 if ($d_ref->{filesystem} eq "tmpfs");

  # add a comment denoting the actual device name in case of UUID or LABEL
  push @fstab_line, "# device at install: $dev_name"
    if ($name =~ /^(UUID|LABEL)=/);

  # set the ROOT_PARTITION variable, if this is the mountpoint for /
  $disk_var{ROOT_PARTITION} = $name
    if ($d_ref->{mountpoint} eq "/");

  # add to the swaplist, if the filesystem is swap
  $disk_var{SWAPLIST} .= " " . $dev_name
    if ($d_ref->{filesystem} eq "swap");

  # join the columns of one line with tabs
  return join ("\t", @fstab_line);
}


################################################################################
#
# @brief Obtain UUID and filesystem label information, if any.
#
# @param device_name Full device name
# @param key_type Type to be used (uuid, label, or device)
#
# @return fstab key to be used
#
################################################################################
sub get_fstab_key {
  my ($device_name, $key_type) = @_;

  ("uuid" eq $key_type) or ("label" eq $key_type) or ("device" eq $key_type) or
    &internal_error("Invalid key type $key_type");

  # write the device name as the first entry; if the user prefers uuids
  # or labels, use these if available
  my @uuid = ();
  system("$udev_settle");
  &in_path("/usr/lib/fai/fai-vol_id") or die "/usr/lib/fai/fai-vol_id not found\n";
  &execute_ro_command(
    "/usr/lib/fai/fai-vol_id -u $device_name", \@uuid, 0);

  # every device must have a uuid, otherwise this is an error (unless we
  # are testing only)
  ($no_dry_run == 0 || scalar (@uuid) == 1)
    or die "Failed to obtain UUID for $device_name.\n
      This may happen if the device was part of a RAID array in the past;\n
      in this case run mdadm --zero-superblock $device_name and retry\n";

  # get the label -- this is likely empty; exit code 3 if no label, but that is
  # ok here
  my @label = ();
  system("$udev_settle");
  &execute_ro_command(
    "/usr/lib/fai/fai-vol_id -l $device_name", \@label, 0);

  # print uuid and label to console
  warn "$device_name UUID=$uuid[0]" if @uuid;
  warn "$device_name LABEL=$label[0]" if @label;

  # using the fstabkey value the desired device entry is defined
  if ($key_type eq "uuid") {
    chomp ($uuid[0]);
    return "UUID=$uuid[0]";
  } elsif ($key_type eq "label" && scalar(@label) == 1) {
    chomp($label[0]);
    return "LABEL=$label[0]";
  } else {
    # otherwise, use the usual device path
    return $device_name;
  }
}

################################################################################
#
# @brief Find the mount point for /boot
#
# @return mount point for /boot
#
################################################################################
sub find_boot_mnt_point {
  my $mnt_point = ".NO_SUCH_MOUNTPOINT";

  # walk through all configured parts
  foreach my $c (keys %configs) {

    if ($c =~ /^PHY_(.+)$/) {
      foreach my $p (keys %{ $configs{$c}{partitions} }) {
        my $this_mp = $configs{$c}{partitions}{$p}{mountpoint};

        next if (!defined($this_mp));

        return $this_mp if ($this_mp eq "/boot");
        $mnt_point = $this_mp if ($this_mp eq "/");
      }
    } elsif ($c =~ /^VG_(.+)$/) {
      next if ($1 eq "--ANY--");
      foreach my $l (keys %{ $configs{$c}{volumes} }) {
        my $this_mp = $configs{$c}{volumes}{$l}{mountpoint};

        next if (!defined($this_mp));

        return $this_mp if ($this_mp eq "/boot");
        $mnt_point = $this_mp if ($this_mp eq "/");
      }
    } elsif ($c eq "RAID" || $c eq "CRYPT") {
      foreach my $r (keys %{ $configs{$c}{volumes} }) {
        my $this_mp = $configs{$c}{volumes}{$r}{mountpoint};

        next if (!defined($this_mp));

        return $this_mp if ($this_mp eq "/boot");
        $mnt_point = $this_mp if ($this_mp eq "/");
      }
    } elsif ($c eq "TMPFS") {
      # not usable for /boot
      next;
    } else {
      &internal_error("Unexpected key $c");
    }
  }

  return $mnt_point;
}

################################################################################
#
# @brief this function generates the fstab file from our representation of the
# partitions to be created.
#
# @reference config Reference to our representation of the partitions to be
# created
#
# @return list of fstab lines
#
################################################################################
sub generate_fstab {

  # config structure is the only input
  my ($config) = @_;

  # the file to be returned, a list of lines
  my @fstab = ();

  # mount point for /boot
  my $boot_mnt_point = &find_boot_mnt_point();

  # walk through all configured parts
  # the order of entries is most likely wrong, it is fixed at the end
  foreach my $c (keys %$config) {

    # entry is a physical device
    if ($c =~ /^PHY_(.+)$/) {
      my $device = $1;

      # make sure the desired fstabkey is defined at all
      defined ($config->{$c}->{fstabkey})
        or &internal_error("fstabkey undefined");

      # create a line in the output file for each partition
      foreach my $p (keys %{ $config->{$c}->{partitions} }) {

        # keep a reference to save some typing
        my $p_ref = $config->{$c}->{partitions}->{$p};

        # skip extended partitions and entries without a mountpoint
        next if ($p_ref->{size}->{extended} || $p_ref->{mountpoint} eq "-");

        my $device_name = 0 == $p ? $device :
          &make_device_name($device, $p);

        # if the mount point the /boot mount point, variables must be set
        if ($p_ref->{mountpoint} eq $boot_mnt_point) {
          # set the BOOT_DEVICE and BOOT_PARTITION variables
          $disk_var{BOOT_PARTITION} = $device_name;
          $disk_var{BOOT_DEVICE} = $device;
        }

        push @fstab, &create_fstab_line($p_ref,
          &get_fstab_key($device_name, $config->{$c}->{fstabkey}), $device_name);

      }
    } elsif ($c =~ /^VG_(.+)$/) {
      next if ($1 eq "--ANY--");

      my $device = $1;

      # create a line in the output file for each logical volume
      foreach my $l (keys %{ $config->{$c}->{volumes} }) {

        # keep a reference to save some typing
        my $l_ref = $config->{$c}->{volumes}->{$l};

        # skip entries without a mountpoint
        next if ($l_ref->{mountpoint} eq "-");

        my $device_name = "/dev/$device/$l";

        # if the mount point the /boot mount point, variables must be set
        $disk_var{BOOT_DEVICE} = $device_name
          if ($l_ref->{mountpoint} eq $boot_mnt_point);

        push @fstab, &create_fstab_line($l_ref,
          &get_fstab_key($device_name, $config->{"VG_--ANY--"}->{fstabkey}), $device_name);
      }
    } elsif ($c eq "RAID") {

      # create a line in the output file for each device
      foreach my $r (keys %{ $config->{$c}->{volumes} }) {

        # keep a reference to save some typing
        my $r_ref = $config->{$c}->{volumes}->{$r};

        # skip entries without a mountpoint
        next if ($r_ref->{mountpoint} eq "-");

        my $device_name = "/dev/md$r";

        # if the mount point the /boot mount point, variables must be set
        $disk_var{BOOT_DEVICE} = $device_name
          if ($r_ref->{mountpoint} eq $boot_mnt_point);

        push @fstab, &create_fstab_line($r_ref,
          &get_fstab_key($device_name, $config->{RAID}->{fstabkey}), $device_name);
      }
    } elsif ($c eq "CRYPT") {
      foreach my $v (keys %{ $config->{$c}->{volumes} }) {
        my $c_ref = $config->{$c}->{volumes}->{$v};

        next if ($c_ref->{mountpoint} eq "-");

        my $device_name = &enc_name($c_ref->{device});

        ($c_ref->{mountpoint} eq $boot_mnt_point) and
          die "Boot partition cannot be encrypted\n";

        push @fstab, &create_fstab_line($c_ref, $device_name, $device_name);
      }
    } elsif ($c eq "TMPFS") {
      foreach my $v (keys %{ $config->{$c}->{volumes} }) {
        my $c_ref = $config->{$c}->{volumes}->{$v};

        next if ($c_ref->{mountpoint} eq "-");

        ($c_ref->{mountpoint} eq $boot_mnt_point) and
          die "Boot partition cannot be a tmpfs\n";

	if (($c_ref->{mount_options} =~ m/size=/) || ($c_ref->{mount_options} =~ m/nr_blocks=/)) {
          warn "Specified tmpfs size for $c_ref->{mountpoint} ignored as mount options contain size= or nr_blocks=\n";
        } else {
	  $c_ref->{mount_options} .= "," if ($c_ref->{mount_options} ne "");
          # Size will be in % or MiB
	  $c_ref->{mount_options} .= "size=" . $c_ref->{size};
	}

        push @fstab, &create_fstab_line($c_ref, "tmpfs", "tmpfs");
      }
    } else {
      &internal_error("Unexpected key $c");
    }
  }

  # cleanup the swaplist (remove leading space and add quotes)
  $disk_var{SWAPLIST} =~ s/^\s*/"/;
  $disk_var{SWAPLIST} =~ s/\s*$/"/;

  # cleanup the list of boot devices (remove leading space and add quotes)
  $disk_var{BOOT_DEVICE} =~ s/^\s*/"/;
  $disk_var{BOOT_DEVICE} =~ s/\s*$/"/;

  # sort the lines in @fstab to enable all sub mounts
  @fstab = sort { [split("\t",$a)]->[1] cmp [split("\t",$b)]->[1] } @fstab;

  # add a nice header to fstab
  unshift @fstab,
    "# <file sys>\t<mount point>\t<type>\t<options>\t<dump>\t<pass>";
  unshift @fstab, "#";
  unshift @fstab, "# /etc/fstab: static file system information.";

  # return the list of lines
  return @fstab;
}

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

################################################################################
#
# @brief the name of the device currently being configured, including a prefix
# such as PHY_ or VG_ to indicate physical devices or LVM volume groups. For
# RAID, the entry is only "RAID"
#
################################################################################
my $device = "";

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
  return 1 if ($check_only);

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
    if ($check_only && $disk =~ /^\d+$/);

  # test $disk for being numeric
  if ($disk =~ /^\d+$/) {
    # $disk-1 must be a valid index in the map of all disks in the system
    (scalar(@disks) >= $disk)
      or die "this system does not have a physical disk $disk\n";

    # fetch the (short) device name
    $disk = $disks[ $disk - 1 ];
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
# @brief Initialise a new entry in @ref $configs for a physical disk.
#
# Checks whether the specified device is valid, creates the entry in the hash
# and sets @ref $device.
#
# @param $disk Either an integer, occurring in the context of, e.g., disk2, or
# a device name. The latter may be fully qualified, such as /dev/hda, or a short
# name, such as sdb, in which case /dev/ is prepended.
#
################################################################################
sub init_disk_config {

  # Initialise $disk
  my ($disk) = @_;

  $disk = &resolve_disk_shortname($disk);

  &in_path("losetup") or die "losetup not found in PATH\n"
    if ((&loopback_dev($disk))[0]);

  # prepend PHY_
  $device = "PHY_$disk";

  # test, whether this is the first disk_config stanza to configure $disk
  defined ($configs{$device})
    and die "Duplicate configuration for disk $disk\n";

  # Initialise the entry in $configs
  $configs{$device} = {
    virtual    => 0,
    disklabel  => "msdos",
    bootable   => -1,
    fstabkey   => "device",
    preserveparts => 0,
    partitions => {},
    opts_all   => {}
  };

  # Init device tree object
  $dev_children{$disk} = ();

  return 1;
}

################################################################################
#
# @brief Initialise the entry of a partition in @ref $configs
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
    &internal_error("invalid type $type");

  # check that a physical device is being configured; logical partitions are
  # only supported on msdos disk labels.
  ($device =~ /^PHY_(.+)$/ && ($type ne "logical"
      || $configs{$device}{disklabel} eq "msdos")) or 
    die "Syntax error: invalid partition type";

  # the disk
  my $disk = $1;

  # the index of the new partition
  my $part_number = 0;

  # defaults from options
  my $preserve_default =
    defined($configs{$device}{opts_all}{preserve}) ? 1 :
      (defined($configs{$device}{opts_all}{preserve_lazy}) ? 2 : 0);
  my $always_format_default =
    defined($configs{$device}{opts_all}{always_format}) ? 1 : 0;
  my $resize_default =
    defined($configs{$device}{opts_all}{resize}) ? 1 : 0;

  # create a primary partition
  if ($type eq "primary") {
    (defined($configs{$device}{partitions}{0})) and
      die "You cannot use raw-disk together with primary/logical partitions\n";

    # find all previously defined primary partitions
    foreach my $part_id (&numsort(keys %{ $configs{$device}{partitions} })) {

      # break, if the partition has not been created by init_part_config
      defined ($configs{$device}{partitions}{$part_id}{size}{extended}) or last;

      # on msdos disklabels we cannot have more than 4 primary partitions
      last if ($part_id > 4 && ! $configs{$device}{virtual}
        && $configs{$device}{disklabel} eq "msdos");

      # store the latest index found
      $part_number = $part_id;
    }

    # the next index available - note that $part_number might have been 0
    $part_number++;

    # msdos disk labels don't allow for more than 4 primary partitions
    ($part_number < 5 || $configs{$device}{virtual} || 
      $configs{$device}{disklabel} ne "msdos")
      or die "$part_number are too many primary partitions\n";
  } elsif ($type eq "raw") {
    (0 == scalar(keys %{ $configs{$device}{partitions} })) or
      die "You cannot use raw-disk together with primary/logical partitions\n";
    # special-case hack: part number 0 is invalid otherwise
    $part_number = 0;
  } else {
    (defined($configs{$device}{partitions}{0})) and
      die "You cannot use raw-disk together with primary/logical partitions\n";

    # no further checks for the disk label being msdos have to be performed in
    # this branch, it has been ensured above

    # find the index of the new partition, initialise it to the highest current index
    foreach my $part_id (&numsort(keys %{ $configs{$device}{partitions} })) {

      # skip primary partitions
      next if ($part_id < 5);

      # break, if the partition has not been created by init_part_config
      defined($configs{$device}{partitions}{$part_id}{size}{extended})
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
      foreach my $part_id (&numsort(keys %{ $configs{$device}{partitions} })) {

        # break, if the partition has not been created by init_part_config
        defined ($configs{$device}{partitions}{$part_id}{size}{extended}) or last;

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
      defined ($configs{$device}{partitions}{$extended})
        or (\%configs)->{$device}->{partitions}->{$extended} = {
          size => {}
        };

      my $part_size =
        (\%configs)->{$device}->{partitions}->{$extended}->{size};

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
      push @{ $dev_children{$disk} }, &make_device_name($disk, $extended);
    }
  }

  # initialise the hash for the partitions, if it doesn't exist already
  # note that it might exists due to options, such as preserve:x,y
  # the initialisation is required for the reference defined next
  defined ($configs{$device}{partitions}{$part_number})
    or $configs{$device}{partitions}{$part_number} = {};

  # set the reference to the current partition
  # the reference is used by all further processing of this config line
  $partition_pointer =
    (\%configs)->{$device}->{partitions}->{$part_number};
  $partition_pointer_dev_name = &make_device_name($disk, $part_number);

  # the partition is not an extended one
  $partition_pointer->{size}->{extended} = 0;

  # add the preserve = 0 flag, if it doesn't exist already
  defined ($partition_pointer->{size}->{preserve})
    or $partition_pointer->{size}->{preserve} = $preserve_default;

  # add the always_format = 0 flag, if it doesn't exist already
  defined ($partition_pointer->{size}->{always_format})
    or $partition_pointer->{size}->{always_format} = $always_format_default;

  # add the resize = 0 flag, if it doesn't exist already
  defined ($partition_pointer->{size}->{resize})
    or $partition_pointer->{size}->{resize} = $resize_default;

  # add entry to device tree
  push @{ $dev_children{$disk} }, $partition_pointer_dev_name;
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
  else { &internal_error("convert_unit $val"); }

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
  $min   = &convert_unit($min);
  $max .= "MiB" if ($max =~ /\d\s*$/);
  $max   = &convert_unit($max);
  # enter the range into the hash
  $partition_pointer->{size}->{range} = "$min-$max";
  # set the resize or preserve flag, if required
  if (defined ($options)) {
    $configs{$device}{preserveparts} = 1;
    $partition_pointer->{size}->{resize} = 1 if ($options =~ /^:resize/);
    $partition_pointer->{size}->{preserve} = 1 if ($options =~ /^:preserve_always/);
    $partition_pointer->{size}->{preserve} = 1
    if ($reinstall && $options =~ /^:preserve_reinstall/);
    if ($options =~ /^:preserve_lazy/) {
      $configs{$device}{preserveparts} = 2;
      $partition_pointer->{size}->{preserve} = 2;
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
my $Parser = Parse::RecDescent->new(
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

	  use Storable qw(dclone);

	  $FAI::configs{$FAI::device} = dclone($FAI::configs{"PHY_" . $ref_dev});
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

	  use Storable qw(dclone);

	  $FAI::configs{$FAI::device} = dclone($FAI::configs{"PHY_" . $ref_dev});
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
# @brief Parse the data from <$IN> using @ref $Parser
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
  $debug and print "Input was:\n" . $input;

  # check for old-style configuration files
  ($input =~ m{(^|\n)[^\n#]+;})
    and die "Error: Old style configuration files are not supported\n";

  # attempt to parse $input - any error will lead to termination
  defined $Parser->file($input) or die "Syntax error\n";
}

################################################################################
#
# @brief Check for invalid configs (despite correct syntax)
#
################################################################################
sub check_config {

  my %all_mount_pts = ();

  # loop through all configs
  foreach my $config (keys %configs) {
    if ($config =~ /^PHY_(.+)$/) {
      (scalar(keys %{ $configs{$config}{partitions} }) > 0) or
        die "Empty disk_config stanza for device $1\n";
      foreach my $p (keys %{ $configs{$config}{partitions} }) {
        next if (1 == $configs{$config}{partitions}{$p}{size}{extended});
        defined($configs{$config}{partitions}{$p}{mountpoint}) or
          &internal_error("Undefined mountpoint for non-extended partition");
        my $this_mp = $configs{$config}{partitions}{$p}{mountpoint};
        next if ($this_mp eq "-");
        defined($all_mount_pts{$this_mp}) and die
          "Mount point $this_mp used twice\n";
        defined($dev_children{&make_device_name($1, $p)}) and die
          "Mount point $this_mp is shadowed by stacked devices\n";
        ($this_mp eq "none") or $all_mount_pts{$this_mp} = 1;
      }
    } elsif ($config =~ /^VG_(.+)$/) {
      next if ($1 eq "--ANY--");
      (scalar(keys %{ $configs{$config}{volumes} }) ==
        scalar(@{ $configs{$config}{ordered_lv_list} })) or
        &internal_error("Inconsistent LV lists - missing entries");
      defined($configs{$config}{volumes}{$_}) or
        &internal_error("Inconsistent LV lists - missing entries")
        foreach (@{ $configs{$config}{ordered_lv_list} });
      foreach my $p (keys %{ $configs{$config}{volumes} }) {
        my $this_mp = $configs{$config}{volumes}{$p}{mountpoint};
        next if ($this_mp eq "-");
        defined($all_mount_pts{$this_mp}) and die
          "Mount point $this_mp used twice\n";
        defined($dev_children{"/dev/$1/$p"}) and die
          "Mount point $this_mp is shadowed by stacked devices\n";
        ($this_mp eq "none") or $all_mount_pts{$this_mp} = 1;
      }
      next;
    } elsif ($config eq "RAID") {
      (scalar(keys %{ $configs{$config}{volumes} }) > 0) or
        die "Empty RAID configuration\n";
      foreach my $p (keys %{ $configs{$config}{volumes} }) {
        my $this_mp = $configs{$config}{volumes}{$p}{mountpoint};
        next if ($this_mp eq "-");
        defined($all_mount_pts{$this_mp}) and die
          "Mount point $this_mp used twice\n";
        defined($dev_children{"/dev/md$p"}) and die
          "Mount point $this_mp is shadowed by stacked devices\n";
        ($this_mp eq "none") or $all_mount_pts{$this_mp} = 1;
      }
    } elsif ($config eq "CRYPT") {
      foreach my $p (keys %{ $configs{$config}{volumes} }) {
        my $this_mp = $configs{$config}{volumes}{$p}{mountpoint};
        next if ($this_mp eq "-");
        defined($all_mount_pts{$this_mp}) and die
          "Mount point $this_mp used twice\n";
        ($this_mp eq "none") or $all_mount_pts{$this_mp} = 1;
      }
      next;
    } elsif ($config eq "TMPFS") {
      foreach my $p (keys %{ $configs{$config}{volumes} }) {
        my $this_mp = $configs{$config}{volumes}{$p}{mountpoint};
        next if ($this_mp eq "-");
        defined($all_mount_pts{$this_mp}) and die
          "Mount point $this_mp used twice\n";
        ($this_mp eq "none") or $all_mount_pts{$this_mp} = 1;
      }
      next;
    } else {
      &internal_error("Unexpected key $config");
    }
  }
}

################################################################################
#
# @file sizes.pm
#
# @brief Compute the size of the partitions and volumes to be created
#
# $Id$
#
# @author Christian Kern, Michael Tautschnig
# @date Sun Jul 23 16:09:36 CEST 2006
#
################################################################################

################################################################################
#
# @brief Build an array $start,$end from ($start-$end)
#
# @param $rstr Range string
# @param $size Size and unit
#
# @return ($start,$end) in bytes
#
################################################################################
use POSIX qw(ceil floor);

sub make_range {

  my ($rstr, $size) = @_;
  # convert size to Bytes
  my $size_b = &convert_unit($size) * 1024.0 * 1024.0;
  # check the format of the string
  ($rstr =~ /^(\d+(\.\d+)?%?)-(\d+(\.\d+)?%?)$/) or &internal_error("Invalid range");
  my ($start, $end) = ($1, $3);
  # start may be given in percents of the size
  if ($start =~ /^(\d+(\.\d+)?)%$/) {
    # rewrite it to bytes
    $start = POSIX::floor($size_b * $1 / 100);
  } else {
    # it is given in megabytes, make it bytes
    $start = $start * 1024.0 * 1024.0;
  }

  # end may be given in percents of the size
  if ( $end =~ /^(\d+(\.\d+)?)%$/ ) {
    # rewrite it to bytes
    $end = POSIX::ceil($size_b * $1 / 100);
  } else {
    # it is given in megabytes, make it bytes
    $end = $end * 1024.0 * 1024.0;
  }

  # the user may have specified a partition that is larger than the entire disk
  ($start <= $size_b) or die "Sorry, can't create a partition of $start B on a disk of $size_b B - check your config!\n";
  # make sure that $end >= $start
  ($end >= $start) or &internal_error("end < start");

  return ($start, $end);
}

################################################################################
#
# @brief Estimate the size of the device $dev
#
# @param $dev Device the size of which should be determined. This may be a
# a partition, a RAID device or an entire disk.
#
# @return the size of the device in megabytes
#
################################################################################
sub estimate_size {
  my ($dev) = @_;

  # try the entire disk first; we then use the data from the current
  # configuration; this matches in fact for than the allowable strings, but
  # this should be caught later on
  my ($i_p_d, $disk, $part_no) = &phys_dev($dev);
  if (1 == $i_p_d && -1 == $part_no) {
    (defined ($current_config{$dev}) &&
      defined ($current_config{$dev}{end_byte}))
        or die "$dev is not a valid block device\n";

    # the size is known, return it
    return ($current_config{$dev}{end_byte} -
        $current_config{$dev}{begin_byte}) / (1024 * 1024);
  }

  # try a partition
  elsif (1 == $i_p_d && $part_no > -1) {
    # the size is configured, return it
    defined ($configs{"PHY_$disk"}) and
      defined ($configs{"PHY_$disk"}{partitions}{$part_no}{size}{eff_size})
        and return $configs{"PHY_$disk"}{partitions}{$part_no}{size}{eff_size} /
        (1024 * 1024);

    # the size is known from the current configuration on disk, return it
    defined ($current_config{$disk}) and
      defined ($current_config{$disk}{partitions}{$part_no}{count_byte})
        and return $current_config{$disk}{partitions}{$part_no}{count_byte} /
        (1024 * 1024) unless defined ($configs{"PHY_$disk"}{partitions});

    # the size is not known (yet?)
    warn "Cannot determine size of $dev\n";
    return 0;
  }

  # try RAID; estimations here are very limited and possible imprecise
  elsif ($dev =~ /^\/dev\/md(\d+)$/) {

    # the list of underlying devices
    my @devs = ();

    # the raid level, like raid0, raid5, linear, etc.
    my $level = "";

    # the number of devices in the volume
    my $dev_count = 0;

    # let's see, whether there is a configuration of this volume
    if (defined ($configs{RAID}{volumes}{$1})) {
      my @devcands = keys %{ $configs{RAID}{volumes}{$1}{devices} };
      $dev_count = scalar(@devcands);
      # we can only estimate the sizes of existing volumes, assume the missing
      # ones aren't smaller
      foreach (@devcands) {
        $dev_count-- if ($configs{RAID}{volumes}{$1}{devices}{$_}{spare});
        next if ($configs{RAID}{volumes}{$1}{devices}{$_}{missing});
        push @devs, $_;
      }
      $level = $configs{RAID}{volumes}{$1}{mode};
    } elsif (defined ($current_raid_config{$1})) {
      @devs  = $current_raid_config{$1}{devices};
      $dev_count = scalar(@devs);
      $level = $current_raid_config{$1}{mode};
    } else {
      die "$dev is not a known RAID device\n";
    }

    # make sure there is at least one non-missing device
    (scalar(@devs) > 0) or die "No devices available in /dev/md$1\n";

    # prepend "raid", if the mode is numeric-only
    $level = "raid$level" if ($level =~ /^\d+$/);

    # now do the mode-specific size estimations
    if ($level =~ /^raid([0156]|10)$/) {
      my $min_size = &estimate_size(shift @devs);
      foreach (@devs) {
        my $s = &estimate_size($_);
        $min_size = $s if ($s < $min_size);
      }

      return $min_size * $dev_count if ($level eq "raid0");
      return $min_size if ($level eq "raid1");
      return $min_size * ($dev_count - 1) if ($level eq "raid5");
      return $min_size * ($dev_count - 2) if ($level eq "raid6");
      return $min_size * ($dev_count/2) if ($level eq "raid10");
    } else {

      # probably some more should be implemented
      die "Don't know how to estimate the size of a $level device\n";
    }
  }

  # otherwise we are clueless
  else {
    die "Cannot determine size of $dev - scheme unknown\n";
  }
}

################################################################################
#
# @brief Compute the desired sizes of logical volumes
#
################################################################################
sub compute_lv_sizes {

  # loop through all device configurations
  foreach my $config (keys %configs) {

    # for RAID, encrypted, tmpfs or physical disks there is nothing to be done here
    next if ($config eq "RAID" || $config eq "CRYPT" || $config eq "TMPFS" || $config =~ /^PHY_./);
    ($config =~ /^VG_(.+)$/) or &internal_error("invalid config entry $config");
    next if ($1 eq "--ANY--");
    my $vg = $1; # the volume group name

    # compute the size of the volume group; this is not exact, but should at
    # least give a rough estimation, we assume 1 % of overhead; the value is
    # stored in megabytes
    my $vg_size = 0;
    foreach my $dev (keys %{ $configs{$config}{devices} }) {

      # $dev may be a partition, an entire disk or a RAID device; otherwise we
      # cannot deal with it
      my $cur_size = &estimate_size($dev);
      ($cur_size > 0)
        or die "Size of device $dev in volume group $vg cannot be determined\n";
      $vg_size += $cur_size;
    }

    # now subtract 1% of overhead
    $vg_size *= 0.99;

    # the volumes that require redistribution of free space
    my @redist_list = ();

    # the minimum and maximum space required in this volume group
    my $min_space = 0;
    my $max_space = 0;

    # set effective sizes where available
    foreach my $lv (keys %{ $configs{$config}{volumes} }) {
      # reference to the size of the current logical volume
      my $lv_size = (\%configs)->{$config}->{volumes}->{$lv}->{size};
      # get the effective sizes (in Bytes) from the range
      my ($start, $end) = &make_range($lv_size->{range}, "${vg_size}MiB");
      # make them MB
      $start /= 1024.0 * 1024.0;
      $end /= 1024.0 * 1024.0;

      # increase the used space
      $min_space += $start;
      $max_space += $end;

      # write back the range in MB
      $lv_size->{range} = "$start-$end";

      # the size is fixed
      if ($start == $end) { 
        # write the size back to the configuration
        $lv_size->{eff_size} = $start * 1024.0 * 1024.0;
      } else {

        # add this volume to the redistribution list
        push @redist_list, $lv;
      }
    }

    # test, whether the configuration fits on the volume group at all
    ($min_space < $vg_size)
      or die "Volume group $vg requires $min_space MB, but available space was estimated to be $vg_size\n";

    # the extension factor
    my $redist_factor = 0;
    $redist_factor = ($vg_size - $min_space) / ($max_space - $min_space)
      if ($max_space > $min_space);
    $redist_factor = 1.0 if ($redist_factor > 1.0);

    # update all sizes that are still ranges
    foreach my $lv (@redist_list) {

      # get the range again
      my ($start, $end) =
      &make_range($configs{$config}{volumes}{$lv}{size}{range}, "${vg_size}MiB");
      # make them MB
      $start /= 1024.0 * 1024.0;
      $end /= 1024.0 * 1024.0;

      # write the final size
      $configs{$config}{volumes}{$lv}{size}{eff_size} =
        ($start + (($end - $start) * $redist_factor)) * 1024.0 * 1024.0;
    }
  }
}

################################################################################
#
# @brief Handle preserved partitions while computing the size of partitions
#
# @param $part_id Partition id within $config
# @param $config Disk config
# @param $current_disk Current config of this disk
# @param $next_start Start of the next partition
# @param $max_avail The maximum size of a partition on this disk
#
# @return Updated value of $next_start
#
################################################################################
sub do_partition_preserve {

  my ($part_id, $config, $disk, $next_start, $max_avail) = @_;
  # reference to the current disk config
  my $current_disk = $current_config{$disk};

  # reference to the current partition
  my $part = (\%configs)->{$config}->{partitions}->{$part_id};
  # full device name
  my $part_dev_name = &make_device_name($disk, $part_id);

  # a partition that should be preserved must exist already
  defined($current_disk->{partitions}->{$part_id})
    or die "$part_dev_name can't be preserved, it does not exist.\n";

  my $curr_part = $current_disk->{partitions}->{$part_id};

  ($next_start > $curr_part->{begin_byte})
    and die "Previous partitions overflow begin of preserved partition $part_dev_name\n"
    unless (defined($configs{$config}{opts_all}{preserve}));

  # get what the user desired
  my ($start, $end) = &make_range($part->{size}->{range}, $max_avail);
  ($start > $curr_part->{count_byte} || $end < $curr_part->{count_byte})
    and warn "Preserved partition $part_dev_name retains size " .
      $curr_part->{count_byte} . "B\n";

  # set the effective size to the value known already
  $part->{size}->{eff_size} = $curr_part->{count_byte};

  # copy the start_byte and end_byte information
  $part->{start_byte} = $curr_part->{begin_byte};
  $part->{end_byte} = $curr_part->{end_byte};

  # set the next start
  $next_start = $part->{end_byte} + 1;

  # several msdos specific parts
  if ($configs{$config}{disklabel} eq "msdos") {

    # make sure the partition ends at a cylinder boundary
    # maybe we should make this a warning if ($curr_part->{filesystem} eq
    # "ntfs")) only, but for now just a warning for everyone; well, it might
    # also be safe to ignore this, don't know for sure.
    (0 == ($curr_part->{end_byte} + 1)
        % ($current_disk->{sector_size} *
          $current_disk->{bios_sectors_per_track} *
          $current_disk->{bios_heads})) or 
      warn "Preserved partition $part_dev_name does not end at a cylinder boundary, parted may fail to restore the partition!\n";

    # make sure we don't change extended partitions to ordinary ones and
    # vice-versa
    ($part->{size}->{extended} == $curr_part->{is_extended})
      or die "Preserved partition $part_dev_name can't change extended/normal setting\n";

    # extended partitions are not handled in here (anymore)
    ($part->{size}->{extended})
      and die &internal_error("Preserve must not handle extended partitions\n");
  }

  # on gpt, ensure that the partition ends at a sector boundary
  if ($configs{$config}{disklabel} eq "gpt" ||
    $configs{$config}{disklabel} eq "gpt-bios") {
    (0 == ($current_disk->{partitions}{$part_id}{end_byte} + 1)
        % $current_disk->{sector_size})
      or die "Preserved partition $part_dev_name does not end at a sector boundary\n";
  }

  return $next_start;
}

################################################################################
#
# @brief Handle extended partitions while computing the size of partitions
#
# @param $part_id Partition id within $config
# @param $config Disk config
# @param $current_disk Current config of this disk
#
################################################################################
sub do_partition_extended {

  my ($part_id, $config, $current_disk) = @_;

  # reference to the current partition
  my $part = (\%configs)->{$config}->{partitions}->{$part_id};

  ($configs{$config}{disklabel} eq "msdos")
    or die "found an extended partition on a non-msdos disklabel\n";

  # ensure that it is a primary partition
  ($part_id <= 4) or
    &internal_error("Extended partition wouldn't be a primary one");

  # initialise the size and the start byte
  $part->{size}->{eff_size} = 0;
  $part->{start_byte} = -1;

  foreach my $p (&numsort(keys %{ $configs{$config}{partitions} })) {
    next if ($p < 5);

    $part->{start_byte} = $configs{$config}{partitions}{$p}{start_byte} -
      (2 * $current_disk->{sector_size}) if (-1 == $part->{start_byte});

    $part->{size}->{eff_size} +=
      $configs{$config}{partitions}{$p}{size}{eff_size} + (2 *
        $current_disk->{sector_size});

    $part->{end_byte} = $configs{$config}{partitions}{$p}{end_byte};
  }

  ($part->{size}->{eff_size} > 0)
    or die "Extended partition has a size of 0\n";
}

################################################################################
#
# @brief Handle all other partitions while computing the size of partitions
#
# @param $part_id Partition id within $config
# @param $config Disk config
# @param $disk This disk
# @param $next_start Start of the next partition
# @param $block_size Requested alignment
# @param $max_avail The maximum size of a partition on this disk
# @param $worklist Reference to the remaining partitions
#
# @return Updated value of $next_start and possibly updated value of $max_avail
#
################################################################################
sub do_partition_real {

  my ($part_id, $config, $disk, $next_start, $block_size, $max_avail, $worklist) = @_;
  # reference to the current disk config
  my $current_disk = $current_config{$disk};

  # reference to the current partition
  my $part = (\%configs)->{$config}->{partitions}->{$part_id};

  # compute the effective start location on the disk
  # msdos specific offset for logical partitions
  $next_start += 2 * $current_disk->{sector_size}
    if (($configs{$config}{disklabel} eq "msdos") && ($part_id > 4));

  # partition starts at where we currently are + requested alignment, or remains
  # fixed in case of resized ntfs
  if ($configs{$config}{partitions}{$part_id}{size}{resize} &&
    ($current_disk->{partitions}->{$part_id}->{filesystem} eq "ntfs")) {
    ($next_start <= $current_disk->{partitions}->{$part_id}->{begin_byte})
      or die "Cannot preserve start byte of ntfs volume on partition $part_id, space before it is too small\n";
    $next_start = $current_disk->{partitions}->{$part_id}->{begin_byte};
  } else {
    $next_start += $block_size - ($next_start % $block_size)
      unless (0 == ($next_start % $block_size));
  }

  $configs{$config}{partitions}{$part_id}{start_byte} =
    $next_start;

  if (1 == $part_id) {
    $max_avail = $current_disk->{end_byte} + 1 - $next_start;
    $max_avail = "${max_avail}B";
  }
  my ($start, $end) = &make_range($part->{size}->{range}, $max_avail);

  # check, whether the size is fixed
  if ($end != $start) {

    # the end of the current range (may be the end of the disk or some
    # preserved partition or an ntfs volume to be resized)
    my $end_of_range = -1;

   # minimum space required by all partitions, i.e., the lower ends of the
   # ranges
   # $min_req_space counts up to the next preserved partition or the
   # end of the disk
    my $min_req_space = 0;

    # maximum useful space
    my $max_space = 0;

    # inspect all remaining entries in the worklist
    foreach my $p (@{$worklist}) {

      # we have found the delimiter
      if ($configs{$config}{partitions}{$p}{size}{preserve} ||
        ($configs{$config}{partitions}{$p}{size}{resize} &&
          ($current_disk->{partitions}->{$p}->{filesystem} eq "ntfs"))) {
        $end_of_range = $current_disk->{partitions}->{$p}->{begin_byte};

        # logical partitions require the space for the EPBR to be left
        # out
        $end_of_range -= 2 * $current_disk->{sector_size}
          if (($configs{$config}{disklabel} eq "msdos") && ($p > 4));
        last;
      } elsif ($configs{$config}{partitions}{$p}{size}{extended}) {
        next;
      } else {
        my ($min_size, $max_size) = &make_range(
          $configs{$config}{partitions}{$p}{size}{range}, $max_avail);

        # logical partitions require the space for the EPBR to be left
        # out; in fact, even alignment constraints would have to be considered
        if (($configs{$config}{disklabel} eq "msdos")
          && ($p != $part_id) && ($p > 4)) {
          $min_size += 2 * $current_disk->{sector_size};
          $max_size += 2 * $current_disk->{sector_size};
        }

        $min_req_space += $min_size;
        $max_space     += $max_size;
      }
    }

    # set the end if we have reached the end of the disk
    $end_of_range = $current_disk->{end_byte} if (-1 == $end_of_range);

    my $available_space = $end_of_range - $next_start + 1;

    # the next boundary is closer than the minimal space that we need
    ($available_space < $min_req_space)
      and die "Insufficient space available for partition " .
        &make_device_name($disk, $part_id) . "\n";

    # the new size
    my $scaled_size = $end;
    $scaled_size = POSIX::floor(($end - $start) * 
      (($available_space - $min_req_space) /
          ($max_space - $min_req_space))) + $start
      if ($max_space > $available_space);

    ($scaled_size >= $start)
      or &internal_error("scaled size is smaller than the desired minimum");

    $start = $scaled_size;
    $end   = $start;
  }

  # partitions must end at the requested alignment
  my $end_byte = $next_start + $start - 1;
  $end_byte -= ($end_byte + 1) % $block_size;

  # set $start and $end to the effective values
  $start = $end_byte - $next_start + 1;
  $end   = $start;

  # write back the size spec in bytes
  $part->{size}->{range} = $start . "-" . $end;

  # then set eff_size to a proper value
  $part->{size}->{eff_size} = $start;

  # write the end byte to the configuration
  $part->{end_byte} = $end_byte;

  # set the next start
  $next_start = $part->{end_byte} + 1;

  return ($next_start, $max_avail);
}

################################################################################
#
# @brief Compute the desired sizes of the partitions and test feasibility
# thereof.
#
################################################################################
sub compute_partition_sizes
{

  # loop through all device configurations
  foreach my $config (keys %configs) {

    # for RAID, encrypted, tmpfs or LVM, there is nothing to be done here
    next if ($config eq "RAID" || $config eq "CRYPT" || $config eq "TMPFS" || $config =~ /^VG_./);
    ($config =~ /^PHY_(.+)$/) or &internal_error("invalid config entry $config");
    # nothing to be done, if this is a configuration for a virtual disk or a
    # disk without partitions
    next if ($configs{$config}{virtual} ||
      defined($configs{$config}{partitions}{0}));
    my $disk = $1; # the device name of the disk
    # test, whether $disk is a block special device
    (-b $disk) or die "$disk is not a valid device name\n";
    # reference to the current disk config
    defined ($current_config{$disk}) or
      &internal_error("Device $disk missing in \$disklist - check buggy");
    my $current_disk = $current_config{$disk};

    # align to sector boundary by default
    my $block_size = $current_disk->{sector_size};
    # align to cylinder boundary for msdos disklabels if at least one of the
    # partitions has to be preserved, for backward compatibility
    if ($configs{$config}{disklabel} eq "msdos" &&
      $configs{$config}{preserveparts} == 1) {
      $block_size = $current_disk->{sector_size} *
        $current_disk->{bios_sectors_per_track} *
        $current_disk->{bios_heads};
    }
    # but user-specified alignment wins no matter what
    defined ($configs{$config}{align_at}) and
      $block_size = $configs{$config}{align_at};

    (0 == $block_size % $current_disk->{sector_size}) or
      die "Alignment must be set to a multiple of the underlying disk sector size\n";

    # at various points the following code highly depends on the desired disk label!
    # initialise variables
    # the id of the extended partition to be created, if required
    my $extended = -1;

    # the id of the current extended partition, if any; this setup only caters
    # for a single existing extended partition!
    my $current_extended = -1;

    # find the first existing extended partition
    foreach my $part_id (&numsort(keys %{ $current_disk->{partitions} })) {
      if ($current_disk->{partitions}->{$part_id}->{is_extended}) {
        $current_extended = $part_id;
        last;
      }
    }

    # the start byte for the next partition - first partition starts at 1M as is
    # new default for most systems it seems
    my $next_start = 1024 * 1024;
    # force original start if first partition will be preserved
    $next_start = $current_disk->{partitions}->{1}->{begin_byte}
      if ($configs{$config}{partitions}{1}{size}{preserve});

    if ($configs{$config}{disklabel} eq "gpt") {
      # modify the disk to claim the space for the second partition table
      $current_disk->{end_byte} -= 33 * $current_disk->{sector_size};

    } elsif ($configs{$config}{disklabel} eq "gpt-bios") {
      # apparently parted insists in having some space left at the end too
      # modify the disk to claim the space for the second partition table
      $current_disk->{end_byte} -= 33 * $current_disk->{sector_size};

      # on gpt-bios we'll need an additional partition to store what doesn't fit
      # in the MBR; this partition must be at the beginning, but it should be
      # created at the very end such as not to invalidate indices of other
      # partitions
      $device = $config;
      &init_part_config("primary");
      $configs{$config}{gpt_bios_part} =
        (&phys_dev($partition_pointer_dev_name))[2];
      # enter the range into the hash
      $partition_pointer->{size}->{range} = "1-1";
      # retain the free space at the beginning and fix the position
      my $s = 1024 * 1024;
      if ($configs{$config}{partitions}{1}{size}{preserve})
      {
        # try to squeeze it in before first partition
        ($next_start - $s > 63 * $current_disk->{sector_size}) or
          die "Insufficient space before first and preserved partition to insert gpt-bios partiton\n";
        $partition_pointer->{start_byte} = $next_start - $s;
        $partition_pointer->{end_byte} = $next_start - 1;
      }
      else
      {
        $partition_pointer->{start_byte} = $next_start;
        $partition_pointer->{end_byte} = $next_start + $s - 1;
        $next_start += $s;
      }
      # set proper defaults
      $partition_pointer->{encrypt} = 0;
      $partition_pointer->{filesystem} = "-";
      $partition_pointer->{mountpoint} = "-";
    }

    # the size of a 100% partition (the 100% available to the user)
    my $max_avail = $current_disk->{end_byte} + 1 - $next_start;
    # expressed in bytes
    $max_avail = "${max_avail}B";

    # the list of partitions that we need to find start and end bytes for
    my @worklist = (&numsort(keys %{ $configs{$config}{partitions} }));

    while (scalar (@worklist))
    {

      # work on the first entry of the list
      my $part_id = $worklist[0];
      # reference to the current partition
      my $part = (\%configs)->{$config}->{partitions}->{$part_id};

      # msdos specific: deal with extended partitions
      if ($part->{size}->{extended}) {
        # handle logical partitions first
        if (scalar (@worklist) > 1) {
          my @old_worklist = @worklist;
          @worklist = ();
          my @primaries = ();
          foreach my $p (@old_worklist) {
            if ($p > 4) {
              push @worklist, $p;
            } else {
              push @primaries, $p;
            }
          }
          if (scalar (@worklist)) {
            push @worklist, @primaries;
            next;
          }
          @worklist = @primaries;
        }

        # make sure that there is only one extended partition
        ($extended == -1) or &internal_error("More than 1 extended partition");

        # set the local variable to this id
        $extended = $part_id;

        # determine the size of the extended partition
        &do_partition_extended($part_id, $config, $current_disk);

        # partition done
        shift @worklist;
      # the gpt-bios special partition is set up already
      } elsif (defined($configs{$config}{gpt_bios_part}) &&
        $configs{$config}{gpt_bios_part} == $part_id) {
        # partition done
        shift @worklist;
      # the partition $part_id must be preserved
      } elsif ($part->{size}->{preserve}) {
        $next_start = &do_partition_preserve($part_id, $config, $disk,
          $next_start, $max_avail);

        # partition done
        shift @worklist;
      } else {
        ($next_start, $max_avail) = &do_partition_real($part_id, $config,
          $disk, $next_start, $block_size, $max_avail, \@worklist);

        # msdos does not support partitions larger than 2TiB
        ($part->{size}->{eff_size} > (&convert_unit("2TiB") * 1024.0 *
            1024.0)) and die "msdos disklabel does not support partitions > 2TiB, please use disklabel:gpt or gpt-bios\n"
          if ($configs{$config}{disklabel} eq "msdos");
        # partition done
        shift @worklist;
      }
    }

    # check, whether there is sufficient space on the disk
    ($next_start > $current_disk->{end_byte} + 1)
      and die "Disk $disk is too small - at least $next_start bytes are required\n";

    # make sure, extended partitions are only created on msdos disklabels
    ($configs{$config}{disklabel} ne "msdos" && $extended > -1)
      and &internal_error("extended partitions are not supported by this disklabel");

    # ensure that we have done our work
    (defined ($configs{$config}{partitions}{$_}{start_byte})
        && defined ($configs{$config}{partitions}{$_}{end_byte}))
      or &internal_error("start or end of partition $_ not set")
        foreach (&numsort(keys %{ $configs{$config}{partitions} }));
  }
}

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

################################################################################
#
# @brief Collect all physical devices reference in the desired configuration
#
################################################################################
sub find_all_phys_devs {

  my @phys_devs = ();

  # loop through all configs
  foreach my $config (keys %configs) {

    if ($config =~ /^PHY_(.+)$/) {
      push @phys_devs, $1;
    } elsif ($config =~ /^VG_(.+)$/) {
      next if ($1 eq "--ANY--");
      foreach my $d (keys %{ $configs{$config}{devices} }) {
        my ($i_p_d, $disk, $part_no) = &phys_dev($d);
        push @phys_devs, $disk if (1 == $i_p_d);
      }
    } elsif ($config eq "RAID") {
      foreach my $r (keys %{ $configs{$config}{volumes} }) {
        foreach my $d (keys %{ $configs{$config}{volumes}{$r}{devices} }) {
          my ($i_p_d, $disk, $part_no) = &phys_dev($d);
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
      &internal_error("Unexpected key $config");
    }
  }

  return \@phys_devs;
}

################################################################################
#
# @brief Collect the current partition information from all disks listed both
# in $disks and $configs{PHY_<disk>}
#
################################################################################
sub get_current_disks {

  my %referenced_devs = ();
  @referenced_devs{ @{ &find_all_phys_devs() } } = ();

  # obtain the current state of all disks
  foreach my $disk (@disks) {
    # create full paths
    ($disk =~ m{^/}) or $disk = "/dev/$disk";

    exists ($referenced_devs{$disk}) or next;

    # make sure, $disk is a proper block device
    (-b $disk) or die "$disk is not a block special device!\n";

    # init device tree
    $current_dev_children{$disk} = ();

    # the list to hold the output of parted commands as parsed below
    my @parted_print = ();

    # try to obtain the partition table for $disk
    # it might fail with parted_2 in case the disk has no partition table
    my $error =
        &execute_ro_command("parted -s $disk unit TiB print", \@parted_print, 0);

    # possible problems
    if (!defined($configs{"PHY_$disk"}) && $error ne "") {
      warn "Could not determine size and contents of $disk, skipping\n";
      next;
    } elsif (defined($configs{"PHY_$disk"}) &&
      $configs{"PHY_$disk"}{preserveparts} == 1 && $error ne "") {
      die "Failed to determine size and contents of $disk, but partitions should have been preserved\n";
    }

    # write a fresh disklabel if no useable data was found and dry_run is not
    # set
    if ($error ne "" && $no_dry_run) {
      # write the disk label as configured
      my $label = $configs{"PHY_$disk"}{disklabel};
      $label = "gpt" if ($label eq "gpt-bios");
      $error = &execute_command("parted -s $disk mklabel $label");
      ($error eq "") or die "Failed to write disk label\n";
      # retry partition-table print
      $error =
        &execute_ro_command("parted -s $disk unit TiB print", \@parted_print, 0);
    }

    ($error eq "") or die "Failed to read the partition table from $disk\n";

    # disk is usable
    &push_command( "true", "", "exist_$disk" );

    # initialise the hash
    $current_config{$disk}{partitions} = {};


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
        || $line =~ /^Warning: Not all of the space available to/
        || $line =~ /^Warning: Unable to open \S+ read-write/);

      # determine the logical sector size
      if ($line =~ /^Sector size \(logical\/physical\): (\d+)B\/\d+B$/) {
        $current_config{$disk}{sector_size} = $1;
      }

      # read and store the current disk label
      elsif ($line =~ /^Partition Table: (.+)$/) {
        $current_config{$disk}{disklabel} = $1;
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

        defined ($cols{"Flags"}{"start"})
          or &internal_error("Column Flags not found in parted output");
        ($col_start == $cols{"Flags"}{"start"} + $cols{"Flags"}{"length"})
          or &internal_error("Flags column is not last");
      } else { # one of the partitions

        # we must have seen the header, otherwise probably the format has
        # changed
        defined ($cols{"File system"}{"start"})
          or &internal_error("Table header not yet seen while reading $line");

        # the info for the partition number
        my $num_cols_before = $cols{"Number"}{"start"};
        my $num_col_width   = $cols{"Number"}{"length"};

        # the info for the file system column
        my $fs_cols_before = $cols{"File system"}{"start"};
        my $fs_col_width   = $cols{"File system"}{"length"};

        # the info for the flags column
        my $flags_cols_before = $cols{"Flags"}{"start"};

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
        $current_config{$disk}{partitions}{$id}{filesystem} = $fs;

        # extract the file system information
        my $flags = "";
        if (length ($line) > $flags_cols_before) {
          $line =~ /^.{$flags_cols_before}(.+)$/;
          $flags = $1;
        }

        # remove any space
        $flags =~ s/\s//g;

        # store the information in the hash
        $current_config{$disk}{partitions}{$id}{flags} = $flags;
      }
    }

    # reset the output list
    @parted_print = ();

    # obtain the partition table using bytes as units
    $error =
      &execute_ro_command("parted -s $disk unit B print free", \@parted_print, 0);

    # Parse the output of the byte-wise partition table
    foreach my $line (@parted_print) {

      # the disk size line (Disk /dev/hda: 82348277759B)
      if ($line =~ /Disk \Q$disk\E: (\d+)B$/) {
        $current_config{$disk}{begin_byte} = 0;
        $current_config{$disk}{end_byte}   = $1 - 1;
        $current_config{$disk}{size}       = $1;

        # nothing else to be done
        next;
      }

      # One of the partition lines, see above example
      next unless ($line =~
        /^\s*(\d+)\s+(\d+)B\s+(\d+)B\s+(\d+)B(\s+(primary|logical|extended))?/i);

      # mark the bounds of existing partitions
      $current_config{$disk}{partitions}{$1}{begin_byte} = $2;
      $current_config{$disk}{partitions}{$1}{end_byte}   = $3;
      $current_config{$disk}{partitions}{$1}{count_byte} = $4;

      # is_extended defaults to false/0
      $current_config{$disk}{partitions}{$1}{is_extended} = 0;

      # but may be true/1 on msdos disk labels
      ( ( $current_config{$disk}{disklabel} eq "msdos" )
          && ( $6 eq "extended" ) )
        and $current_config{$disk}{partitions}{$1}{is_extended} = 1;

      # add entry in device tree
      push @{ $current_dev_children{$disk} }, &make_device_name($disk, $1);
    }

    # reset the output list
    @parted_print = ();

    # obtain the partition table using bytes as units
    $error =
      &execute_ro_command(
      "parted -s $disk unit chs print free", \@parted_print, 0);

    # Parse the output of the CHS partition table
    foreach my $line (@parted_print) {

   # find the BIOS geometry that looks like this:
   # BIOS cylinder,head,sector geometry: 10011,255,63.  Each cylinder is 8225kB.
      if ($line =~
        /^BIOS cylinder,head,sector geometry:\s*(\d+),(\d+),(\d+)\.\s*Each cylinder is \d+(\.\d+)?kB\.$/) {
        $current_config{$disk}{bios_cylinders}         = $1;
        $current_config{$disk}{bios_heads}             = $2;
        $current_config{$disk}{bios_sectors_per_track} = $3;
      }
    }

    # make sure we have determined all the necessary information
    ($current_config{$disk}{begin_byte} == 0)
      or die "Invalid start byte\n";
    ($current_config{$disk}{end_byte} > 0) or die "Invalid end byte\n";
    defined ($current_config{$disk}{size})
      or die "Failed to determine disk size\n";
    defined ($current_config{$disk}{sector_size})
      or die "Failed to determine sector size\n";
    defined ($current_config{$disk}{bios_sectors_per_track})
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
    $current_lvm_config{$vg}{physical_volumes} = ();

    # init device tree
    $current_dev_children{"VG_$vg"} = ();

    # store the vg size in MB
    my %vg_info = get_volume_group_information($vg);
    if (%vg_info) {
      $current_lvm_config{$vg}{size} = &convert_unit(
        $vg_info{vg_size} . $vg_info{vg_size_unit});
    } else {
      $current_lvm_config{$vg}{size} = "0";
    }

    # store the logical volumes and their sizes
    my %lv_info = get_logical_volume_information($vg);
    foreach my $lv_name (sort keys %lv_info) {
      my $short_name = $lv_name;
      $short_name =~ s{/dev/\Q$vg\E/}{};
      $current_lvm_config{$vg}{volumes}{$short_name}{size} =
        &convert_unit($lv_info{$lv_name}->{lv_size} .
          $lv_info{$lv_name}->{lv_size_unit});
      # add entry in device tree
      push @{ $current_dev_children{"VG_$vg"} }, $lv_name;
    }

    # store the physical volumes
    my %pv_info = get_physical_volume_information($vg);
    foreach my $pv_name (sort keys %pv_info) {
      push @{ $current_lvm_config{$vg}{physical_volumes} },
        abs_path($pv_name);

      # add entry in device tree
      push @{ $current_dev_children{abs_path($pv_name)} }, "VG_$vg";
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
    &execute_ro_command("mdadm --examine --scan --verbose -c partitions",
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
  open(MDADM_EX, ">$DATADIR/mdadm-from-examine.conf");

  # the id of the RAID
  my $id;

  # parse the output line by line
  foreach my $line (@mdadm_print) {
    print MDADM_EX "$line";
    if ($line =~ /^ARRAY \/dev\/md[\/]?(\d+)\s+/) {
      $id = $1;

      foreach (split (" ", $line)) {
        $current_raid_config{$id}{mode} = $1 if ($_ =~ /^level=(\S+)/);
      }
    } elsif ($line =~ /^\s*devices=(\S+)$/) {
      defined($id) or
        &internal_error("mdadm ARRAY line not yet seen -- unexpected mdadm output:\n"
        . join("", @mdadm_print));
      foreach my $d (split (",", $1)) {
        push @{ $current_raid_config{$id}{devices} }, abs_path($d);

        # add entry in device tree
        push @{ $current_dev_children{abs_path($d)} }, "/dev/md$id";
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
  my ($i_p_d, $disk, $part_no) = &phys_dev($device_name);

  if (1 == $i_p_d) {
    if (defined($configs{"PHY_$disk"}) &&
        defined($configs{"PHY_$disk"}{partitions}{$part_no})) {
      (defined ($current_config{$disk}) &&
        defined ($current_config{$disk}{partitions}{$part_no})) or die
        "Can't preserve $device_name because it does not exist\n";
      $configs{"PHY_$disk"}{partitions}{$part_no}{size}{preserve} = 1;
      $configs{"PHY_$disk"}{preserveparts} = 1;
    } elsif (0 == $missing) {
      (defined ($current_config{$disk}) &&
        defined ($current_config{$disk}{partitions}{$part_no})) or die
        "Can't preserve $device_name because it does not exist\n";
    }
  } elsif ($device_name =~ m{^/dev/md[\/]?(\d+)$}) {
    my $vol = $1;
    if (defined($configs{RAID}) &&
        defined($configs{RAID}{volumes}{$vol})) {
      defined ($current_raid_config{$vol}) or die
        "Can't preserve $device_name because it does not exist\n";
      if ($configs{RAID}{volumes}{$vol}{preserve} != 1) {
        $configs{RAID}{volumes}{$vol}{preserve} = 1;
        &mark_preserve($_, $configs{RAID}{volumes}{$vol}{devices}{$_}{missing})
          foreach (keys %{ $configs{RAID}{volumes}{$vol}{devices} });
      }
    } elsif (0 == $missing) {
      defined ($current_raid_config{$vol}) or die
        "Can't preserve $device_name because it does not exist\n";
    }
  } elsif ($device_name =~ m{^/dev/([^/\s]+)/([^/\s]+)$}) {
    my $vg = $1;
    my $lv = $2;
    if (defined($configs{"VG_$vg"}) &&
        defined($configs{"VG_$vg"}{volumes}{$lv})) {
      defined ($current_lvm_config{$vg}{volumes}{$lv}) or die
        "Can't preserve $device_name because it does not exist\n";
      if ($configs{"VG_$vg"}{volumes}{$lv}{size}{preserve} != 1) {
        $configs{"VG_$vg"}{volumes}{$lv}{size}{preserve} = 1;
        &mark_preserve($_, $missing) foreach (keys %{ $configs{"VG_$vg"}{devices} });
      }
    } elsif (0 == $missing) {
      defined ($current_lvm_config{$vg}{volumes}{$lv}) or die
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
  foreach my $config (keys %configs) {

    if ($config =~ /^PHY_(.+)$/) {
      defined ($current_config{$1}) or
        die "Device $1 was not specified in \$disklist\n";
      defined ($current_config{$1}{partitions}) or
        &internal_error("Missing key \"partitions\"");

      foreach my $part_id (&numsort(keys %{ $configs{$config}{partitions} })) {
        my $part = (\%configs)->{$config}->{partitions}->{$part_id};
        $part->{size}->{preserve} =
          (defined($current_config{$1}{partitions}{$part_id}) ? 1 : 0)
          if (2 == $part->{size}->{preserve});
        next unless ($part->{size}->{preserve} || $part->{size}->{resize});
        ($part->{size}->{extended}) and die
          "Preserving extended partitions is not supported; mark all logical partitions instead\n";
        if (0 != $part_id) {
          defined ($current_config{$1}{partitions}{$part_id}) or die
            "Can't preserve ". &make_device_name($1, $part_id)
              . " because it does not exist\n";
          defined ($part->{size}->{range}) or die
            "Can't preserve ". &make_device_name($1, $part_id)
              . " because it is not defined in the current config\n";
        }
      }
    } elsif ($config =~ /^VG_(.+)$/) {
      next if ($1 eq "--ANY--");
      # check for logical volumes that need to be preserved and preserve the
      # underlying devices recursively
      foreach my $l (keys %{ $configs{$config}{volumes} }) {
        $configs{$config}{volumes}{$l}{size}{preserve} =
          ((defined($current_lvm_config{$1}) &&
              defined($current_lvm_config{$1}{volumes}{$l})) ? 1 : 0)
          if (2 == $configs{$config}{volumes}{$l}{size}{preserve});
        next unless ($configs{$config}{volumes}{$l}{size}{preserve} == 1 ||
          $configs{$config}{volumes}{$l}{size}{resize} == 1);
        defined ($current_lvm_config{$1}{volumes}{$l}) or die
          "Can't preserve /dev/$1/$l because it does not exist\n";
        defined ($configs{$config}{volumes}{$l}{size}{range}) or die
          "Can't preserve /dev/$1/$l because it is not defined in the current config\n";
        &mark_preserve($_, 0) foreach (keys %{ $configs{$config}{devices} });
      }
    } elsif ($config eq "RAID") {
      # check for volumes that need to be preserved and preserve the underlying
      # devices recursively
      foreach my $r (keys %{ $configs{$config}{volumes} }) {
        $configs{$config}{volumes}{$r}{preserve} =
          (defined($current_raid_config{$r}) ? 1 : 0)
          if (2 == $configs{$config}{volumes}{$r}{preserve});
        next unless ($configs{$config}{volumes}{$r}{preserve} == 1);
        defined ($current_raid_config{$r}) or die
          "Can't preserve /dev/md$r because it does not exist\n";
        defined ($configs{$config}{volumes}{$r}{devices}) or die
          "Can't preserve /dev/md$r because it is not defined in the current config\n";
        &mark_preserve($_, $configs{$config}{volumes}{$r}{devices}{$_}{missing})
          foreach (keys %{ $configs{$config}{volumes}{$r}{devices} });
      }
    } elsif ($config eq "CRYPT") {
      # We don't do preserve for encrypted partitions
      next;
    } elsif ($config eq "TMPFS") {
      # We don't do preserve for tmpfs
      next;
    } else {
      &internal_error("Unexpected key $config");
    }
  }
}


1;
__END__
