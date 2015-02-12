package Config::DBI;
use strict; use warnings; use re 'taint'; use autodie; use 5.010;
our $VERSION = 1.0.0;
use Carp;
use Contextual::Return;
use DBI;

=pod

=head1 NAME

Config::DBI - DBI based configuration storage

=head1 SYNOPSIS

 use strict;
 use Config::DBI;
 my $config = Config::DBI->Open( $sqlite_file );
 my $config = Config::DBI->Open( $sqlite_file, Table => $table );
 my $config = Config::DBI->Connect( $dbi_dsn, $user, $pass, \%dbi_params );

 # simple persistant hash
 my $name = $config->first_name;
 $config->last_name( "Smith" );

 # Simple namespaces:
 my $foo_config = $config->foo;
 $foo_config->bar("baz");

 # deep hashes:
 $config->user->name("Bob");
 my $user = $config->Get( "user.*" )->{user};
 my %user = $config->user->Get;
 say $user{name};

=head1 DESCRIPTION



=head1 USAGE

=cut

sub Open {
  my ($class, $file, %opt) = @_;
  $class->Connect( "dbi:SQLite:dbname=$file", "", "", { AutoCommit => 1, RaiseError => 1 }, %opt );
}

sub Connect {
  my ($class, $dsn, $user, $pass, $opt, %conf) = @_;
  my $self = bless { %conf }, $class;
  $$self{DBH} = DBI->connect( $dsn, $user, $pass, $opt );
  $self->_HasTable || $self->_Initialize;
  return $self;
}

our $AUTOLOAD;
sub AUTOLOAD {
  no strict 'refs';
  my $meth = $AUTOLOAD;
  $meth =~ s/.*:://;
  die "Can not autoload $meth" if $meth =~ /^_?[A-Z]/;
  *$AUTOLOAD = sub {
    my $self = shift;
    if (@_) {
      $self->Set( $meth, @_ );
    } else {
      return OBJREF  { $self->Subspace($meth) }
             HASHREF { $self->Get() }
             DEFAULT { $self->Get($meth) }
    }
  };
  goto &$AUTOLOAD;
}

sub DESTROY { }

our @rw_attributes = qw/ DBH Table NamespaceSeparator KeyColumn ValueColumn UseStarGlob /;
for (@rw_attributes) {
  my $_attr = $_;
  my $attr  = $_; $attr =~ s/^_//;
  my $builder = "_Build_$attr";
  no strict 'refs';
  *{$attr} = sub {
    my $self = shift;
    if (@_) {
      delete $$self{_Cache};
      my $old = $$self{$_attr};
      $$self{$_attr} = shift;
      return $old;
    }
    return $$self{$_attr} if exists $$self{$_attr};
    return $$self{$_attr} = $self->$builder() if $self->can($builder);
    return $$self{$_attr} = undef;
  };
}

sub _Build_NamespaceSeparator { '.' }
sub _Build_KeyColumn          { 'key' }
sub _Build_ValueColumn        { 'value' }
sub _Build_UseStarGlob        { 1 }
sub _Build_Table              { 'config' }
sub _Build_DBH                { die }
# sub _Build_ { '' }
# sub _Build_ { '' }

sub Namespace {
  my $self = shift;
  if (@_) {
    croak "Can't use Namespaces without defined NamespaceSeparator" unless my $sep = $self->NamespaceSeparator;
    $$self{Namespace} = join $sep, @_;
  }
  return unless defined($$self{Namespace});
  return $$self{Namespace};
}

sub Path {
  my ($self, @path) = @_;
  unshift @path, $self->Namespace;
  return $path[0] if 1 == @path;

  croak "Can't use Namespaces without defined NamespaceSeparator" unless my $sep = $self->NamespaceSeparator;
  join $sep, @path;
}

=head3 Get

 my $all = $config->Get;
 my %all = $config->Get;
 my $name = $config->Get( "user.name" );

 my %user = $config->Get( "user.*" );
 # sample %user:
 # { "user.name" => "Bob Smiley",
 #   "user.addr" => { street => "1234 Main St.",
 #                    city   => "MyCity",
 #                    state  => "MyState",
 #                  },
 # }

 my %user = $config->user->Get;
 my %user = $config->user->Get( "*" ); # same as previous line
 # sample %user:
 # { "name" => "Bob Smiley",
 #   "addr" => { street => "1234 Main St.",
 #               city   => "MyCity",
 #               state  => "MyState",
 #             },
 # }

Get single value from the database. Deep values (hash of hash) are
extracted if C<UseStarGlob> option is set.

=cut

