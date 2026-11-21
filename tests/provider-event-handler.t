use strict;
use warnings;
use Test::More;
use JSON::PP ();
use lib 'src';
use Orm::Broker::Handler;

{
    package Local::HandlerResolver;
    sub resolve_account { return { gid => 1001, name => 'ormtest', uid => $_[1] }; }
}
{
    package Local::HandlerManager;
    sub new { return bless { response => $_[1], status => $_[2] }, $_[0]; }
    sub dispatch { return $_[0]->{response}; }
    sub status { return $_[0]->{status}; }
}
{
    package Local::HandlerEvents;
    sub new { return bless { calls => [] }, $_[0]; }
    sub emit { my ($self, @args) = @_; push @{$self->{calls}}, \@args; return (0, 'disabled'); }
}

my $resolver = bless {}, 'Local::HandlerResolver';
my $events = Local::HandlerEvents->new();
my $frame = '{"operation":"instance.start","version":1}' . "\n";
my $manager = Local::HandlerManager->new(
    { backend => 'redis', success => JSON::PP::true, state => 'running', version => 1 }, undef,
);
my $response = Orm::Broker::Handler->handle_frame($frame, 1001, $resolver, $manager, undef, undef, undef, $events);
like($response, qr/"success":true/, 'keeps the successful broker response when telemetry is available');
is_deeply($events->{calls}, [[ 'instance.started', { backend => 'redis' } ]],
    'emits a bounded lifecycle event after the operation completes');

$events = Local::HandlerEvents->new();
$manager = Local::HandlerManager->new(
    { error => 'service_failed', success => JSON::PP::false, version => 1 },
    { backend => 'valkey', success => JSON::PP::true, state => 'failed', version => 1 },
);
$response = Orm::Broker::Handler->handle_frame($frame, 1001, $resolver, $manager, undef, undef, undef, $events);
like($response, qr/"error":"service_failed"/, 'keeps the original lifecycle failure response');
is_deeply($events->{calls}, [[ 'instance.failed', {
    backend => 'valkey', operation => 'instance.start', reason_code => 'service_failed',
} ]], 'emits only fixed failure metadata after a service failure');

done_testing();
