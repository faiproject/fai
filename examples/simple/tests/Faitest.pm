#! /usr/bin/perl

# Subroutines for automatic tests
#
# Copyright (C) 2009 Thomas Lange, lange@informatik.uni-koeln.de
# Based on the first version by Sebastian Hetze, 08/2008

package FAITEST;

my $errors = 0;

use strict;
use Getopt::Long;
use Pod::Usage;
#  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -  -
sub setup_test {

  my $verbose = 0;
  my $help = 0;
  my $man  = 0;
  $verbose = $ENV{'debug'} if $ENV{'debug'};

  my $result = GetOptions (
        "verbose=i" => \$verbose,
        "help" => \$help,
        "man" => \$man,

        );

  pod2usage(1) if $help;
  pod2usage(-exitstatus => 0, -verbose => 2) if $man;

  open(LOGFILE,">> $ENV{LOGDIR}/test.log") || die "Can't open test.log. $!";
  print LOGFILE "------------   Test $0 starting  ------------\n";
}

sub printresult {

  # write test result and set next test
  my ($nexttest) = @_;

  if ($errors > 0) {
    print STDERR  "\n===>  $0 FAILED with $errors errors\n";
    print LOGFILE "\n===>  $0 FAILED with $errors errors\n";
  } else {
    print STDERR  "\n===>  $0 PASSED successfully\n";
    print LOGFILE "\n===>  $0 PASSED successfully\n";
    print LOGFILE "NEXTTEST=$nexttest\n" if $nexttest;
  }
  close (LOGFILE);
  return $errors;
}

sub getDevByMount {

  my $mount = shift;
  my $dev = qx#mount|grep $mount|cut -d' ' -f1#;
  chomp $dev;
  return $dev
}

sub checkMdStat {

  my ($device, $expected) = @_;
  my ($value) = qx#grep -i "^$device\\b" /proc/mdstat# =~ m/$device\s*:\s*(.*)/i;

  if ($value eq $expected) {
    print LOGFILE "Check raid $device success\n";
    return 0;
  } else {
    print LOGFILE "Check raid $device FAILED.\n   Expect <$expected>\n   Found <$value>\n";
    $errors++;
    return 1;
  }
}

sub checkE2fsAttribute {

  my ($device, $attribute, $expected) = @_;

  # since attribute is a space separated list of attributes, IMO we must loop over
  # the list. Ask Sebastian again
  my ($value) = qx#tune2fs -l $device |grep -i "$attribute"# =~ m/$attribute:\s+(.*)/i;

  if ($value eq $expected) {
    print LOGFILE "Check $attribute for $device success\n";
    return 0;
  } else {
    print LOGFILE "Check $attribute for $device FAILED.\n   Expect <$expected>\n   Found  <$value>\n";

    $errors++;
    return 1;
  }
}

1;
