#
# interface test for 'handle_oldstyle_encrypt_device()'
#
# manual execution:
#  perl -I 'lib/setup-storage/' t/Commands_handle_oldstyle_encrypt_device.t

## no critic (RequireExplicitPackage RequireEndWithOne ProhibitPackageVars)

use strict;
use warnings;

use Data::Dumper;
use Test::More;

use Commands;                # FAI::handle_oldstyle_encrypt_device()

subtest 'not an encrypted device'
  => \&test_noconfig;
subtest 'a single encrypted device [old syntax]'
  => \&test_encrypt;
subtest 'a single encrypted device [old syntax with randinit]'
  => \&test_encrypt_randinit;
subtest 'multiple encrypted devices [old syntax]'
  => \&test_nextitem;
subtest 'preserve an encrypted device (1/2) [old syntax]'
  => \&test_preserve1;
subtest 'preserve an encrypted device (2/2) [old syntax]'
  => \&test_preserve2;

done_testing();

# --------------------------------------------------------------------------
# disk_config sda
# primary  /  10G  ext3  -
# --------------------------------------------------------------------------
sub test_noconfig {
	plan tests => 3;

	# input variables
	my $i_device = '/dev/sda1';
	my %i_partition = (
		'journal_dev' => undef,
		'encrypt' => 0,
		'start_byte' => 1048576,
		'mountpoint' => '/',
		'mount_options' => '-',
		'size' => {
			'resize' => 0,
			'always_format' => 0,
			'range' => '10737418240-10737418240',
			'preserve' => 0,
			'eff_size' => '10737418240',
			'extended' => 0
		},
		'filesystem' => 'ext3',
		'end_byte' => '10738466815'
	);
	my %i_configs = (
		'PHY_/dev/sda' => {
			'opts_all' => {},
			'preserveparts' => 0,
			'disklabel' => 'msdos',
			'partitions' => {
				'1' => {
					'journal_dev' => undef,
					'encrypt' => 0,
					'start_byte' => 1048576,
					'mountpoint' => '/',
					'mount_options' => '-',
					'size' => {
						'resize' => 0,
						'always_format' => 0,
						'range' => '10737418240-10737418240',
						'preserve' => 0,
						'eff_size' => '10737418240',
						'extended' => 0
					},
					'filesystem' => 'ext3',
					'end_byte' => '10738466815'
				},
			},
			'fstabkey' => 'device',
			'bootable' => -1,
			'virtual' => 0
		}
	);

	my $e_device = '/dev/sda1';
	my %e_partition = (
		'encrypt' => 0,
		'end_byte' => '10738466815',
		'filesystem' => 'ext3',
		'journal_dev' => undef,
		'mount_options' => '-',
		'mountpoint' => '/',
		'size' => {
			'always_format' => 0,
			'eff_size' => '10737418240',
			'extended' => 0,
			'preserve' => 0,
			'range' => '10737418240-10737418240',
			'resize' => 0
		},
		'start_byte' => 1048576
	);
	my %e_configs = (
		'PHY_/dev/sda' => {
			'bootable' => -1,
			'disklabel' => 'msdos',
			'fstabkey' => 'device',
			'opts_all' => {},
			'partitions' => {
				'1' => {
					'encrypt' => 0,
					'end_byte' => '10738466815',
					'filesystem' => 'ext3',
					'journal_dev' => undef,
					'mount_options' => '-',
					'mountpoint' => '/',
					'size' => {
						'always_format' => 0,
						'eff_size' => '10737418240',
						'extended' => 0,
						'preserve' => 0,
						'range' => '10737418240-10737418240',
						'resize' => 0
					},
					'start_byte' => 1048576
				}
			},
			'preserveparts' => 0,
			'virtual' => 0
		}
	);

	my $device    = $i_device;
	my $partition = \%i_partition;
	%FAI::configs = %i_configs;

	&FAI::handle_oldstyle_encrypt_device($device, $partition);

	my $r_device    = $device;
	my %r_partition = %{$partition};
	my %r_configs   = %FAI::configs;

	is($r_device, $e_device,                'variable $device');
	is_deeply(\%r_partition, \%e_partition, 'variable $partition');
	is_deeply(\%r_configs,   \%e_configs,   'variable %FAI::configs');

	return;
}