sub Get {
  my ($self, $path) = @_;
  $path //= "*";
  my $fullpath = $self->Path($path);
  if ($self->UseStarGlob and $fullpath =~ s/\*/%/g) {
    my $res = $self->_Get( LIKE => $fullpath );
    my $hash = $self->_Values2Nested( @$res );
    if ($self->Namespace) {
      my $sep = $self->NamespaceSeparator;
      $hash = GETPATH( $hash, split /\Q$sep\E/, $self->Namespace );
    }
    return wantarray ? %$hash : $hash;
  } else {
    my $res = $self->_Get( '=' => $fullpath );
    carp "Multiple results found for $path" if @$res > 1;
    return undef unless @$res;
    return $$res[0][1];
  }
}

=head3 GetFlatHash

 my $all = $config->GetFlatHash;
 my %all = $config->GetFlatHash;
 my %user = $config->GetFlatHash("user.*");
 # sample %user:
 # { "user.name" => "Bob Smiley",
 #   "user.addr.street" => "1234 Main St.",
 #   "user.addr.city"   => "MyCity",
 #   "user.addr.state"  => "MyState",
 # }

Get values from the database without expanding hash of hash recursions.

=cut

sub GetFlatHash {
  my $self = shift;
  @_ = ("*") if !@_ and $self->UseStarGlob;
  my %vals;
  for (@_) {
    my $fullpath = $self->Path($_);
    my $res;
    if ($self->UseStarGlob and $fullpath =~ s/\*/%/g) {
      $res = $self->_Get( LIKE => $fullpath );
    } else {
      $res = $self->_Get( '=' => $fullpath );
      carp "Multiple results found for $_" if @$res > 1;
    }
    $vals{$$_[0]} = $$_[1] for @$res;
  }
  return wantarray ? %vals : \%vals;
}

=head3 Delete

 $config->Set( %values );

Sets keys to given values. Operates recursively as long as
C<NamespaceSeparator> is defined.

=cut

sub Set {
  my ($self, %val) = @_;
  my @set;
  push @set, $self->_Nested2Values( $val{$_}, $self->Path($_) ) for keys %val;
  $self->_Set( @$_ ) for @set;
}

=head3 Delete

 $config->foo->Delete;
 $config->Delete("foo.*");
 $config->Delete("key1", "key2", ...);

Delete keys. When called with no arguments, deletes entire current
namespace. When called with arguments deletes the given keys (with glob
expansion if C<UseStarGlob> is set).

=cut

sub Delete {
  my $self = shift;
  @_ = ("*") unless @_;
  for my $path (@_) {
    next unless defined $path;
    my $fullpath = $self->Path($path);
    if ($self->UseStarGlob and $fullpath =~ s/\*/%/g) {
      $self->_Delete( LIKE => $fullpath );
    } else {
      $self->_Delete( '=' => $fullpath );
    }
  }
}

=head3 Increment

=head3 Decrement

 my $new_foo = $config->foo->Increment;
 my $new_foo = $config->Increment("foo");

Add/Subtract one to an existing value then store and return the new value.
If the value does not exist, stores and returns ±1.

=cut

sub Increment { shift->AddToVal( $_[0],  1 ) }
sub Decrement { shift->AddToVal( $_[0], -1 ) }

=head3 AddToVal

 my $new_foo = $config->foo->AddToVal( 5 );
 my $new_foo = $config->AddToVal("foo", 5);

Add to an existing value then store and return the new value. If the value
does not exist, stores and returns the added value.

=cut

sub AddToVal {
  my ($self, $path, $delta) = @_;
  my $val;
  if ($path) {
    $val = $delta + ($self->Get( $path ) || 0);
    $self->Set( $path, $val );
  } else {
    $path = $self->Namespace || die "Empty Namespace";
    $val = $delta + ($self->_Get( '=' => $path )->[0][1] || 0);
    $self->_Set( $path, $val );
  }
  return $val;
}

=head3 Subspace

 my $foo_config = $config->Subspace( "foo" );
 my $foo_config = $config->foo;                # if $foo_config used as object

Returns new config object which sets and gets values from a namespace (as
delimited by C<NamespaceSeparator>). Croaks if C<NamespaceSeparator> is
undefined.

=cut

sub Subspace {
  my ($self, @space) = @_;
  my $sub = bless { %$self }, ref($self);
  $sub->Namespace( $self->Namespace, @space );
  return $sub;
}

=head1 INTERNAL METHODS

=cut

sub _Get {
  my ($self, $op, $path) = @_;
  my $dbh = $self->DBH;
  my $smt = $$self{_Cache}{Get}{$op} ||= do {
    my $table   = $dbh->quote_identifier( $self->Table );
    my $key_col = $dbh->quote_identifier( $self->KeyColumn );
    my $val_col = $dbh->quote_identifier( $self->ValueColumn );
    $dbh->prepare( "SELECT $key_col, $val_col FROM $table WHERE $key_col $op ?" );
  };
  $smt->execute($path);
  $smt->fetchall_arrayref;
}

