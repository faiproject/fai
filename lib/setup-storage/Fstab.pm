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
# @file fstab.pm
#
# @brief Generate an fstab file as appropriate for the configuration
#
# @author Christian Kern, Michael Tautschnig
# @date Sun Jul 23 16:09:36 CEST 2006
#
################################################################################

package FAI;

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
  my $comment_line = "";

  # add a comment denoting the actual device name in case of UUID or LABEL
  $comment_line="# device during installation: $dev_name\n"
    if ($name =~ /^(UUID|LABEL)=/);

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

  # set the ROOT_PARTITION variable, if this is the mountpoint for /
  $FAI::disk_var{ROOT_PARTITION} = $name
    if ($d_ref->{mountpoint} eq "/");

  # add to the swaplist, if the filesystem is swap
  $FAI::disk_var{SWAPLIST} .= " " . $dev_name
    if ($d_ref->{filesystem} eq "swap");

  my $ret = "\n$comment_line";
  # join the columns of one line with tabs
  $ret .= join ("\t", @fstab_line);
  return $ret;
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
    &FAI::internal_error("Invalid key type $key_type");

  # write the device name as the first entry; if the user prefers uuids
  # or labels, use these if available
  my @uuid = ();
  `$FAI::udev_settle`;
  &FAI::execute_ro_command(
    "/sbin/blkid -c /dev/null -s UUID -o value $device_name", \@uuid, 0);

  # every device must have a uuid, otherwise this is an error (unless we
  # are testing only)
  ($FAI::no_dry_run == 0 || scalar (@uuid) == 1)
    or die "Failed to obtain UUID for $device_name.\n
      This may happen if the device was part of a RAID array in the past;\n
      in this case run mdadm --zero-superblock $device_name and retry\n";

  # get the label -- this is likely empty; exit code 3 if no label, but that is
  # ok here
  my @label = ();
  `$FAI::udev_settle`;
  &FAI::execute_ro_command(
    "/sbin/blkid -c /dev/null -s LABEL -o value $device_name", \@label, 0);

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
  my %config = @_;

  my $mnt_point = ".NO_SUCH_MOUNTPOINT";

  # walk through all configured parts
  foreach my $c (keys %config) {

    if ($c =~ /^PHY_(.+)$/) {
      foreach my $p (keys %{ $config{$c}->{partitions} }) {
        my $this_mp = $config{$c}->{partitions}->{$p}->{mountpoint};

        next if (!defined($this_mp));

        return $this_mp if ($this_mp eq "/boot");
        $mnt_point = $this_mp if ($this_mp eq "/");
      }
    } elsif ($c =~ /^VG_(.+)$/) {
      next if ($1 eq "--ANY--");
      foreach my $l (keys %{ $config{$c}->{volumes} }) {
        my $this_mp = $config{$c}->{volumes}->{$l}->{mountpoint};

        next if (!defined($this_mp));

        return $this_mp if ($this_mp eq "/boot");
        $mnt_point = $this_mp if ($this_mp eq "/");
      }
    } elsif ($c eq "BTRFS") {
      foreach my $b (keys %{ $config{$c}->{volumes}}) {
        my $this_mp = $config{$c}->{volumes}->{mountpoint};
        next if (!defined($this_mp));
        return $this_mp if ($this_mp eq "/boot");
        $mnt_point = $this_mp if ($this_mp eq "/");
      }
    } elsif ($c eq "RAID" || $c eq "CRYPT") {
      foreach my $r (keys %{ $config{$c}->{volumes} }) {
        my $this_mp = $config{$c}->{volumes}->{$r}->{mountpoint};

        next if (!defined($this_mp));

        return $this_mp if ($this_mp eq "/boot");
        $mnt_point = $this_mp if ($this_mp eq "/");
      }
    } elsif ($c eq "TMPFS") {
      # not usable for /boot
      next;
    } else {
      &FAI::internal_error("Unexpected key $c");
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
  my $boot_mnt_point = find_boot_mnt_point(%FAI::configs);

  # walk through all configured parts
  # the order of entries is most likely wrong, it is fixed at the end
  foreach my $c (keys %$config) {

    # entry is a physical device
    if ($c =~ /^PHY_(.+)$/) {
      my $device = $1;
      next if (exists($config->{$c}->{vg}) && $config->{$c}->{vg} == 1);
      # make sure the desired fstabkey is defined at all
      defined ($config->{$c}->{fstabkey})
        or &FAI::internal_error("fstabkey undefined");

      # create a line in the output file for each partition
      foreach my $p (keys %{ $config->{$c}->{partitions} }) {

        # keep a reference to save some typing
        my $p_ref = $config->{$c}->{partitions}->{$p};

        # skip extended partitions and entries without a mountpoint
        next if ($p_ref->{size}->{extended} || $p_ref->{mountpoint} eq "-");

        my $device_name = 0 == $p ? $device :
          &FAI::make_device_name($device, $p);

        # if the mount point the /boot mount point, variables must be set
        if ($p_ref->{mountpoint} eq $boot_mnt_point) {
          # set the BOOT_DEVICE and BOOT_PARTITION variables
          $FAI::disk_var{BOOT_PARTITION} = $device_name;
          $FAI::disk_var{BOOT_DEVICE} = $device;

        }

        push @fstab, create_fstab_line($p_ref,
          get_fstab_key($device_name, $config->{$c}->{fstabkey}), $device_name);

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
        $FAI::disk_var{BOOT_DEVICE} = $device_name
          if ($l_ref->{mountpoint} eq $boot_mnt_point);

        push @fstab, create_fstab_line($l_ref,
          get_fstab_key($device_name, $config->{"VG_--ANY--"}->{fstabkey}), $device_name);
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
        $FAI::disk_var{BOOT_DEVICE} = $device_name
          if ($r_ref->{mountpoint} eq $boot_mnt_point);

        push @fstab, create_fstab_line($r_ref,
          get_fstab_key($device_name, $config->{RAID}->{fstabkey}), $device_name);
      }
    } elsif ($c eq "BTRFS") {
      # cycles through the volume IDs
      foreach my $v (keys %{ $config->{$c}->{volumes} }) {

        # skip entries without a mountpoint
        next if ( $config->{$c}->{volumes}->{$v}->{mountpoint} eq "-");

        # get an array of devices that are part of the BTRFS RAID configuration
        my @device_names = keys %{ $config->{$c}->{volumes}->{$v}->{devices}};
        my $name_string = join(".", @device_names);

        # Only one of the BTRFS RAID devices are necessary to get the fstab key

        if (defined($config->{"BTRFS"}->{fstabkey})) {
          push @fstab, &FAI::create_fstab_line($config->{$c}->{volumes}->{$v},
                                               &FAI::get_fstab_key($device_names[0], $config->{"BTRFS"}->{fstabkey}), $name_string);
        } else {
          push @fstab, &FAI::create_fstab_line($config->{$c}->{volumes}->{$v},
                                               &FAI::get_fstab_key($device_names[0], $config->{$c}->{volumes}->{$v}->{fstabkey}), $device_names[0]);
        }
      }
    } elsif ($c eq "CRYPT") {
      foreach my $v (keys %{ $config->{$c}->{volumes} }) {
        my $c_ref = $config->{$c}->{volumes}->{$v};

        next if ($c_ref->{mountpoint} eq "-");

        my $device_name = &FAI::enc_name($c_ref->{device});

        ($c_ref->{mountpoint} eq $boot_mnt_point) and
          die "Boot partition cannot be encrypted\n";

        push @fstab, create_fstab_line($c_ref, $device_name, $device_name);
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

        push @fstab, create_fstab_line($c_ref, "tmpfs", "tmpfs");
      }
    } else {
      &FAI::internal_error("Unexpected key $c");
    }
  }

  # cleanup the swaplist (remove leading space and add quotes)
  $FAI::disk_var{SWAPLIST} =~ s/^\s*/"/;
  $FAI::disk_var{SWAPLIST} =~ s/\s*$/"/;

  # cleanup the list of boot devices (remove leading space and add quotes)
  $FAI::disk_var{BOOT_DEVICE} =~ s/^\s*/"/;
  $FAI::disk_var{BOOT_DEVICE} =~ s/\s*$/"/;

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

1;

