#! /usr/bin/perl

# read a disk config file and look for several partitions
# (c) Thomas Lange, 2001, lange@informatik.uni-koeln.de

sub match {
    # here you can add more definitions
    m#\s/scratch\s#          && print "NFS_SERVER SCRATCH ";
    m#\s/files/scratch\s#    && print "NFS_SERVER FILES_SCRATCH ";
    m#\s/tmp\s#              && print "TMP_PARTITION ";
    m#\s/fai-boot\s#         && print "FAI_BOOTPART ";
}

# main routine is read only for you
foreach $class ( $ENV{HOSTNAME}, split /\s+/, $ENV{classes}) {
  $file = "/fai/disk_config/$class";
  next unless -f $file;
  open (PART,"<$file") || die "Can't open $file\n";
  while (<PART>) {
    # skip comments
    next if /^#/;
    &match;
  }
  close PART;
  # read only one config file
  exit 0;
}