sub _Set {
  my ($self, $path, $value) = @_;
  my $dbh = $self->DBH;
  unless ($$self{_Cache}{Set}{upd} and $$self{_Cache}{Set}{ins}) {
    my $table   = $dbh->quote_identifier( $self->Table );
    my $key_col = $dbh->quote_identifier( $self->KeyColumn );
    my $val_col = $dbh->quote_identifier( $self->ValueColumn );
    $$self{_Cache}{Set}{upd} ||= $dbh->prepare("UPDATE $table SET $val_col = ? WHERE $key_col = ?");
    $$self{_Cache}{Set}{ins} ||= $dbh->prepare("INSERT INTO $table ($key_col, $val_col) VALUES (?, ?)");
  };
  0+$$self{_Cache}{Set}{upd}->execute($value, $path)
    or
  0+$$self{_Cache}{Set}{ins}->execute($path, $value)
    or
  carp "Error Updating table";
}

sub _Delete {
  my ($self, $op, $path) = @_;
  my $dbh = $self->DBH;
  my $smt = $$self{_Cache}{Delete}{$op} ||= do {
    my $table   = $dbh->quote_identifier( $self->Table );
    my $key_col = $dbh->quote_identifier( $self->KeyColumn );
    $dbh->prepare( "DELETE FROM $table WHERE $key_col $op ?" );
  };
  $smt->execute($path);
}

sub _Nested2Values {
  my ($self, $val, @path) = @_;
  my @vals;

  for my $ref (ref($val)) {
    if ($ref eq 'HASH') {
      push @vals, $self->_Nested2Values( $$val{$_}, @path, $_ ) for keys %$val;
    }

    elsif ($ref eq 'ARRAY') {
      push @vals, $self->_Nested2Values( $$val[$_], @path, $_ ) for 0..$#{$val};
    }

    else {
      my $key;
      if (1 > @path) {
        die "Can not save value without name";
      } elsif (1 == @path) {
        $key = $path[0];
      } else {
        my $sep = $self->NamespaceSeparator;
        croak "Can not save nested values without defined NamespaceSeparator" unless defined $sep;
        $key = join $sep, @path;
      }

      return [ $key, $val ];
    }
  }
  return @vals;
}

sub SETPATH {
  my ($A, $v, @path) = @_;
  if (@path == 1) { (ref($A) eq 'ARRAY') ? ($$A[$path[0]] = $v) : ($$A{$path[0]} = $v) }
  else {
    my $this = shift @path;
    $$A{$this} ||= { };
    SETPATH(((ref($A) eq 'ARRAY') ? $$A[$this] : $$A{$this}), $v, @path);
  }
}

sub GETPATH {
  my ($A, @path) = @_;
  return unless @path;
  return unless +(ref($A) eq 'ARRAY') ? ($#{$A} >= $path[0]) : exists($$A{$path[0]});
  if (@path == 1) { return +(ref($A) eq 'ARRAY') ? $$A[$path[0]] : $$A{$path[0]} }
  else {
    my $this = shift @path;
    return GETPATH(((ref($A) eq 'ARRAY') ? $$A[$this] : $$A{$this}), @path);
  }
}

sub _Values2Nested {
  my $self = shift;
  my $sep = $self->NamespaceSeparator;
  my %h;
  for (@_) {
    my ($k, $v) = @$_;
    if (defined($sep)) {
      SETPATH(\%h, $v, split /\Q$sep\E/, $k);
    } else {
      $h{$k} = $v;
    }
  }
  return \%h;
}

sub _Initialize {
  my $self = shift;
  my $dbh = $self->DBH;
  my $table   = $dbh->quote_identifier( $self->Table );
  my $key_col = $dbh->quote_identifier( $self->KeyColumn );
  my $val_col = $dbh->quote_identifier( $self->ValueColumn );
  $dbh->do( "CREATE TABLE $table ($key_col TEXT PRIMARY KEY, $val_col TEXT)" );
}

sub _HasTable {
  my $self = shift;
  my $dbh = $self->DBH;
  my $table = $dbh->quote_identifier( $self->Table );
  eval { local $dbh->{PrintError} = 0; $dbh->do( "SELECT 1 FROM $table LIMIT 1" ); 1 } || 0;
}




1;

__END__

=head1 AUTHOR

 Dean Serenevy
 dean@serenevy.net
 http://dean.serenevy.net/

=head1 COPYRIGHT

This software is hereby placed into the public domain. If you use this
code, a simple comment in your code giving credit and an email letting
me know that you find it useful would be courteous but is not required.

The software is provided "as is" without warranty of any kind, either
expressed or implied including, but not limited to, the implied warranties
of merchantability and fitness for a particular purpose. In no event shall
the authors or copyright holders be liable for any claim, damages or other
liability, whether in an action of contract, tort or otherwise, arising
from, out of or in connection with the software or the use or other
dealings in the software.

=head1 SEE ALSO

perl(1)
