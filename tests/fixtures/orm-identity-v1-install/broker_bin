#!/usr/bin/perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Orm::Broker::Server;

$SIG{PIPE} = 'IGNORE';
Orm::Broker::Server->run(socket_path => '/run/orm/broker.sock');
