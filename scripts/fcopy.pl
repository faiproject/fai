#! /usr/bin/perl

# $Id$
#*********************************************************************
#
# fcopy -- copy files using FAI classes and preserve directory structure
#
# This script is part of FAI (Fully Automatic Installation)
# (c) 2000 by Thomas Lange, lange@informatik.uni-koeln.de
# Universitaet zu Koeln
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
# A copy of the GNU General Public License is available as
# '/usr/share/common-licences/GPL' in the Debian GNU/Linux distribution
# or on the World Wide Web at http://www.gnu.org/copyleft/gpl.html.  You
# can also obtain it by writing to the Free Software Foundation, Inc.,
# 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.
#*********************************************************************

my $version = "version 1.0, 23-Dec-2000";

use File::Copy;
use File::Compare;
use File::Find;
use File::Path;
use File::Basename;
use Getopt::Std;
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
sub copy_one {

  # copy file $prefix/$source/$class to $target/$source

  my ($prefix,$source,$target) = @_;
  my ($class,$sourcefile,$destfile);
  my $ps = "$prefix/$source";
  my $tpath = "$target/" . dirname $source;

  # $prefix/$source must be a directory
  unless (-d $ps) { warn "$ps is not a directory\n";return }

  # use hostname if a config file 'hostname' exists
  # otherwise the last class for which a file exists is used
  foreach (@classes) {
    next unless -f "$ps/$_";
    $class = $_;
    last if ($class eq $host)
  }

  unless (defined $class) {
    warn "No matching file for any class for $source defined\n";
    # do not copy
    return;
  }

  $sourcefile = "$ps/$class";
  $destfile = "$target/$source";
  # do nothing if source and destination files are equal
  compare($sourcefile,$destfile) || return;

  # create subdirectories, if they do not exist
  unless (-d $tpath) {
    mkpath($tpath,$debug,0777);
  }

  # save existing file, add suffix .fcopy
  # what should I, if $destfile is a symlink ?
  move($destfile,"$destfile.fcopy") if -f $destfile;
  if (copy($sourcefile,$destfile)) {
    print "Copied $sourcefile to $destfile.\n" ;
    set_mode($ps,$destfile,$class);
  } else {
    warn "Copy $sourcefile to $destfile failed. $!\n" ;
  } 
}
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
sub name2num {

  # convert names to numeric uid, gid
  my ($user,$group) = @_;

  my $uid = ($user  =~ /^\d+$/) ? $user  : getpwnam $user;
  my $gid = ($group =~ /^\d+$/) ? $group : getgrnam $group;
  warn "name2id $user = $uid ; $group = $gid\n" if $debug;
  return ($uid,$gid);
}
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
sub set_mode {

  # set target file's owner, group, mode and time
  # use owner,group,mode from -m or from the file file-modes or
  # use the values from the source file
  my ($sourcefile,$destfile,$class) = @_;
  my ($uid,$gid,$owner,$group,$mode);
  # get uid,gid,mode,mtime from source file
  my ($stime,@defmodes) = (stat("$sourcefile/$class"))[9,4,5,2];

  if ($modeset) { # use -m values
    ($owner,$group,$mode) = @opt_modes;
  } elsif (-f "$sourcefile/file-modes"){
    ($owner,$group,$mode) = read_file_mode("$sourcefile/file-modes",$class);
  } else { # use values from source file
    ($owner,$group,$mode) = @defmodes;
  }

  ($uid,$gid) = name2num($owner,$group);
  warn "chown/chmod u:$uid g:$gid m:$mode $destfile\n" if $debug; 
  chown ($uid,$gid,     $destfile) || warn "chown $owner $group $destfile failed. $!\n";
  chmod ($mode,         $destfile) || warn "chmod $mode $destfile failed. $!\n";
  utime ($stime,$stime, $destfile) || warn "utime for $destfile failed. $!\n";
}
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
sub check_mopt {

  # save and check -m options
  $modeset = 1;
  my $n = @opt_modes = split(/,/,$opt_m);
  ($n != 3) &&
    die "Wrong number of options for -m. Exact 3 comma separated items needed.\n";
   unless ($opt_modes[2] =~/^[0-7]+$/) {
     die "File mode $opt_modes[2] should be an octal number\n";
   }
  $opt_modes[2] = oct($opt_modes[2]);
}
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
sub read_file_mode {

  my ($modefile,$class) = @_;
  my ($owner,$group,$mode,$fclass,@defaults);

  warn "reading $modefile" if $verbose;
  open (MODEFILE,"<$modefile") || die "Can't open $modefile\n";
  while (<MODEFILE>) {
    ($owner,$group,$mode,$fclass) = split;
    # class found
    return ($owner,$group,$mode) if ($fclass eq $class);
    # when no class is specified use data for all classes
    $fclass or @defaults = ($owner,$group,$mode);
  }
  close MODEFILE;
  return @defaults if @defaults;
  warn "No modes found for $class\n";
}
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
sub read_classes {

  # read class names from a file
  my $file = shift;
  my @classes;

  open(CLASS,$file) || die "Can't open class file $file. $!\n";
  while (<CLASS>) {
    next if /^#/;
    push @classes, split;
  }
  close CLASS;
  return @classes;
}
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
sub usage {

  print << "EOF";
fcopy $version

Usage: fcopy [OPTION] ... SOURCE ...
EOF
  exit 0;
}
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# main program

