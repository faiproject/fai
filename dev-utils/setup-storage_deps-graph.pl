#!/usr/bin/perl -w

use strict;

my $latest_cmd = undef;
my $latest_pre = undef;
my $latest_post = undef;
my %lines = ();

while (<>) {
  if (/^Trying to add CMD: (.*)$/) {
    defined($latest_cmd) and die;
    defined($latest_pre) and die;
    defined($latest_post) and die;
    $latest_cmd = $1;
    $latest_cmd =~ s/"/\\"/g;
  } elsif (/^PRE: ?(.+)?$/) {
    defined($latest_cmd) or die;
    defined($latest_pre) and die;
    defined($latest_post) and die;
    if (defined($1)) {
      $latest_pre = $1;
    } else {
      $latest_pre = "START";
    }
  } elsif (/^POST: ?(.+)?$/) {
    defined($latest_cmd) or die;
    defined($latest_pre) or die;
    defined($latest_post) and die;
    if (defined($1)) {
      $latest_post = $1;
    } else {
      $latest_post = "END";
    }
  } elsif (/^\s*$/) {
    next;
  } else {
    die;
  }
  
  if (defined($latest_post)) {
    foreach my $pre (split(/,/, $latest_pre)) {
      $pre =~ s/\//__/g;
      foreach my $post (split(/,/, $latest_post)) {
        $post =~ s/\//__/g;
        $lines{"$pre -> $post [label=\"$latest_cmd\"];"} = ();
      }
    }
    $latest_cmd = undef;
    $latest_pre = undef;
    $latest_post = undef;
  }
}

print "digraph D {\n";
print "$_\n" foreach(keys %lines);
print "}\n";

