
package EZDBI;
use DBI;
use strict;
use Carp;
use vars '$E', '@EXPORT', '$VERSION';

$VERSION = '0.04';

# Note that this package does NOT inherit from Exporter
@EXPORT = qw(Insert Select Update Delete DBcommand);

# select '* from TABLE WHERE...'
#   returns array of rows in list context
#   returns ref to such array in scalar context
#   each row is an array ref when the query starts with "*" or "a, b"
#   each row is a single value when the query starts with "a from"

my $DBH;
*E = \$DBI::errstr;
my $MAX_STH = 10;

# use EZDBI 'DBTYPE' => args...
sub import {
  my ($package, $type, @args) = @_;

  my $caller = caller;
  if (defined $type) {
    Connect($type, @args) ;
  } else {
    push @EXPORT, 'Connect';
  }

  for my $func (@EXPORT) {
    no strict 'refs';
    *{"$caller\::$func"} = \&$func;
  }
}

sub Connect {
  my ($type, @args) = @_;

  unless ($DBH = DBI->connect("DBI:$type", @args)) {
    croak "Couldn't connect to database: $E";
  }
}


# Update "set a=?, b=? where ...", ...;
sub Update {
  my ($str, @args) = @_;
  my $sth = _substitute('Update', $str, @args);
  my $rc;
  unless ($rc = $sth->execute(@args)) {
    croak "update failed: $E";
  }
  $sth->finish();
  $rc;
}

sub Insert {
  my ($str, @args) = @_;
  my $sth = _substitute('Insert', $str, @args);
  my $rc;
  unless ($rc = $sth->execute(@args)) {
    croak "insert failed: $E";
  }
  $sth->finish();
  $rc;
}

sub Delete {
  my ($str, @args) = @_;
  my $sth = _substitute('Delete', $str, @args);
  my $rc;
  unless ($rc = $sth->execute(@args)) {
    croak "delete failed: $E";
  }
  $sth->finish();
  $rc;
}

# TODO: Write a SelectHash version
#       SelectOne, SelectOneHash
sub Select {
  my ($str, @args) = @_;
  my ($columns) = ($str =~ /^\s*(.*\S+)\s+from\s+/i);

  unless (defined wantarray) {
    croak "Select in void context";
  }

  if ($columns =~ /^\*/ || $columns =~ /,/) {
    $columns = 'many';
  } else {
    $columns = 'one';
  }

  my @r;
  my $sth = _substitute('Select', $str, @args);
  unless ($sth->execute(@args)) {
    croak "select failed: $E";
  }

  while (my $row = $sth->fetchrow_arrayref) {
    if ($columns eq 'many') {
      push @r, [@$row];
    } else {
      push @r, $row->[0];
    }
  }

  my $n = $sth->rows;
  $sth->finish();
  return wantarray ? @r : $n;
}

# DBcommand "grant blah where blah blah blah";
sub DBcommand {
  my $caller = caller;
  unless ($DBH->do(@_)) {
    croak "failed: $E";
  }
}

my %sth_cache;  # string to statement handle
my @sth_cache;  # oldest key first

# given a query string, 
sub _substitute {
  my ($function, $str, @args) = @_;

  if ($function eq 'Insert') {
    my $list = join ',' , (('?') x @args);
    unless ($str =~ s/\?\?L/($list)/) {
      if (/\bvalues\b/) {
        unless ($str =~ /\)\s*$/) {
          $str .= "($list)";
        }
      } else {
        $str .= "values ($list)";
      }
    }
  }

  # maybe this should be a separate function
  # otherwise, the @args are never used for anything
  my $subct = ($str =~ /\?/g);
  if ($subct > @args) {
    croak "Not enough arguments for $function ($subct required)";
  } elsif ($subct < @args) {
    croak "Too many arguments for $function ($subct required)";
  }

  my $sth = $sth_cache{$str};

  # was the statement handle cached already?
  if ($sth) {                   # yes
    my @a;
    local $_;

  } else {                      # new query
    # expire old cache item if cache is full
    while (@sth_cache >= $MAX_STH) {
      my $q = shift @sth_cache;
      delete $sth_cache{$q};  # should cause garbage collection
    }

    # prepare new handle
    $sth = $DBH->prepare("\L$function\E $str");
    unless ($sth) {
      croak "Couldn't prepare query from '$str': $E; aborting";
    }

    # install new handle in cache
    $sth_cache{$str} = $sth;
  }

  # remove it from the MRU queue (if it is there)
  # and add it to the end
  @sth_cache = ((grep {$_ ne $str} @sth_cache), $str);

  return $sth;
}

