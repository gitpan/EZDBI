package EZDBI;
use DBI;
use strict;
use Carp;
use vars ('$E', '@EXPORT', '$VERSION', '$MAX_STH');
require 5;

my $DBH;
*E = \$DBI::errstr;
my $sth_cache;   # string to statement handle cache
my $sth_cacheA;  # oldest first (LRU)  handle order
$VERSION = '0.1';

# Note that this package does NOT inherit from Exporter
@EXPORT = qw(Connect Delete Disconnect Insert Select Sql Update Use);
sub import {
  no strict 'refs';
  my ($package, $type, %parms) = @_;
  my $caller = caller;

  #This is per database handle
  $MAX_STH = $parms{maxQuery} || 10;

  for my $func (@EXPORT) {
    *{"$caller\::$func"} = \&$func;
  }
}

sub Connect {
  my ($type, @args) = @_;
  unless( $type ){
    defined($DBH) ? return $DBH : croak "Not connected to a database";
  }

  if( ref($type) eq 'HASH' ){
    my $cfg = _parseIni(-file=>
			$type->{ini}||
			$ENV{'DBIX_CONN'}||
			$ENV{HOME}.'/.appconfig-dbi',
			-label=>$type->{label});
    @args = (
	     $cfg->{user},
	     $cfg->{pass},
	     $type->{attr} ? {%$cfg->{attr}, %$type->{attr}} : %$cfg->{attr}
	    );
    $cfg->{dsn} =~ s/^dbi://i;
    if( $cfg->{dsn} =~ /\?$/ ){
      croak("Section '$type->{label}' requires a database name") unless
	exists($type->{database});
      $cfg->{dsn} =~ s/\?$/$type->{database}/;
    }
    $type = $cfg->{dsn};
  }
  if ($type =~ /^Pg:(.*)/ && $1 !~ /dbname=/) {
    $type = "Pg:dbname=$1";
  }
  unless ($DBH = DBI->connect("DBI:$type", @args)) {
    croak "Couldn't connect to database: $E";
  }
  $sth_cacheA->{$DBH} = [];
  return $DBH;
}

sub Delete {
  my ($str, @args) = @_;
  my $sth = _substitute('Delete', $str, @args);
  my $rc;
  unless ($rc = $sth->execute(@args)) {
    croak "Delete failed: $E";
  }
  $sth->finish();
  $rc;
}

sub Disconnect {
  defined($DBH) || croak "Not connected to a database";
  my $dbh = $_[0] || $DBH;
  delete($_->{$dbh}) for ($sth_cache, $sth_cacheA);
  $DBH->disconnect();
  undef($_[0]);
  undef($DBH);
}

sub Insert {
  my ($str, @args) = @_;
  my $sth = _substitute('Insert', $str, @args);
  my $rc;
  unless ($rc = $sth->execute(@args)) {
    croak "Insert failed: $E";
  }
  $sth->finish();
  $rc;
}