# --------------------------------------------------------------------------
# disk_config sda
# primary  /:encrypt  10G  ext3  -
# --------------------------------------------------------------------------
sub test_encrypt {

	# input variables
	my %i_configs = (
		'PHY_/dev/sda' => {
			'bootable' => -1,
			'disklabel' => 'msdos',
			'fstabkey' => 'device',
			'opts_all' => {},
			'partitions' => {
				'1' => {
					'encrypt' => 1,
					'end_byte' => '10738466815',
					'filesystem' => 'ext3',
					'journal_dev' => undef,
					'mount_options' => '-',
					'mountpoint' => '/',
					'size' => {
						'always_format' => 0,
						'eff_size' => '10737418240',
						'extended' => 0,
						'preserve' => 0,
						'range' => '10737418240-10737418240',
						'resize' => 0
					},
					'start_byte' => 1048576
				}
			},
			'preserveparts' => 0,
			'virtual' => 0
		}
	);
	my $i_device    = '/dev/sda1';
	my $i_partition = $i_configs{'PHY_/dev/sda'}->{'partitions'}->{'1'};

	my %e_configs = (
		'CRYPT' => {
			'fstabkey' => 'device',
			'randinit' => 0,
			'volumes' => {
				'0' => {
					'createopts' => undef,
					'device' => '/dev/sda1',
					'filesystem' => 'ext3',
					'mode' => 'luks',
					'mount_options' => '-',
					'mountpoint' => '/',
					'preserve' => 0,
					'tuneopts' => undef
				}
			}
		},
		'PHY_/dev/sda' => {
			'bootable' => -1,
			'disklabel' => 'msdos',
			'fstabkey' => 'device',
			'opts_all' => {},
			'partitions' => {
				'1' => {
					'encrypt' => 1,
					'end_byte' => '10738466815',
					'filesystem' => '-',
					'journal_dev' => undef,
					'mount_options' => '-',
					'mountpoint' => '-',
					'size' => {
						'always_format' => 0,
						'eff_size' => '10737418240',
						'extended' => 0,
						'preserve' => 0,
						'range' => '10737418240-10737418240',
						'resize' => 0
					},
					'start_byte' => 1048576
				}
			},
			'preserveparts' => 0,
			'virtual' => 0
		}
	);
	my $e_device    = '/dev/sda1';
	my $e_partition = $e_configs{'PHY_/dev/sda'}->{'partitions'}->{'1'};

	execute_test(
		[ \%i_configs, $i_device, $i_partition ],
		[ \%e_configs, $e_device, $e_partition ],
	);

	return;
}

