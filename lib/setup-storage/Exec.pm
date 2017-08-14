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
# @file exec.pm
#
# @brief functions to execute system commands
#
# @author Christian Kern, Michael Tautschnig
# @date Sun Jul 23 16:09:36 CEST 2006
#
################################################################################

use File::Temp;

package FAI;

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
$FAI::error_codes = [
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
  {
    error        => "parted_3_2",
    message      => "Parted could not read a disk label (new disk?)\n",
    stderr_regex => "Error: .* unrecognised disk label",
    stdout_regex => "",
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
  ##   response     => \&FAI::restore_partition_table,
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
    program      => "mdadm --assemble --scan --config=$FAI::DATADIR/mdadm-from-examine.conf",
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
  my @treffer = grep { $_->{error} eq "$error" } @$FAI::error_codes;

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
  my @treffer = grep { $_->{error} eq "$error" } @$FAI::error_codes;

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
# error output of the bash command
#
# @return the identifier of the error
#
################################################################################
sub execute_command {

  my ($command, $stdout, $stderr) = @_;

  my $err = &execute_command_internal($command, $stdout, $stderr,1);

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

  # backup value of $FAI::no_dry_run
  my $no_dry_run = $FAI::no_dry_run;

  # set no_dry_run to perform read-only commands always
  $FAI::no_dry_run = 1;

  my $err = &execute_command_internal($command, $stdout, $stderr,0);

  # reset no_dry_run
  $FAI::no_dry_run = $no_dry_run;

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
# @param print command or don't
#
# @return the identifier of the error
#
################################################################################
sub execute_command_internal {

  my ($command, $stdout_ref, $stderr_ref,$prt) = @_;

  my @stderr      = ();
  my @stdout      = ();
  my $stderr_line = "";
  my $stdout_line = "";
  my $exit_code   = 0;

  #make tempfile, get perl filehandle and filename of the file
  my ($stderr_fh, $stderr_filename) = File::Temp::tempfile(UNLINK => 1);
  my ($stdout_fh, $stdout_filename) = File::Temp::tempfile(UNLINK => 1);

  $FAI::debug and $prt=1; # always print if in debug mode

  # do only execute the given command, when in no_dry_mode
  if ($FAI::no_dry_run) {

    $FAI::debug
      and print "(CMD) $command 1> $stdout_filename 2> $stderr_filename\n";

    # execute the bash command, write stderr and stdout into the testfiles
    print "Executing: $command\n" if $prt;
    `$command 1> $stdout_filename 2> $stderr_filename`;
    $exit_code = ($?>>8);
  } else {
    print "DRY-RUN $command\n";
    return "";
  }

  # read the tempfile into lists, each element of the list one line
  @stderr = <$stderr_fh>;
  @stdout = <$stdout_fh>;

  #when closing the files, the tempfiles are removed too
  close ($stderr_fh);
  close ($stdout_fh);

  #print stderr and stdout when -d is set
  #perhaps always print stdout?
  $FAI::debug and print "(STDERR) $_" foreach (@stderr);
  $FAI::debug and print "(STDOUT) $_" foreach (@stdout);

  #if the stderr contains information, get the first line for error recognition
  $stderr_line = $stderr[0] if (scalar (@stderr));

  #see last comment
  $stdout_line = $stdout[0] if (scalar (@stdout));

  #if an array is passed to the function, it is filled with the stdout
  @$stdout_ref = @stdout if ('ARRAY' eq ref ($stdout_ref));

  #see above
  @$stderr_ref = @stderr if ('ARRAY' eq ref ($stderr_ref));

  #get the error, if there was any
  foreach my $err (@$FAI::error_codes) {
    if (($err->{stdout_regex} eq "" || $stdout_line =~ /$err->{stdout_regex}/)
        && ($err->{stderr_regex} eq "" || $stderr_line =~ /$err->{stderr_regex}/)
        && ($err->{program} eq "" || $command =~ /$err->{program}/)
        && (grep {$_ == $exit_code} @{ $err->{exit_codes} })) {

      if ($err->{error} =~ /catch_all_nonzero_exit_code/) {
        print "(STDERR) $_" foreach (@stderr);
        print "(STDOUT) $_" foreach (@stdout);
      }

      return $err->{error};
    }
  }

}

1;