# select '* from TABLE WHERE...'
#   Single column: returns list of scalar    in list   context
#   Multi  column: returns list of arrayrefs in list   context
#                  returns closure/object    in scalar context
# closure/object   returns indvidual records as arrayref or hashref
sub Select {
  my ($str, @args) = @_;
  my ($columns) = ($str =~ /^\s*(.*\S+)\s+from\s+/i);

  croak "Select in void context" unless defined wantarray;

  my $sth = _substitute('Select', $str, @args);
  unless ($sth->execute(@args)) {
    croak "Select failed: $E";
  }

  my $r;
  if( wantarray ){
    $r = $sth->fetchall_arrayref;
    unless( $columns =~ /^\*/ || $columns =~ /,/ ){
      $_ = $_->[0] foreach @{$r};
    }
    $sth->finish();
    return @$r;
  }
  my $finish;
  $r = sub {
    $_ = ref($_[0]);
    my $res =
      /HASH/ ? $sth->fetchrow_hashref :
	/ARRAY/ ? $sth->fetchrow_arrayref :
	  /SCALAR/ ? 0 :
	    croak qq(Select doesn't understand "$_[0]");
    unless( $res || $finish){
      $sth->finish();
      $finish = 1;
      return 0;
    }
  };
  #XXX This object cannot be inherited...
  bless $r, 'EZDBI::Select';
}
sub EZDBI::Select::DESTROY{
  $_[0]->(\"_");
}

# Freeform execution
sub Sql {
  defined($DBH) || croak "Not connected to a database";
  my $caller = caller;
  unless ($DBH->do(@_)) {
    croak "Sql failed: $E";
  }
}

sub Update {
  my ($str, @args) = @_;
  my $sth = _substitute('Update', $str, @args);
  my $rc;
  unless ($rc = $sth->execute(@args)) {
    croak "Update failed: $E";
  }
  $sth->finish();
  $rc;
}

#Multiple databases, whee!
sub Use{
   ref($_[0]) eq 'DBI::db' ? $DBH = $_[0] : croak("Not a DBI handle: $_[0]");
}

#Private Methods
sub _parseIni{
  my %parm = @_;
  my $self;
  open(my $INI, $parm{'-file'}) || croak("$!: $parm{-file}\n");
  while( <$INI> ){
    next if /^\s*$|(?:[\#\;])/;
    if( /^\s*\[$parm{'-label'}\]/ ..
	(/^\s*\[(?!$parm{'-label'})/ || eof($INI) ) ){
      /^\s*([^=]+?)\s*=\s*(.*)$/;
      $self->{$1} = $2 if $1;
    }
  }
  #Handle DBIx::Connect attr construct
  foreach my $key ( grep {/^attr/} keys %{$self} ){
    my $attr = $key;
    $attr =~ s/^attr\s+//i;
    #XXX Unfortunately delete does not reliably return the value?
    #XXX $self->{attr}->{$attr} = delete($self->{$key});
    $self->{attr}->{$attr} = $self->{$key};
    delete($self->{$key});
  }

  croak("Section [$parm{'-label'}] does not exist in $parm{'-file'}") unless
    keys %{$self};
  return $self;
}

# given a query string,
sub _substitute {
  defined($DBH) || croak "Not connected to a database";
  my ($function, $str, @args) = @_;

  if ($function eq 'Insert') {
    my $list = join ',' , (('?') x @args);
    unless ($str =~ s/\?\?L/($list)/) {
      if ($str =~ /\bvalues\b/i) {
        unless ($str =~ /\)\s*$/) {
          $str .= "($list)";
        }
      } elsif(@args){
        $str .= " values ($list)";
      }
    }
  }

  # maybe this should be a separate function
  # otherwise, the @args are never used for anything
  my $subct = $str =~ tr/?/?/;
  if ($subct > @args) {
    croak "Not enough arguments for $function ($subct required)";
  } elsif ($subct < @args) {
    croak "Too many arguments for $function ($subct required)";
  }

  my $sth;
  # was the statement handle cached already?
  unless( $sth = $sth_cache->{$DBH}->{$str} ){
  #XXX should this be more rigorous? kill 1/3 at a stroke a` la FileCache?
    # expire old cache item if cache is full
    while (@{$sth_cacheA->{$DBH}} >= $MAX_STH) {
      my $q = shift @{$sth_cacheA->{$DBH}};
      delete $sth_cache->{$DBH}->{$q};  # should cause garbage collection
    }

    # prepare new handle
    #XXX Why the casing?
    $sth = $DBH->prepare("\L$function\E $str");
    unless ($sth) {
      croak "Couldn't prepare query from '$str': $E; aborting";
    }

    # install new handle in cache
    $sth_cache->{$DBH}->{$str} = $sth;
  }

  # remove it from the MRU queue (if it is there)
  # and add it to the end
  $sth_cacheA->{$DBH} = [grep($_ ne $str, @{$sth_cacheA->{$DBH}}), $str];

  return $sth;
}

1;
__END__

=pod

=head1 NAME

EZDBI - EZ (Easy) interface to SQL databases (DBI)

=head1 SYNOPSIS

  use EZDBI;

  Connect   'type:database', 'username', 'password', ...;
  #OR
  Connect   {label=>'section', ...};

  Insert    'Into TABLE Values', ...;
  Delete    'From TABLE Where field=?, field=?', ...;
  Update    'TABLE set field=?, field=?', ...;

  @rows   =  Select 'field, field From TABLE Where field=?, ...;
  $n_rows = (Select 'Count(*) From TABLE Where field=?,     ...)[0];

=head1 DESCRIPTION

This file documents version 0.1 of B<EZDBI>.

B<EZDBI> provides a simple and convenient interface to most common SQL
databases.  It requires that you have installed the B<DBI> module and
the B<DBD> module for whatever database you will be using.

This documentation assumes that you already know the basics of SQL.
It is not an SQL tutorial.

=head2 C<Connect>

There are two means of connecting to a database with B<EZDBI>.
To use the first you put the following line in your program:

  Connect 'type:database', ...;

The C<type> is the kind of database you are using.  Typical values are
C<mysql>, C<Oracle>, C<Sybase>, C<Pg> (for PostgreSQL), C<Informix>,
C<DB2>, and C<CSV> (for text files).  C<database> is the name of the
database.  For example, if you want to connect to a MySQL database
named 'accounts', use C<mysql:accounts>.

Any additional arguments here will be passed directly to the database.
This part is hard to document because every database is a little
different.  Typically, you supply a username and a password here if
the database requires them.  Consult the documentation for the
B<DBD::> module for your database for more information.

  # For MySQL
  Connect 'mysql:databasename', 'username', 'password';
  
  # For Postgres
  Connect 'Pg:databasename', 'username', 'password';
  
  # Please send me sample calls for other databases

To use the second you put the following line in your program:

    Connect {label=>'section', database=>'db', ini=>'file', attr=>{ ... }};

This form is especially useful if you maintain many scripts that
use the same connection information, it allows you store your connection
parameters in an B<AppConfig> (Windows INI) format file, which is compatible
with B<DBIx::Connect>. Here is an example resource file.

  [section]
  user     = Bob
  pass     = Smith
  dsn      = dbi:mysql:?
  attr Foo = Bar

=over

=item I<label>

Required. It indicates which section of the resource file contains the
pertinent connection information.

=item I<database>

Optional. If supplied it replaces the special value I<?> at the end of the dsn
from the resource file.

=item I<ini>

Optional. Specifies the resource file to read connection information from.
See L<"ENVIRONMENT"> and L<"FILES">.

=item I<attr>

Optional. Equivalent to \%attr in L<DBI>. I<attr> supplied to C<Connect>
take precedence over these set in the resource file.

=item I<user>

Required. The username to connect with.

=item I<pass>

Required. The password to connect with, be sure to protect you resource file.

=item I<dsn>

Required. The C<dbi:> is optional, though it is required for a
B<DBIx::Connect> compatibile resource file.

=back

=head2 C<Select>

C<Select> queries the database and retrieves the records that you ask
for.  It returns a list of matching records.

  @records = Select 'lastname From ACCOUNTS Where balance < 0';

C<@records> now contains a list of the last names of every customer
with an overdrawn account.

  @Tims = Select "lastname From ACCOUNTS Where firstname = 'Tim'";

C<@Tims> now contains a list of the last names of every customer
whose first name is C<Tim>.

You can use this in a loop:

  for $name (Select "lastname From ACCOUNTS Where firstname = 'Tim'") {
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
  
    for (Select "firstname From ACCOUNTS Where lastname='$lastname'") {
      print "$_ $lastname\n";
    }
  }

The bug is that if the user enters C<"O'Reilly">, the SQL statement
will have a syntax error, because the apostrophe in C<O'Reilly> will
confuse the database.

Sometimes people go to a lot of work to try to fix this.  B<EZDBI>
will fix it for you automatically.  Instead of the code above, you
should use this:

  for (Select "firstname From ACCOUNTS Where lastname=?", $lastname) {
    print "$_ $lastname\n";
  }

The C<?> will be replaced with the value of C<$lastname> avoiding
such potential embedded quoting problems.  Use C<?> wherever
you want to insert a value.  Doing this may also be much more
efficient than inserting the variables into the SQL yourself.

The C<?>s in the SQL code are called I<placeholders>.
The Perl value C<undef> is converted to the SQL C<NULL> value by
placeholders:

  for (Select "* From ACCOUNTS Where occupation=?", undef) {
    # selects records where occupation is NULL
  }

You can, of course, use

  for (Select "* From ACCOUNTS Where occupation Is NULL") {
    # selects records where occupation is NULL
  }

If you simply require the number of rows selected do the following:

  if ((Select "Count(*) From ACCOUNTS Where balance < 0")[0]) {
    print "Someone is overdrawn.\n";
  } else {
    print "Nobody is overdrawn.\n";
  }

That is, use the SQL C<Count> function, and retrieve the appropriate
element of the returned list. I<This behavior has changed since 0.07>,
where you would simply C<Select> in scalar context.  

=cut

XXX kill this eventually --^ & moving to CAVEATS? or just nix mention of prior

=pod

In list context, C<Select> returns a list of selected records.  If the
selection includes only one field, you will get back a list of field
values:

  # print out all last names
  for $lastname (Select "lastname From ACCOUNTS") {
    print "$lastname\n";
  }
  # Select returned ("Smith", "Jones", "O'Reilly", ...)

If the selection includes more than one field, you will get back a
list of rows; each row will be an array of values:

  # print out all full names
  for $name (Select "firstname, lastname From ACCOUNTS") {
    print "$name->[1], $name->[0]\n";
  }
  # Select returned (["Will", "Smith"], ["Tom", "Jones"],
  #                       ["Tim", "O'Reilly"], ...)
  
  # print out everything
  for $row (Select "* From ACCOUNTS") {
    print "@$row\n";
  }
  # Select returned ([143, "Will", "Smith", 36, "Actor", 142395.37],
  #                  [229, "Tom", "Jones", 52, "Singer", -1834.00],
  #                  [119, "Tim", "O'Reilly", 48, "Publishing Magnate",
  #                    -550.00], ...)

=head2 C<Delete>

C<Delete> removes records from the database.

  Delete "From ACCOUNTS Where id=?", $old_customer_id;

You can (and should) use C<?> placeholders with C<Delete> when they
are appropriate.

In a numeric context, C<Delete> returns the number of records
deleted.  In boolean context, C<Delete> returns a success or failure
code.  Deleting zero records is considered to be success.

=head2 C<Update>

C<Update> modifies records that are already in the database.

  Update "ACCOUNTS Set balance=balance+? Where id=?",
            $deposit, $old_customer_id;


The return value is the same as for C<Delete>.

=head2 C<Insert>

C<Insert> inserts new records into the database.

  Insert "Into ACCOUNTS Values (?, ?, ?, ?, ?, ?)",
            undef, "Michael", "Schwern",  26, "Slacker", 0.00;

Writing so many C<?>'s is inconvenient.  For C<Insert>, you may use
C<??L> as an abbreviation for the appropriate list of placeholders:

  Insert "Into ACCOUNTS Values ??L",
            undef, "Michael", "Schwern",  26, "Slacker", 0.00;

If the C<??L> is the last thing in the SQL statement, you may omit it.
You may also omit the word C<'Values'>:

  Insert "Into ACCOUNTS",
            undef, "Michael", "Schwern",  26, "Slacker", 0.00;

The return value is the same as for C<Delete>.

=head1 FMTYEWTK

Far More Than You Ever Wanted To Know. Actually, if you are reading this,
probably not. These are the "advanced" features of B<EZDBI>. They control
B<EZDBI>'s behavior or bridge the gap between B<EZDBI>'s simplicity and
B<DBI>'s power.

=head2 C<use EZDBI maxQuery=E<gt>4>

Set the maximum number of queries to cache I<per database handle>.
The default is 10.

=head2 C<Connect>

C<Connect> returns a database handle upon connection, actually a B<DBI> object.
If no connection information is provided the current database handle
is returned if one exists, otherwise an exception is thrown.

=head2 C<Disconnect>

If you have a long running program that performs minimal interaction
with a database you may wish to C<Disconnect> from the database when
not in use so as not to tie up a connection. Additionally it is probably
not safe to assume in such a situtation that your connection is still
intact. You may provide a database handle or default to the current handle.

  my $dbh = Connect ...;
  ..;
  Disconnect($dbh);
  ...;

=head2 C<Select>

The normal manner of calling C<Select> returns the entire recordset,
this may be hazardous to your health in the limit of large recordsets.
C<Select> provides a mechanism for fetching individual records. In
scalar context C<Select> returns an object that may be repeatedly
queried, fetching a row at a time until the recordset is exhausted.
The object can return an arrayref or a hashref.

  my $r = Select('id, name From USERS');
  while( $_ = $r->([]) ){
    printf "%i\n", $_->[0];   #First column of the record
  }
  #OR
  while( $_ = $r->({}) ){
    printf "%i\n", $_->{id};  #The record column named id
  }

If you plan on using any loop control (C<last> is the only sensible option)
you will want to enclose everything in a block. It would be prudent to
do this even if you aren't using C<last>.

  {
    my $r = Select('id, name From USERS');
    while( $_ = $r->([]) ){
      last if $_->[1] eq 'Tim';
      printf "%i\n", $_->[0]; #First column of the record
    }
  }

=head2 C<Sql>

This allows you to execute an arbitrary SQL command which is not abstracted
by B<EZDBI> such as C<Grant>.

  Sql('Drop FOO');

NOTE: Sql does not expect a result set, as C<DBI::do()> does not, as such
commands such as MySQL's Describe are not especially useful.

=head2 C<Use>

C<Use> provides the ability to manage multiple simultaneous connections.
It might be compared to B<perl>'s 2-arg C<select> where C<Select> would be
B<perl>'s C<readline>.

  my $dbha = Connect ...;
  my $dbhb = Connect ...;
  Select('plugh From FOO');
  Use($dbha);
  Select('xyzzy From BAR');

You might do this if you had C<Connecte>ed to both FOO and BAR on the
same host. This is perfectly acceptable, but rather wasteful. SQL syntax
allows you to do this more efficiently.

  Connect ...;
  Select('plugh From FOO.BARFLE');
  Select('xyzzy From BAR.ZAZ');

Rather this is most appropriate when connections to databases on seperate
machines need to be maintained.

=head1 ERRORS

If there's an error, B<EZDBI> prints a (hopefully explanatory) message
and throws an exception.  You can catch the exception with C<eval { ... }>  or let it kill your program.

=head1 ENVIRONMENT

=over

=item DBIX_CONN

If C<Connect> is called in the B<AppConfig> format but is not provided
I<ini> it will try the file specified by DBIX_CONN.

=item HOME

If DBIX_CONN is not set C<Connect> will try the file F<.appconfig-dbi> in HOME.

=back

=head1 FILES

=over

=item ~/.appconfig-dbi

The last fall back for B<AppConfig> style Connect as documented in
L<"ENVIRONMENT">.

=back

=head1 CAVEATS

=over

=item C<Select> in list context

The normal manner of calling select can result in excess memory usage,
see L<"FMTYEWTK">.

=item Other Features

Any other features in this module should be construed as undocumented
and unsupported and may go away in a future release. Inquire within.

=back

=head1 BUGS

This is ALPHA software.
There may be bugs.
The interface may change.

=head1 AUTHORS

 Mark Jason Dominus
 mjd-perl-ezdbi+@plover.com
 http://perl.plover.com/EZDBI/

 Jerrad Pierce
 jpierce@cpan.org OR webmaster@pthbb.org
 http://pthbb.org/software/perl/

=head2 THANKS

Thanks to the following people for their advice, suggestions, and support:

Terence Brannon /
Meng Wong /
Juerd /
Ray Brizner /
Gavin Estey

=head1 COPYRIGHT

  EZDBI - Easy Perl interface to SQL databases
  Portions Copyright (C) 2002  Jerrad Pierce
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

perl(1), L<DBI>, L<DBIx::Connect>.

=cut
