#! /usr/bin/perl

# define classes for different network card configurations

use Debian::Fai;

@ethernet = read_ethernet_info();

# rules for classes

foreach (@ethernet) {
  classes("3C905B","100MBIT") if /3Com\s+3c905B/;
  classes("3C90X") if /3Com 3c90x/;
  classes("PCI_NE2000") if /PCI\s+NE2000/;
  classes("DS211403") if /Digital\s+DS211403/;
  classes("100MBIT") if /100baseTx/;
}

exit;