# --------------------------------------------------------------------------
# disk_config sda
# primary  /:encrypt:randinit  10G  ext3  -
# --------------------------------------------------------------------------
sub test_encrypt_randinit {

	# input variables
	my %i_configs = (
		'PHY_/dev/sda' => {
			'bootable' => -1,
			'disklabel' => 'msdos',
			'fstabkey' => 'device',
			'opts_all' => {},
			'partitions' => {
				'1' => {
					'encrypt' => 2,
					'end_byte' => '10738466815',
					'filesystem' => 'ext3',
					'journal_dev' => undef,
					'mount_options' => '-',
					'mountpoint' => '/',
					'size' => {
						'always_format' => 0,
						'eff_size' => '10737418240',
						'extended' => 0,
						'preserve' => 0,
						'range' => '10737418240-10737418240',
						'resize' => 0
					},
					'start_byte' => 1048576
				}
			},
			'preserveparts' => 0,
			'virtual' => 0
		}
	);
	my $i_device = '/dev/sda1';
	my $i_partition = $i_configs{'PHY_/dev/sda'}->{'partitions'}->{'1'};

	my %e_configs = (
		'CRYPT' => {
			'fstabkey' => 'device',
			'randinit' => 1,
			'volumes' => {
				'0' => {
					'createopts' => undef,
					'device' => '/dev/sda1',
					'filesystem' => 'ext3',
					'mode' => 'luks',
					'mount_options' => '-',
					'mountpoint' => '/',
					'preserve' => 0,
					'tuneopts' => undef
				}
			}
		},
		'PHY_/dev/sda' => {
			'bootable' => -1,
			'disklabel' => 'msdos',
			'fstabkey' => 'device',
			'opts_all' => {},
			'partitions' => {
				'1' => {
					'encrypt' => 2,
					'end_byte' => '10738466815',
					'filesystem' => '-',
					'journal_dev' => undef,
					'mount_options' => '-',
					'mountpoint' => '-',
					'size' => {
						'always_format' => 0,
						'eff_size' => '10737418240',
						'extended' => 0,
						'preserve' => 0,
						'range' => '10737418240-10737418240',
						'resize' => 0
					},
					'start_byte' => 1048576
				}
			},
			'preserveparts' => 0,
			'virtual' => 0
		}
	);
	my $e_device = '/dev/sda1';
	my $e_partition = $e_configs{'PHY_/dev/sda'}->{'partitions'}->{'1'};

	execute_test(
		[ \%i_configs, $i_device, $i_partition ],
		[ \%e_configs, $e_device, $e_partition ],
	);


	return;
}

# --------------------------------------------------------------------------
# disk_config sda
# primary  -                     10G  ext3  -
# primary  /m2:encrypt:randinit  10G  xfs   -
#
# disk_config cryptsetup
# luks  /m1  sda1  ext3  -
# --------------------------------------------------------------------------
sub test_nextitem {

	# input variables
	my %i_configs = (
		'CRYPT' => {
			'fstabkey' => 'device',
			'randinit' => 0,
			'volumes' => {
				'0' => {
					'device' => '/dev/sda1',
					'encrypt' => 0,
					'filesystem' => 'ext3',
					'journal_dev' => undef,
					'mode' => 'luks',
					'mount_options' => '-',
					'mountpoint' => '/m1',
					'preserve' => 0
				}
			}
		},
		'PHY_/dev/sda' => {
			'bootable' => -1,
			'disklabel' => 'msdos',
			'fstabkey' => 'device',
			'opts_all' => {},
			'partitions' => {
				'1' => {
					'encrypt' => 0,
					'end_byte' => '10738466815',
					'filesystem' => 'ext3',
					'journal_dev' => undef,
					'mount_options' => '-',
					'mountpoint' => '-',
					'size' => {
						'always_format' => 0,
						'eff_size' => '10737418240',
						'extended' => 0,
						'preserve' => 0,
						'range' => '10737418240-10737418240',
						'resize' => 0
					},
					'start_byte' => 1048576
				},
				'2' => {
					'encrypt' => 2,
					'end_byte' => '21475885055',
					'filesystem' => 'xfs',
					'journal_dev' => undef,
					'mount_options' => '-',
					'mountpoint' => '/m2',
					'size' => {
						'always_format' => 0,
						'eff_size' => '10737418240',
						'extended' => 0,
						'preserve' => 0,
						'range' => '10737418240-10737418240',
						'resize' => 0
					},
					'start_byte' => '10738466816'
				}
			},
			'preserveparts' => 0,
			'virtual' => 0
		}
	);
	my $i_device = '/dev/sda2';
	my $i_partition = $i_configs{'PHY_/dev/sda'}->{'partitions'}->{'2'};

	my %e_configs = (
		'CRYPT' => {
			'fstabkey' => 'device',
			'randinit' => 1,
			'volumes' => {
				'0' => {
					'device' => '/dev/sda1',
					'encrypt' => 0,
					'filesystem' => 'ext3',
					'journal_dev' => undef,
					'mode' => 'luks',
					'mount_options' => '-',
					'mountpoint' => '/m1',
					'preserve' => 0
				},
				'1' => {
					'createopts' => undef,
					'device' => '/dev/sda2',
					'filesystem' => 'xfs',
					'mode' => 'luks',
					'mount_options' => '-',
					'mountpoint' => '/m2',
					'preserve' => 0,
					'tuneopts' => undef
				}
			}
		},
		'PHY_/dev/sda' => {
			'bootable' => -1,
			'disklabel' => 'msdos',
			'fstabkey' => 'device',
			'opts_all' => {},
			'partitions' => {
				'1' => {
					'encrypt' => 0,
					'end_byte' => '10738466815',
					'filesystem' => 'ext3',
					'journal_dev' => undef,
					'mount_options' => '-',
					'mountpoint' => '-',
					'size' => {
						'always_format' => 0,
						'eff_size' => '10737418240',
						'extended' => 0,
						'preserve' => 0,
						'range' => '10737418240-10737418240',
						'resize' => 0
					},
					'start_byte' => 1048576
				},
				'2' => {
					'encrypt' => 2,
					'end_byte' => '21475885055',
					'filesystem' => '-',
					'journal_dev' => undef,
					'mount_options' => '-',
					'mountpoint' => '-',
					'size' => {
						'always_format' => 0,
						'eff_size' => '10737418240',
						'extended' => 0,
						'preserve' => 0,
						'range' => '10737418240-10737418240',
						'resize' => 0
					},
					'start_byte' => '10738466816'
				}
			},
			'preserveparts' => 0,
			'virtual' => 0
		}
	);
	my $e_device = '/dev/sda2';
	my $e_partition = $e_configs{'PHY_/dev/sda'}->{'partitions'}->{'2'};

	execute_test(
		[ \%i_configs, $i_device, $i_partition ],
		[ \%e_configs, $e_device, $e_partition ],
	);

	return;
}