1;

=head1 NAME

EZDBI - Easy interface to SQL database

=head1 SYNOPSIS

  use EZDBI 'type:database', @arguments;

  Insert 'into TABLE values', ...;
  Delete 'from TABLE where field=?, field=?', ...;
  Update 'TABLE set field=?, field=?', ...;

  @rows   = Select 'field, field from TABLE where field=?, field=?', ...;
  $n_rows = Select 'field, field from TABLE where field=?, field=?', ...;

=head1 DESCRIPTION

This file documents version 0.04 of C<EZDBI>.

C<EZDBI> provides a simple and convenient interface to most common SQL
databases.  It requires that you have installed the C<DBI> module and
the C<DBD> module for whatever database you will be using.

This documentation assumes that you already know the basics of SQL.
It is not an SQL tutorial.

=head2 C<use>

To use C<EZDBI>, you put the following line at the top of your program:

	use EZDBI 'type:database', ...;

The C<type> is the kind of database you are using.  Typical values are
C<mysql>, C<Oracle>, C<Sybase>, C<Pg> (for PostgreSQL), C<Informix>,
C<DB2>, and C<CSV> (for text files).  C<database> is the name of the
database.  For example, if you want to connect to a MySQL database
named 'accounts', use C<mysql:accounts>.

Any additional arguments here will be passed directly to the database.
This part is hard to document because every database is a little
different.  Typically, you supply a username and a password here if
the database requires them.  Consult the documentation for the
C<DBD::> module for your database for more information.

	use EZDBI 'mysql:databasename', 'username', 'password';
	# Please send me sample calls for other databases

The normal use of C<use> creates a connection to the database
immediately, even before the rest of your program is compiled, and
aborts the compilation unless the attempt to connect to the database
is successful.  Sometimes it may be more convenient to defer the
connection attempt until later, after part of your program has run.
To do that, use:

	use EZDBI;

and later, when your program is ready to connect, call

	Connect 'type:database', ...;

=head2 C<Select>

C<Select> queries the database and retrieves the records that you ask
for.  It returns a list of matching records.  

        @records = Select 'lastname from accounts where balance < 0';

C<@records> now contains a list of the last names of every customer
with an overdrawn account.

        @Tims = Select "lastname from accounts where firstname = 'Tim'";

C<@Tims> now contains a list of the last names of every customer
whose first name is C<Tim>.

You can use this in a loop:

        for $name (Select "lastname from accounts where firstname = 'Tim'") {
          print "Tim $name\n";
        }

It prints out C<Tim Cox>, C<Tim O'Reilly>, C<Tim Bunce>, C<Tim Allen>.

This next example prompts the user for a last name, then  prints out
all the people with that last name.  But it has a bug:

        while (1) {
          print "Enter last name: ";
          chomp($lastname = <>);
          last unless $lastname;

          print "People named $lastname:\n"

          for (Select "firstname from accounts where lastname='$lastname'") {
            print "$_ $lastname\n";
          }
        }

The bug is that if the user enters C<"O'Reilly">, the SQL statement
will have a syntax error, because the apostrophe in C<O'Reilly> will
confuse the database.  

Sometimes people go to a lot of work to try to fix this.  C<EZDBI>
will fix it for you automatically.  Instead of the code above, you
should use this:

          for (Select "firstname from accounts where lastname=?", $lastname) {
            print "$_ $lastname\n";
          }

C<EZDBI> will replace the C<?> with the value of C<$lastname>.  If
C<$lastname> contains an apostrophe or something else that would mess
up the SQL, C<EZDBI> will take care of it for you.  Use C<?> wherever
you want to insert a value.  Doing this may also be much more
efficient than inserting the variables into the SQL yourself.

