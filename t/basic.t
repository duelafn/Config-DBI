#!/usr/bin/perl
use strict; use warnings; use 5.010;
use Test::More tests => 10;
use lib 'lib';

BEGIN{ use_ok 'Config::DBI' };

use Cwd qw/ chdir /;
chdir "t" if -d "t";

use File::Copy;
copy "test_populated-template.sqlite", "test_populated.sqlite";
unlink "testconfig.sqlite";

my $config = Config::DBI->Open( "testconfig.sqlite" );
$config->first_name("Bob");

is "".$config->first_name, "Bob", "Simple setter";

my $user = $config->user;
$user->name("Bob Smiley");

is "".$config->Get("user.name"), "Bob Smiley", "Subspace setter creates";
is "".$config->user->name, "Bob Smiley", "Subspace setter creates";


my $config2 = Config::DBI->Open( "test_populated.sqlite", Table => 'myconfig' );
is "".$config2->foo, 1, "Simple getter 1";
is "".$config2->bar, 2, "Simple getter 2";

is "".$config2->Get("user.name"), "Bob Smiley", "Simple getter 3";

my $userinfo =
  { name => 'Bob Smiley',
    address => { street => '1234 Main St.',
                 city => 'Metropolis',
                 state => 'SO',
                 zip => '12345',
               }
  };

is "".$config2->user->name, "Bob Smiley", "deep value";
is_deeply { $config2->Get( "user.*" ) }, { user => $userinfo }, "Deep retrieval";
is_deeply { $config2->user->Get }, $userinfo, "Deep retrieval 2";
