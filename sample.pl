#!/usr/bin/perl

use EZDBI 'mysql:test' => 'username', 'password';

Insert 'into names values', 'Harry', 'Potter';

if (Select q{* from names where first = 'Harry'} ) {
  print "Potter is IN THE HOUSE.\n";
}

for (Select 'last from names') {
  next if $seen{$_}++;
  my @first = Select 'first from names where last = ?', $_;
  print "$_: @first\n";
}

Delete q{from names where last='Potter'};

if (Select q{* from names where first = 'Potter'} ) {
  die "Can't get rid of that damn Harry Potter!";
}