# --------------------------------------------------------------------------
# no config - %FAI::configs was manually edited
# --------------------------------------------------------------------------
sub test_preserve1 {

	# input variables
	my %i_configs = (
		'PHY_/dev/sda' => {
			'bootable' => -1,
			'disklabel' => 'msdos',
			'fstabkey' => 'device',
			'opts_all' => {},
			'partitions' => {
				'1' => {
					'encrypt' => 1,
					'end_byte' => '10738466815',
					'filesystem' => 'ext3',
					'journal_dev' => undef,
					'mount_options' => '-',
					'mountpoint' => '/',
					'size' => {
						'always_format' => 0,
						'eff_size' => '10737418240',
						'extended' => 0,
						'preserve' => 1,
						'range' => '10737418240-10737418240',
						'resize' => 0
					},
					'start_byte' => 1048576
				}
			},
			'preserveparts' => 0,
			'virtual' => 0
		}
	);
	my $i_device    = '/dev/sda1';
	my $i_partition = $i_configs{'PHY_/dev/sda'}->{'partitions'}->{'1'};

	my %e_configs = (
		'CRYPT' => {
			'fstabkey' => 'device',
			'randinit' => 0,
			'volumes' => {
				'0' => {
					'createopts' => undef,
					'device' => '/dev/sda1',
					'filesystem' => 'ext3',
					'mode' => 'luks',
					'mount_options' => '-',
					'mountpoint' => '/',
					'preserve' => 1,
					'tuneopts' => undef
				}
			}
		},
		'PHY_/dev/sda' => {
			'bootable' => -1,
			'disklabel' => 'msdos',
			'fstabkey' => 'device',
			'opts_all' => {},
			'partitions' => {
				'1' => {
					'encrypt' => 1,
					'end_byte' => '10738466815',
					'filesystem' => '-',
					'journal_dev' => undef,
					'mount_options' => '-',
					'mountpoint' => '-',
					'size' => {
						'always_format' => 0,
						'eff_size' => '10737418240',
						'extended' => 0,
						'preserve' => 1,
						'range' => '10737418240-10737418240',
						'resize' => 0
					},
					'start_byte' => 1048576
				}
			},
			'preserveparts' => 0,
			'virtual' => 0
		}
	);
	my $e_device    = '/dev/sda1';
	my $e_partition = $e_configs{'PHY_/dev/sda'}->{'partitions'}->{'1'};

	execute_test(
		[ \%i_configs, $i_device, $i_partition ],
		[ \%e_configs, $e_device, $e_partition ],
	);

	return;
}