The C<?>es in the SQL code are called I<placeholders>.
The Perl value C<undef> is converted to the SQL C<NULL> value by
placeholders:

        for (Select "* from accounts where occupation=?", undef) {
          # selects records where occupation is NULL
        }

You can, of course, use

        for (Select "* from accounts where occupation is NULL") {
          # selects records where occupation is NULL
        }

In scalar context, C<Select> returns the number of rows selected.
This means you can say

        if (Select "* from accounts where balance < 0") {
          print "Someone is overdrawn.\n";
        } else {
          print "Nobody is overdrawn.\n";
        }

In list context, C<Select> returns a list of selected records.  If the
selection includes only one field, you will get back a list of field
values:

        # print out all last names
        for $lastname (Select "lastname from accounts") {       
          print "$lastname\n";
        }
        # Select returned ("Smith", "Jones", "O'Reilly", ...)

If the selection includes more than one field, you will get back a
list of rows; each row will be an array of values:

        # print out all full names
        for $name (Select "firstname, lastname from accounts") {       
          print "$name->[1], $name->[0]\n";
        }
        # Select returned (["Will", "Smith"], ["Tom", "Jones"],
        #                       ["Tim", "O'Reilly"], ...)

        # print out everything
        for $row (Select "* from accounts") {       
          print "@$row\n";
        }
        # Select returned ([143, "Will", "Smith", 36, "Actor", 142395.37], 
        #                  [229, "Tom", "Jones", 52, "Singer", -1834.00],
        #                  [119, "Tim", "O'Reilly", 48, "Publishing Magnate",
        #                    -550.00], ...)

=head2 C<Delete>

C<Delete> removes records from the database.

        Delete "from accounts where id=?", $old_customer_id;

You can (and should) use C<?> placeholders with C<Delete> when they
are approprite.

In a numeric context, C<Delete> returns the number of records
deleted.  In boolean context, C<Delete> returns a success or failure
code.  Deleting zero records is considered to be success.

=head2 C<Update>

C<Update> modifies records that are already in the database.

        Update "accounts set balance=balance+? where id=?", 
                  $deposit, $old_customer_id;


The return value is the same as for C<Delete>.

=head2 C<Insert>

C<Insert> inserts new records into the database.

        Insert "into accounts values (?, ?, ?, ?, ?, ?)", 
                  undef, "Michael", "Schwern",  26, "Slacker", 0.00;

Writing so many C<?>'s is inconvenient.  For C<Insert>, you may use
C<??L> as an abbreviation for the appropriate list of placeholders:

        Insert "into accounts values ??L",
                  undef, "Michael", "Schwern",  26, "Slacker", 0.00;

If the C<??L> is the last thing in the SQL statement, you may omit it.
You may also omit the word C<'values'>:

        Insert "into accounts",
                  undef, "Michael", "Schwern",  26, "Slacker", 0.00;

The return value is the same as for C<Delete>.

=head2 Error Handling

If there's an error, C<EZDBI> prints a (hopefully explanatory) message
and throws an exception.  You can catch the exception with C<eval { ... }>  or let it kill your program.


=head2 Other Features

Any other features in this module should be construed as undocumented
and unsupported and may go away in a future release.

=head1 BUGS

This is ALPHA software.  There may be bugs.  The interface may change.
Do not use this for anything important.

Notice that this module has NO TEST SUITE.
What does that mean to you?

=head1 THANKS

Thanks to the following people for their advice, suggestions, and
support:

Terence Brannon /
Meng Wong


=head1 SUPPORT

Send mail to C<mjd-perl-ezdbi+@plover.com> and I will do what I can.

=head1 AUTHOR

	Mark Jason Dominus
	mjd-perl-ezdbi+@plover.com
	http://perl.plover.com/EZDBI/

=head1 COPYRIGHT

    EZDBI - Easy Perl interface to SQL databases
    Copyright (C) 2001  Mark Jason Dominus

    This program is free software; you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation; either version 2 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program; if not, write to the Free Software
    Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.

The full text of the license can be found in the COPYING file included
with this module.

=head1 SEE ALSO

perl(1), L<DBI>.

=cut


