#! /usr/bin/perl

# $Id$
#*********************************************************************
#
# Fai.pm -- subroutines used by /fai/class/S*.pl scripts
#
# This script is part of FAI (Fully Automatic Installation)
# Copyright (c) 1999-2000 by Thomas Lange, Universitaet zu Koeln
#
#*********************************************************************
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with this program; see the file COPYING. If not, write to the
# Free Software Foundation, Inc., 59 Temple Place - Suite 330, Boston,
# MA 02111-1307, USA.
#*********************************************************************

$hostname = $ENV{'HOSTNAME'};

# - - - - - - - - - - - - - - - - - - - - - - - - - - - -
sub read_all_info () {
  read_disk_info;
  read_memory_info;
  read_kernel_messages;
}
# - - - - - - - - - - - - - - - - - - - - - - - - - - - -
sub classes {

  # print a list of classes
  my @strings = @_;
  foreach (@strings) {
    print "$_\n";
  }
}
# - - - - - - - - - - - - - - - - - - - - - - - - - - - -
sub class {

  # print a list of classes and exit
  classes(@_);
  exit;
}
# - - - - - - - - - - - - - - - - - - - - - - - - - - - -
sub testsize {

  # test, if value is within a range
  # return 1 if size within range

  my ($value,$lower,$upper) = @_;
  return 1 if ($lower < $value && $value <= $upper);
  return 0;
}
# - - - - - - - - - - - - - - - - - - - - - - - - - - - -
sub read_disk_info {

  # disk_info set variables containing the information

  foreach ($ENV{device_size}=~ m#([a-z])\s+(\d+)#g) {
    my ($device,$blocks) = ($1,$2);
    $numdisks++;
    push @devicelist,$device;
    $blocks{$device} = $blocks;
  }

# I hope blocksize is constant !!!

#      my $device;
#      open ( DISK,"sfdisk -l|");
#      while (<DISK>) {
#  	if (m!^Disk\s/dev/(\w+)!) {
#  	    $device = $1;
#  	}
#  	if (m!blocks of\s*(\d+)\s*bytes!) {
#  	    my $bytes_per_block = $1;
#  	    # blocks -> Mbytes:
#  	    $size = $blocks{$device} * $bytes_per_block / (1024*1024) ;
#  	    $sum_disk_size += $size;
#  	    $disksize{$device} = $size;
#  	}
#      }
#      close DISK;
}
# - - - - - - - - - - - - - - - - - - - - - - - - - - - -
sub disksize {

    my ($disk,$lower,$upper) = @_;
    testsize($disksize{$disk},$lower,$upper);
}
# - - - - - - - - - - - - - - - - - - - - - - - - - - - -
sub read_memory_info {

  $size = -s "/proc/kcore";
  $size -=4*1024; # man 5 proc says, that kcore is phys. mem + 4KB
  $size /=(1024*1024); # return RAM in MB
}

sub memsize {

  my ($lower,$upper) = @_;
  testsize($ramsize,$lower,$upper);
}
# - - - - - - - - - - - - - - - - - - - - - - - - - - - -
sub read_kernel_messages {

  open (DMESG, "dmesg|");
  @dmesg =<DMESG>;
  close DMESG;

  # /var/log/messages* are not available during first installation
  return if -f "/tmp/FAI_INSTALLATION_IN_PROGRESS";
  open (LOGS,"zcat -f /var/log/messages*|");
  @messages =<LOGS>;
  close LOGS;
}
# - - - - - - - - - - - - - - - - - - - - - - - - - - - -
sub read_ethernet_info {

  read_kernel_messages();

# return map { m!\beth\d+:(.+)!} (@dmesg,@messages);
# some driver don't print eth0:
# so now we use:

  return (@dmesg,@messages);
}
# - - - - - - - - - - - - - - - - - - - - - - - - - - - -
1;
