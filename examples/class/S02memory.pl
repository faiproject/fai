#! /usr/bin/perl

# define classes for different memory configurations

use Debian::Fai;

$ramsize = read_memory_info();

# rules for classes

memsize(0,200) and class("MEMORY_200MB");
memsize(200,500) and class("MEMORY_500MB");
memsize(500,9000) and class("MEMORY_9GB");

exit;
