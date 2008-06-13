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
# $Id$
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
    defined ($FAI::current_config{$dev}{end_byte})
      or die "$dev is not a valid block device\n";

    # the size is known, return it
    return ($FAI::current_config{$dev}{end_byte} -
        $FAI::current_config{$dev}{begin_byte}) / (1024 * 1024);
  }

  # try a partition
  elsif (1 == $i_p_d && $part_no > -1) {
    # the size is configured, return it
    defined ($FAI::configs{"PHY_$disk"}{partitions}{$part_no}{size}{eff_size})
      and return $FAI::configs{"PHY_$disk"}{partitions}{$part_no}{size}{eff_size} /
      (1024 * 1024);

    # the size is known from the current configuration on disk, return it
    defined ($FAI::current_config{$disk}{partitions}{$part_no}{count_byte})
      and return $FAI::current_config{$disk}{partitions}{$part_no}{count_byte} /
      (1024 * 1024);

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

    # let's see, whether there is a configuration of this volume
    if (defined ($FAI::configs{RAID}{volumes}{$1}{devices})) {
      @devs  = keys %{ $FAI::configs{RAID}{volumes}{$1}{devices} };
      $level = $FAI::configs{RAID}{volumes}{$1}{mode};
    } elsif (defined ($FAI::current_raid_config{$1}{devices})) {
      @devs  = $FAI::current_raid_config{$1}{devices};
      $level = $FAI::current_raid_config{$1}{mode};
    } else {
      die "$dev is not a known RAID device\n";
    }

    # prepend "raid", if the mode is numeric-only
    $level = "raid$level" if ($level =~ /^\d+$/);

    # the number of devices in the volume
    my $dev_count = scalar (@devs);

    # now do the mode-specific size estimations
    if ($level =~ /^raid[015]$/) {
      my $min_size = &estimate_size(shift @devs);
      foreach (@devs) {
        my $s = &FAI::estimate_size($_);
        $min_size = $s if ($s < $min_size);
      }

      return $min_size * POSIX::floor($dev_count / 2)
        if ($level eq "raid1");
      return $min_size * $dev_count if ($level eq "raid0");
      return $min_size * ($dev_count - 1) if ($level eq "raid5");
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

    # for RAID or physical disks there is nothing to be done here
    next if ($config eq "RAID" || $config =~ /^PHY_./);
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
      $vg_size += &FAI::estimate_size($dev);
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
      my ($start, $end) = &FAI::make_range($lv_size->{range}, "${vg_size}MB");
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
        $lv_size->{eff_size} = $start;
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

    # update all sizes that are still ranges
    foreach my $lv (@redist_list) {

      # get the range again
      my ($start, $end) =
      &FAI::make_range($FAI::configs{$config}{volumes}{$lv}{size}{range}, "${vg_size}MB");
      # make them MB
      $start /= 1024.0 * 1024.0;
      $end /= 1024.0 * 1024.0;

      # write the final size
      $FAI::configs{$config}{volumes}{$lv}{size}{eff_size} =
        $start + (($end - $start) * $redist_factor);
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
# @param $min_req_total_space Minimum space required on disk
#
# @return Updated values of ($next_start, $min_req_total_space)
#
################################################################################
sub do_partition_preserve {

  my ($part_id, $config, $current_disk, $next_start, $min_req_total_space) = @_;

  # reference to the current partition
  my $part = (\%FAI::configs)->{$config}->{partitions}->{$part_id};

  # a partition that should be preserved must exist already
  defined($current_disk->{partitions}->{$part_id})
    or die "$part_id can't be preserved, it does not exist.\n";

  my $curr_part = $current_disk->{partitions}->{$part_id};

  ($next_start > $curr_part->{begin_byte})
    and die "Previous partitions overflow begin of preserved partition $part_id\n";

  # set the effective size to the value known already
  $part->{size}->{eff_size} = $curr_part->{count_byte};

  # copy the start_byte and end_byte information
  $part->{start_byte} = $curr_part->{begin_byte};
  $part->{end_byte} = $curr_part->{end_byte};

  # and add it to the total disk space required by this config
  $min_req_total_space += $part->{size}->{eff_size};

  # set the next start
  $next_start = $part->{end_byte} + 1;

  # several msdos specific parts
  if ($FAI::configs{$config}{disklabel} eq "msdos") {

    # make sure the partition ends at a cylinder boundary
    (0 == ($curr_part->{end_byte} + 1)
        % ($current_disk->{sector_size} *
          $current_disk->{bios_sectors_per_track} *
          $current_disk->{bios_heads})) or 
      die "Preserved partition $part_id does not end at a cylinder boundary\n";

    # add one head of disk usage if this is a logical partition
    $min_req_total_space += $current_disk->{bios_sectors_per_track} *
      $current_disk->{sector_size} if ($part_id > 4);

    # extended partitions consume no space
    if ($part->{size}->{extended}) {

      # revert the addition of the size
      $min_req_total_space -= $part->{size}->{eff_size};

      # set the next start to the start of the extended partition
      $next_start = $part->{start_byte};
    }
  }

  # on gpt, ensure that the partition ends at a sector boundary
  if ($FAI::configs{$config}{disklabel} eq "gpt") {
    (0 == ($current_disk->{partitions}{$part_id}{end_byte} + 1)
        % $current_disk->{sector_size})
      or die "Preserved partition $part_id does not end at a sector boundary\n";
  }

  return ($next_start, $min_req_total_space);
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
  my $part = (\%FAI::configs)->{$config}->{partitions}->{$part_id};

  ($FAI::configs{$config}{disklabel} eq "msdos")
    or die "found an extended partition on a non-msdos disklabel\n";

  # ensure that it is a primary partition
  ($part_id <= 4) or
    &FAI::internal_error("Extended partition wouldn't be a primary one");

  my $epbr_size = $current_disk->{bios_sectors_per_track} *
    $current_disk->{sector_size};

  # initialise the size and the start byte
  $part->{size}->{eff_size} = 0;
  $part->{start_byte} = -1;

  foreach my $p (&numsort(keys %{ $FAI::configs{$config}{partitions} })) {
    next if ($p < 5);

    $part->{start_byte} = $FAI::configs{$config}{partitions}{$p}{start_byte} -
      $epbr_size if (-1 == $part->{start_byte});

    $part->{size}->{eff_size} += $FAI::configs{$config}{partitions}{$p}{size}{eff_size} +
      $epbr_size;

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
# @param $current_disk Current config of this disk
# @param $next_start Start of the next partition
# @param $min_req_total_space Minimum space required on disk
# @param $worklist Reference to the remaining partitions
#
# @return Updated values of ($next_start, $min_req_total_space)
#
################################################################################
sub do_partition_real {

  my ($part_id, $config, $current_disk, $next_start, $min_req_total_space,
    $worklist) = @_;

  # reference to the current partition
  my $part = (\%FAI::configs)->{$config}->{partitions}->{$part_id};

  my ($start, $end) = &FAI::make_range($part->{size}->{range},
    $current_disk->{size} . "B");

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
        if (($FAI::configs{$config}{disklabel} eq "msdos")
          && ($p > 4)) {
          $end_of_range -= $current_disk->{bios_sectors_per_track} *
            $current_disk->{sector_size};
        }
        last;
      } elsif ($FAI::configs{$config}{partitions}{$p}{size}{extended}) {
        next;
      } else {
        my ($min_size, $max_size) = &FAI::make_range(
          $FAI::configs{$config}{partitions}{$p}{size}{range},
          $current_disk->{size} . "B");

        # logical partitions require the space for the EPBR to be left
        # out
        if (($FAI::configs{$config}{disklabel} eq "msdos")
          && ($p > 4)) {
          $min_size += $current_disk->{bios_sectors_per_track} *
            $current_disk->{sector_size};
          $max_size += $current_disk->{bios_sectors_per_track} *
            $current_disk->{sector_size};
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
      and die "Insufficient space available for partition $part_id\n";

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

  # now we compute the effective locations on the disk
  # msdos specific offset for logical partitions
  if (($FAI::configs{$config}{disklabel} eq "msdos")
    && ($part_id > 4)) {

    # add one head of disk usage if this is a logical partition
    $min_req_total_space += $current_disk->{bios_sectors_per_track} *
      $current_disk->{sector_size};

    # move the start byte as well
    $next_start += $current_disk->{bios_sectors_per_track} *
      $current_disk->{sector_size};
  }

  # partition starts at where we currently are, or remains fixed in case of
  # resized ntfs
  if ($FAI::configs{$config}{partitions}{$part_id}{size}{resize} &&
    ($current_disk->{partitions}->{$part_id}->{filesystem} eq "ntfs")) {
    ($next_start <= $current_disk->{partitions}->{$part_id}->{begin_byte}) 
      or die "Cannot preserve start byte of ntfs volume on partition $part_id, space before it is too small\n";
    $next_start = $current_disk->{partitions}->{$part_id}->{begin_byte};
  }
  $FAI::configs{$config}{partitions}{$part_id}{start_byte} =
    $next_start;

  # the end may need some alignment, depending on the disk label
  my $end_byte = $next_start + $start - 1;

  # on msdos, ensure that the partition ends at a cylinder boundary
  if ($FAI::configs{$config}{disklabel} eq "msdos") {
    $end_byte -=
      ($end_byte + 1) % ($current_disk->{sector_size} *
        $current_disk->{bios_sectors_per_track} *
        $current_disk->{bios_heads});
  }

  # on gpt, ensure that the partition ends at a sector boundary
  if ($FAI::configs{$config}{disklabel} eq "gpt") {
    $end_byte -=
      ($end_byte + 1) % $current_disk->{sector_size};
  }

  # set $start and $end to the effective values
  $start = $end_byte - $next_start + 1;
  $end   = $start;

  # write back the size spec in bytes
  $part->{size}->{range} = $start . "-" . $end;

  # then set eff_size to a proper value
  $part->{size}->{eff_size} = $start;

  # write the end byte to the configuration
  $part->{end_byte} = $end_byte;

  # and add it to the total disk space required by this config
  $min_req_total_space += $part->{size}->{eff_size};

  # set the next start
  $next_start = $part->{end_byte} + 1;

  return ($next_start, $min_req_total_space);
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

    # for RAID or LVM, there is nothing to be done here
    next if ($config eq "RAID" || $config =~ /^VG_./);
    ($config =~ /^PHY_(.+)$/) or &FAI::internal_error("invalid config entry $config");
    # nothing to be done, if this is a configuration for a virtual disk
    next if $FAI::configs{$config}{virtual};
    my $disk = $1; # the device name of the disk
    # test, whether $disk is a block special device
    (-b $disk) or die "$disk is not a valid device name\n";
    # reference to the current disk config
    my $current_disk = $FAI::current_config{$disk};

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

    # the space required on the disk
    my $min_req_total_space = 0;

    # the start byte for the next partition
    my $next_start = 0;

    # on msdos disk labels, the first partitions starts at head #1
    if ($FAI::configs{$config}{disklabel} eq "msdos") {
      $next_start = $current_disk->{bios_sectors_per_track} *
        $current_disk->{sector_size};

      # the MBR requires space, too
      $min_req_total_space += $current_disk->{bios_sectors_per_track} *
        $current_disk->{sector_size};
    }

    # on GPT disk labels the first 34 and last 34 sectors must be left alone
    if ($FAI::configs{$config}{disklabel} eq "gpt") {
      $next_start = 34 * $current_disk->{sector_size};

      # modify the disk to claim the space for the second partition table
      $current_disk->{end_byte} -= 34 * $current_disk->{sector_size};

      # the space required by the GPTs
      $min_req_total_space += 2 * 34 * $current_disk->{sector_size};
    }

    # the list of partitions that we need to find start and end bytes for
    my @worklist = (&numsort(keys %{ $FAI::configs{$config}{partitions} }));

    while (scalar (@worklist))
    {

      # work on the first entry of the list
      my $part_id = $worklist[0];
      # reference to the current partition
      my $part = (\%FAI::configs)->{$config}->{partitions}->{$part_id};

      # the partition $part_id must be preserved
      if ($part->{size}->{preserve}) {
        ($next_start, $min_req_total_space) = &FAI::do_partition_preserve($part_id, 
          $config, $current_disk, $next_start, $min_req_total_space);

        # partition done
        shift @worklist;
      }

      # msdos specific: deal with extended partitions
      elsif ($part->{size}->{extended}) {
        # make sure that there is only one extended partition
        ($extended == -1 || 1 == scalar (@worklist))
          or &FAI::internal_error("More than 1 extended partition");

        # set the local variable to this id
        $extended = $part_id;

        # the size cannot be determined now, push it to the end of the
        # worklist; the check against $extended being == -1 ensures that
        # there is no indefinite loop
        if (scalar (@worklist) > 1) {
          push @worklist, shift @worklist;
          next;
        }

        # determine the size of the extended partition
        &FAI::do_partition_extended($part_id, $config, $current_disk);

        # partition done
        shift @worklist;
      } else {
        ($next_start, $min_req_total_space) = &FAI::do_partition_real($part_id, 
          $config, $current_disk, $next_start, $min_req_total_space, \@worklist);

        # partition done
        shift @worklist;
      }
    }

    # check, whether there is sufficient space on the disk
    ($min_req_total_space > $current_disk->{size})
      and die "Disk $disk is too small - at least $min_req_total_space bytes are required\n";

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

