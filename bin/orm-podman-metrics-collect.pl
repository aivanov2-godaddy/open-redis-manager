#!/usr/bin/perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Orm::Broker::AccountResolver;
use Orm::Broker::PodmanMetricsCollector;

exit 1 if $^O ne 'linux' || $> != 0;
my $resolver = Orm::Broker::AccountResolver->new();
my $collector = Orm::Broker::PodmanMetricsCollector->new(resolver => $resolver);
my $snapshot = eval { $collector->collect_and_write() };
exit(ref($snapshot) eq 'HASH' ? 0 : 1);