getopts('s:t:rm:vdc:C:h');
$opt_h && usage;
$host = $ENV{HOST};
$opt_m && check_mopt();
$verbose = $opt_v || $ENV{verbose} || 0;
$debug   = $opt_d || $ENV{debug}   || 0;
$source  = $opt_s || $ENV{FAI_FILES};
$target  = $opt_t || $ENV{FAI_ROOT};
@classes = qw/$ENV{classes}/;
$opt_c and @classes = split /,/,$opt_c;
$opt_C and @classes = read_classes($opt_C);
print join ' ','Classes:',@classes,"\n" if $debug;
die "Source undefined\n" unless $source;
die "Target undefined\n" unless $target;

if ($opt_r) {
  my $pathes = join ' ',@ARGV;
# TODO: use File::Find
  @ARGV = split /\n/, `cd  $source ; find $pathes -links 2`;
}

foreach (@ARGV) { copy_one($source,$_,$target); }

$usage = << "EOF";
fcopy: copy a list of files to its destination directories

  fcopy [options] ... SOURCE ...

fcopy copies a file from a source directory to a target directory if a
class is defined which matches a filename in the source directory.

In the source tree for each file to be copied, a directory must exist,
which contains a file for every class that should copy this file.

You have to create a directory for every file that should be copied to
the install client. The directory structure will be preserved. Copy a
template file for a class with a filename equal to the class to this
directory. This file is copied to the target directory, if the
appropriate class is defined. Source files are located in files/ in
your configuration space.

Example:
Suppose the source directory /files/etc/X11/XF86Config contains following files:

DEFAULT
LAB
CAD
MACH64
server1
faifoo
file-modes

Each file is an instance for a XF86Config file exept for
file-modes. The command

    fcopy -t /tmp/target -s /files /etc/X11/XF86Config

copies one of these files to /tmp/target/etc/XF86Config. If a file is
found which is equal to the hostname, this file will be
copied. Otherwise the last class to which the host belongs is
used. Since all hosts belong to the class DEFAULT, this file is used,
when no other class matches. All hosts, that belong to class DEFAULT
and LAB use file LAB as its XF86Config, host 'server99' which belongs
to classes DEFAULT, MACH64 and server99 will use file MACH64. The host
'faifoo' uses config file faifoo independent to which other classes it
belongs.

User, group and permissions for the files can be defined in several
ways. Option -m has the highest priority and will be used for all
files, if specified. The file file-modes in the source directory can
contain one line for each class. The space separated parameter are:

owner group mode class

If class is missing, the data is used for all classes. If neither -m
or file-modes data is available, the user, group and mode of the
source file will be used. Missing subdirectories be be created with
mode 0777. If the destination file already exists and is different
from the source file, suffix .fcopy is appended. If the files are
equal no copy is performed.

call this program for every leaf directory: find -links 2 | xargs fcopy
options:
-r recursive (traverse down the tree)
-c classes comma separated
-t target dir (default $FAI_ROOT)
-s source dir (default $FAI_FILES)
-m user, group and mode (mode as octal)
-v verbose output
-d debug output
-C file
This script can also be used to maintain your configuration of the cluster
TODO: create a log file ? log all copied files to stderr/stdout
copy a list of files from $source to $target
use all classes and a file file-modes for permissions
EOF
