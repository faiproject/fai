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
# @file sizes.pm
#
# @brief Compute the size of the partitions and volumes to be created
#
# @author Christian Kern, Michael Tautschnig
# @date Sun Jul 23 16:09:36 CEST 2006
#
################################################################################

package FAI;

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
sub make_range {

  use POSIX qw(ceil floor);

  my ($rstr, $size) = @_;
  # convert size to Bytes
  my $size_b = &FAI::convert_unit($size) * 1024.0 * 1024.0;
  # check the format of the string
  ($rstr =~ /^(\d+(\.\d+)?%?)-(\d+(\.\d+)?%?)$/) or &FAI::internal_error("Invalid range");
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
  ($end >= $start) or &FAI::internal_error("end < start");

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
  my ($i_p_d, $disk, $part_no) = &FAI::phys_dev($dev);
  if (1 == $i_p_d && -1 == $part_no) {
    (defined ($FAI::current_config{$dev}) &&
      defined ($FAI::current_config{$dev}{end_byte}))
        or die "$dev is not a valid block device\n";

    # the size is known, return it
    return ($FAI::current_config{$dev}{end_byte} -
        $FAI::current_config{$dev}{begin_byte}) / (1024 * 1024);
  }

  # try a partition
  elsif (1 == $i_p_d && $part_no > -1) {
    # the size is configured, return it
    defined ($FAI::configs{"PHY_$disk"}) and
      defined ($FAI::configs{"PHY_$disk"}{partitions}{$part_no}{size}{eff_size})
        and return $FAI::configs{"PHY_$disk"}{partitions}{$part_no}{size}{eff_size} /
        (1024 * 1024);

    # the size is known from the current configuration on disk, return it
    defined ($FAI::current_config{$disk}) and
      defined ($FAI::current_config{$disk}{partitions}{$part_no}{count_byte})
        and return $FAI::current_config{$disk}{partitions}{$part_no}{count_byte} /
        (1024 * 1024) unless defined ($FAI::configs{"PHY_$disk"}{partitions});

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
    if (defined ($FAI::configs{RAID}{volumes}{$1})) {
      my @devcands = keys %{ $FAI::configs{RAID}{volumes}{$1}{devices} };
      $dev_count = scalar(@devcands);
      # we can only estimate the sizes of existing volumes, assume the missing
      # ones aren't smaller
      foreach (@devcands) {
        $dev_count-- if ($FAI::configs{RAID}{volumes}{$1}{devices}{$_}{spare});
        next if ($FAI::configs{RAID}{volumes}{$1}{devices}{$_}{missing});
        push @devs, $_;
      }
      $level = $FAI::configs{RAID}{volumes}{$1}{mode};
    } elsif (defined ($FAI::current_raid_config{$1})) {
      @devs  = $FAI::current_raid_config{$1}{devices};
      $dev_count = scalar(@devs);
      $level = $FAI::current_raid_config{$1}{mode};
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
        my $s = &FAI::estimate_size($_);
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
  foreach my $config (keys %FAI::configs) {

    # for RAID, encrypted, tmpfs or physical disks there is nothing to be done here
    next if ($config eq "BTRFS" || $config eq "RAID" || $config eq "CRYPT" || $config eq "TMPFS" || $config =~ /^PHY_./);
    ($config =~ /^VG_(.+)$/) or &FAI::internal_error("invalid config entry $config");
    next if ($1 eq "--ANY--");
    my $vg = $1; # the volume group name

    # compute the size of the volume group; this is not exact, but should at
    # least give a rough estimation, we assume 1 % of overhead; the value is
    # stored in megabytes
    my $vg_size = 0;
    foreach my $dev (keys %{ $FAI::configs{$config}{devices} }) {

      # $dev may be a partition, an entire disk or a RAID device; otherwise we
      # cannot deal with it
      my $cur_size = &FAI::estimate_size($dev);
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
    foreach my $lv (keys %{ $FAI::configs{$config}{volumes} }) {
      # reference to the size of the current logical volume
      my $lv_size = (\%FAI::configs)->{$config}->{volumes}->{$lv}->{size};
      # get the effective sizes (in Bytes) from the range
      my ($start, $end) = &FAI::make_range($lv_size->{range}, "${vg_size}MiB");
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
      &FAI::make_range($FAI::configs{$config}{volumes}{$lv}{size}{range}, "${vg_size}MiB");
      # make them MB
      $start /= 1024.0 * 1024.0;
      $end /= 1024.0 * 1024.0;

      # write the final size
      $FAI::configs{$config}{volumes}{$lv}{size}{eff_size} =
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
  my $current_disk = $FAI::current_config{$disk};

  # reference to the current partition
  my $part = (\%FAI::configs)->{$config}->{partitions}->{$part_id};
  # full device name
  my $part_dev_name = &FAI::make_device_name($disk, $part_id);

  # a partition that should be preserved must exist already
  defined($current_disk->{partitions}->{$part_id})
    or die "$part_dev_name can't be preserved, it does not exist.\n";

  my $curr_part = $current_disk->{partitions}->{$part_id};

  ($next_start > $curr_part->{begin_byte})
    and die "Previous partitions overflow begin of preserved partition $part_dev_name\n"
    unless (defined($FAI::configs{$config}{opts_all}{preserve}));

  # get what the user desired
  my ($start, $end) = &FAI::make_range($part->{size}->{range}, $max_avail);
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
  if ($FAI::configs{$config}{disklabel} eq "msdos") {

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
      and die &FAI::internal_error("Preserve must not handle extended partitions\n");
  }

  # on gpt, ensure that the partition ends at a sector boundary
  if ($FAI::configs{$config}{disklabel} eq "gpt" ||
    $FAI::configs{$config}{disklabel} eq "gpt-bios") {
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

  my ($part_id, $config, $current_disk, $block_size) = @_;

  # reference to the current partition
  my $part = (\%FAI::configs)->{$config}->{partitions}->{$part_id};

  ($FAI::configs{$config}{disklabel} eq "msdos")
    or die "found an extended partition on a non-msdos disklabel\n";

  # ensure that it is a primary partition
  ($part_id <= 4) or
    &FAI::internal_error("Extended partition wouldn't be a primary one");

  # initialise the size and the start byte
  $part->{size}->{eff_size} = 0;
  $part->{start_byte} = -1;

  foreach my $p (&numsort(keys %{ $FAI::configs{$config}{partitions} })) {
    next if ($p < 5);

    if (-1 == $part->{start_byte}) {
      my $align_offset = 2 * $current_disk->{sector_size};
      $align_offset = $block_size if ($block_size > $align_offset);
      $part->{start_byte} = $FAI::configs{$config}{partitions}{$p}{start_byte}
        - $align_offset;
    }

    $part->{size}->{eff_size} +=
      $FAI::configs{$config}{partitions}{$p}{size}{eff_size} + (2 *
        $current_disk->{sector_size});

    $part->{end_byte} = $FAI::configs{$config}{partitions}{$p}{end_byte};
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
  my $current_disk = $FAI::current_config{$disk};

  # reference to the current partition
  my $part = (\%FAI::configs)->{$config}->{partitions}->{$part_id};

  # compute the effective start location on the disk
  # msdos specific offset for logical partitions
  $next_start += 2 * $current_disk->{sector_size}
    if (($FAI::configs{$config}{disklabel} eq "msdos") && ($part_id > 4));

  # partition starts at where we currently are + requested alignment, or remains
  # fixed in case of resized ntfs
  if ($FAI::configs{$config}{partitions}{$part_id}{size}{resize} &&
    ($current_disk->{partitions}->{$part_id}->{filesystem} eq "ntfs")) {
    ($next_start <= $current_disk->{partitions}->{$part_id}->{begin_byte})
      or die "Cannot preserve start byte of ntfs volume on partition $part_id, space before it is too small\n";
    $next_start = $current_disk->{partitions}->{$part_id}->{begin_byte};
  } else {
    $next_start += $block_size - ($next_start % $block_size)
      unless (0 == ($next_start % $block_size));
  }

  $FAI::configs{$config}{partitions}{$part_id}{start_byte} =
    $next_start;

  if (1 == $part_id) {
    $max_avail = $current_disk->{end_byte} + 1 - $next_start;
    $max_avail = "${max_avail}B";
  }

  unless ($part->{size}->{range}) {
    $part->{size}->{range} = '512-100%';
  }
  my ($start, $end) = &FAI::make_range($part->{size}->{range}, $max_avail);

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
      if ($FAI::configs{$config}{partitions}{$p}{size}{preserve} ||
        ($FAI::configs{$config}{partitions}{$p}{size}{resize} &&
          ($current_disk->{partitions}->{$p}->{filesystem} eq "ntfs"))) {
        $end_of_range = $current_disk->{partitions}->{$p}->{begin_byte};

        # logical partitions require the space for the EPBR to be left
        # out
        $end_of_range -= 2 * $current_disk->{sector_size}
          if (($FAI::configs{$config}{disklabel} eq "msdos") && ($p > 4));
        last;
      } elsif ($FAI::configs{$config}{partitions}{$p}{size}{extended}) {
        next;
      } else {
        my ($min_size, $max_size) = &FAI::make_range(
          $FAI::configs{$config}{partitions}{$p}{size}{range}, $max_avail);

        # logical partitions require the space for the EPBR to be left
        # out; in fact, even alignment constraints have to be considered
        if (($FAI::configs{$config}{disklabel} eq "msdos")
          && ($p != $part_id) && ($p > 4)) {
          my $align_offset = 2 * $current_disk->{sector_size};
          $align_offset = $block_size if ($block_size > $align_offset);
          $min_size += $align_offset;
          $max_size += $align_offset;
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
        &FAI::make_device_name($disk, $part_id) . "\n";

    # the new size
    my $scaled_size = $end;
    $scaled_size = POSIX::floor(($end - $start) *
      (($available_space - $min_req_space) /
          ($max_space - $min_req_space))) + $start
      if ($max_space > $available_space);

    ($scaled_size >= $start)
      or &FAI::internal_error("scaled size is smaller than the desired minimum");

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
  foreach my $config (keys %FAI::configs) {

    # for RAID, encrypted, tmpfs or LVM, there is nothing to be done here
    next if ($config eq "BTRFS" || $config eq "RAID" || $config eq "CRYPT" || $config eq "TMPFS" || $config =~ /^VG_./);
    ($config =~ /^PHY_(.+)$/) or &FAI::internal_error("invalid config entry $config");
    # nothing to be done, if this is a configuration for a virtual disk or a
    # disk without partitions
    next if ($FAI::configs{$config}{virtual} ||
      defined($FAI::configs{$config}{partitions}{0}));
    my $disk = $1; # the device name of the disk
    # test, whether $disk is a block special device
    (-b $disk) or die "$disk is not a valid device name\n";
    # reference to the current disk config
    defined ($FAI::current_config{$disk}) or
      &FAI::internal_error("Device $disk missing in \$disklist - check buggy");
    my $current_disk = $FAI::current_config{$disk};

    # align to sector boundary by default
    my $block_size = $current_disk->{sector_size};
    # align to cylinder boundary for msdos disklabels if at least one of the
    # partitions has to be preserved, for backward compatibility
    if ($FAI::configs{$config}{disklabel} eq "msdos" &&
      $FAI::configs{$config}{preserveparts} == 1) {
      $block_size = $current_disk->{sector_size} *
        $current_disk->{bios_sectors_per_track} *
        $current_disk->{bios_heads};
    }
    # but user-specified alignment wins no matter what
    defined ($FAI::configs{$config}{align_at}) and
      $block_size = $FAI::configs{$config}{align_at};

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
      if ($FAI::configs{$config}{partitions}{1}{size}{preserve});

    if ($FAI::configs{$config}{disklabel} eq "gpt") {
      # modify the disk to claim the space for the second partition table
      $current_disk->{end_byte} -= 33 * $current_disk->{sector_size};

    } elsif ($FAI::configs{$config}{disklabel} eq "gpt-bios") {
      # apparently parted insists in having some space left at the end too
      # modify the disk to claim the space for the second partition table
      $current_disk->{end_byte} -= 33 * $current_disk->{sector_size};

      # on gpt-bios we'll need an additional partition to store what doesn't fit
      # in the MBR; this partition must be at the beginning, but it should be
      # created at the very end such as not to invalidate indices of other
      # partitions
      $FAI::device = $config;
      &FAI::init_part_config("primary");
      $FAI::configs{$config}{gpt_bios_part} =
        (&FAI::phys_dev($FAI::partition_pointer_dev_name))[2];
      # enter the range into the hash
      $FAI::partition_pointer->{size}->{range} = "1-1";
      # retain the free space at the beginning and fix the position
      my $s = 1024 * 1024;
      if ($FAI::configs{$config}{partitions}{1}{size}{preserve})
      {
        # try to squeeze it in before first partition
        ($next_start - $s > 63 * $current_disk->{sector_size}) or
          die "Insufficient space before first and preserved partition to insert gpt-bios partiton\n";
        $FAI::partition_pointer->{start_byte} = $next_start - $s;
        $FAI::partition_pointer->{end_byte} = $next_start - 1;
      }
      else
      {
        $FAI::partition_pointer->{start_byte} = $next_start;
        $FAI::partition_pointer->{end_byte} = $next_start + $s - 1;
        $next_start += $s;
      }
      # set proper defaults
      $FAI::partition_pointer->{encrypt} = 0;
      $FAI::partition_pointer->{filesystem} = "-";
      $FAI::partition_pointer->{mountpoint} = "-";
    }

    # the size of a 100% partition (the 100% available to the user)
    my $max_avail = $current_disk->{end_byte} + 1 - $next_start;
    # expressed in bytes
    $max_avail = "${max_avail}B";

    # the list of partitions that we need to find start and end bytes for
    my @worklist = (&numsort(keys %{ $FAI::configs{$config}{partitions} }));

    while (scalar (@worklist))
    {

      # work on the first entry of the list
      my $part_id = $worklist[0];
      # reference to the current partition
      my $part = (\%FAI::configs)->{$config}->{partitions}->{$part_id};

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
        ($extended == -1) or &FAI::internal_error("More than 1 extended partition");

        # set the local variable to this id
        $extended = $part_id;

        # determine the size of the extended partition
        &FAI::do_partition_extended($part_id, $config, $current_disk,
          $block_size);

        # partition done
        shift @worklist;
      # the gpt-bios special partition is set up already
      } elsif (defined($FAI::configs{$config}{gpt_bios_part}) &&
        $FAI::configs{$config}{gpt_bios_part} == $part_id) {
        # partition done
        shift @worklist;
      # the partition $part_id must be preserved
      } elsif ($part->{size}->{preserve}) {
        $next_start = &FAI::do_partition_preserve($part_id, $config, $disk,
          $next_start, $max_avail);

        # partition done
        shift @worklist;
      } else {
        ($next_start, $max_avail) = &FAI::do_partition_real($part_id, $config,
          $disk, $next_start, $block_size, $max_avail, \@worklist);

        # msdos does not support partitions larger than 2TiB
        ($part->{size}->{eff_size} > (&FAI::convert_unit("2TiB") * 1024.0 *
            1024.0)) and die "msdos disklabel does not support partitions > 2TiB, please use disklabel:gpt or gpt-bios\n"
          if ($FAI::configs{$config}{disklabel} eq "msdos");
        # partition done
        shift @worklist;
      }
    }

    # check, whether there is sufficient space on the disk
    ($next_start > $current_disk->{end_byte} + 1)
      and die "Disk $disk is too small - at least $next_start bytes are required\n";

    # make sure, extended partitions are only created on msdos disklabels
    ($FAI::configs{$config}{disklabel} ne "msdos" && $extended > -1)
      and &FAI::internal_error("extended partitions are not supported by this disklabel");

    # ensure that we have done our work
    (defined ($FAI::configs{$config}{partitions}{$_}{start_byte})
        && defined ($FAI::configs{$config}{partitions}{$_}{end_byte}))
      or &FAI::internal_error("start or end of partition $_ not set")
        foreach (&numsort(keys %{ $FAI::configs{$config}{partitions} }));
  }
}

1;