# --------------------------------------------------------------------------
# no config - %FAI::configs was manually edited
# --------------------------------------------------------------------------
sub test_preserve2 {

	# input variables
	my %i_configs = (
		'PHY_/dev/sda' => {
			'bootable' => -1,
			'disklabel' => 'msdos',
			'fstabkey' => 'device',
			'opts_all' => {},
			'partitions' => {
				'1' => {
					'encrypt' => 1,
					'end_byte' => '10738466815',
					'filesystem' => 'ext3',
					'journal_dev' => undef,
					'mount_options' => '-',
					'mountpoint' => '/',
					'preserve' => 1,
					'start_byte' => 1048576
				}
			},
			'preserveparts' => 0,
			'virtual' => 0
		}
	);
	my $i_device    = '/dev/sda1';
	my $i_partition = $i_configs{'PHY_/dev/sda'}->{'partitions'}->{'1'};

	my %e_configs = (
		'CRYPT' => {
			'fstabkey' => 'device',
			'randinit' => 0,
			'volumes' => {
				'0' => {
					'createopts' => undef,
					'device' => '/dev/sda1',
					'filesystem' => 'ext3',
					'mode' => 'luks',
					'mount_options' => '-',
					'mountpoint' => '/',
					'preserve' => 1,
					'tuneopts' => undef
				}
			}
		},
		'PHY_/dev/sda' => {
			'bootable' => -1,
			'disklabel' => 'msdos',
			'fstabkey' => 'device',
			'opts_all' => {},
			'partitions' => {
				'1' => {
					'encrypt' => 1,
					'end_byte' => '10738466815',
					'filesystem' => '-',
					'journal_dev' => undef,
					'mount_options' => '-',
					'mountpoint' => '-',
					'preserve' => 1,
					'start_byte' => 1048576
				}
			},
			'preserveparts' => 0,
			'virtual' => 0
		}
	);
	my $e_device    = '/dev/sda1';
	my $e_partition = $e_configs{'PHY_/dev/sda'}->{'partitions'}->{'1'};

	execute_test(
		[ \%i_configs, $i_device, $i_partition ],
		[ \%e_configs, $e_device, $e_partition ],
	);

	return;
}

# ==========================================================================

# execute_test(
#  [ \%i_configs, $i_device, $i_partition],           - input values
#  [ \%e_configs, $e_device, $e_partition],           - expected result
# );
sub execute_test {
	my %i_configs   = %{ $_[0]->[0] };
	my $i_device    =    $_[0]->[1];
	my $i_partition =    $_[0]->[2];
	my %e_configs   = %{ $_[1]->[0] };
	my $e_device    =    $_[1]->[1];
	my $e_partition =    $_[1]->[2];

	plan tests => 3;

	my $device    = $i_device;
	my $partition = $i_partition;
	%FAI::configs = %i_configs;

	&FAI::handle_oldstyle_encrypt_device($device, $partition);
	my $r_device    = $device;
	my $r_partition = $partition;
	my %r_configs   = %FAI::configs;

	is($r_device, $e_device, 'variable $device');

	is_deeply($r_partition, $e_partition, 'variable $partition')
	  or diag( Data::Dumper->Dump([ $r_partition ], [ '*partition' ]) );

	is_deeply(\%r_configs,   \%e_configs,   'variable %FAI::configs')
	  or diag( Data::Dumper->Dump([ \%r_configs ], [ '*FAI::configs' ]) );

	return;
}
