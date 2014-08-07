## no critic (RequireExplicitPackage RequireVersionVar ProhibitNoisyQuotes)

use strict;
use warnings;

use Test::More               tests => 14;
use Data::Dumper;

use Init;
use Volumes;
use Parser;
use Sizes;
use Commands;
use Fstab;
use Exec;

my $testdir = 't/Fstab/data';

# replace FAI::get_fstab_key with a custom function
# (the original function would require each partition/device to exist
#  since we would like to test a wide range of configuration this is
#  impossible to achieve -> replace actual function with a dummy)
{
	no warnings 'redefine';
	*FAI::get_fstab_key = \&my_get_fstab_key;
}

{
	my @testcases = (
		'TEST1_no-mountpoints',
		'TEST2_just-root+swap',
		'TEST3_multiswap',
		'TEST4_root+boot+swap',
		'TEST5_simple-md',
		'TEST6_lvm-no-boot',
		'TEST7_lvm-with-boot',
	);

	for my $testcase (@testcases) {
		my $input  = slurp_file("$testdir/$testcase.input");
		my $output = slurp_file("$testdir/$testcase.result");

		my %configs;            eval $input;
		my (@fstab, @disk_var); eval $output;

		#   @fstab @disk_vars
		my ($aref1, $aref2) = FAI::generate_fstab(\%configs);

		my @expected1 = @fstab;
		is_deeply($aref1, \@expected1, "$testcase: fstab")
		  or diag(Data::Dumper->Dump([$aref1], ['computed']));

		my @expected2 = @disk_var;
		is_deeply($aref2, \@expected2, "$testcase: disk_vars")
		  or diag(Data::Dumper->Dump([$aref2], ['computed']));
	}
}

sub slurp_file {
	my $filename = shift;

	open my $fh, '<', $filename
	  or die "Unable to open '$filename': $!";
	local $/;
	my $content = <$fh>;
	close $fh
	  or die "Unable to close filehandle for '$filename': $!\n";

	return $content;
}

sub my_get_fstab_key {
	my $device_name = shift;
	my $key_type = shift;

	if ($key_type eq 'uuid' and $device_name eq '/dev/md0') {
		return 'UUID=11e86ce7-2589-420d-9833-5186c2cd8a61';
	}
	else {
		return $device_name;
	}
}

1;
