use strict;
use warnings;
use Test::More;
use JSON::PP ();
use lib 'src';
use Orm::Broker::Handler;

{
    package Local::EventAdminConfig;
    sub new { return bless { saved => [], key => 'do-not-return-this-key' }, $_[0]; }
    sub load { return ({ enabled => JSON::PP::false, destination => '', signing_key => 'a' x 64 }, 'ok'); }
    sub public_view { return { enabled => $_[1]->{enabled}, destination => $_[1]->{destination}, key_configured => JSON::PP::true }; }
    sub save {
        my ($self, @args) = @_;
        push @{$self->{saved}}, \@args;
        return ({ enabled => JSON::PP::true, destination => $args[0], signing_key => $self->{key}, key_rotated => 1 }, 'ok');
    }
}
{
    package Local::EventAdminQueue;
    sub status { return ({ counts => { pending => 2, sending => 0, delivered => 1, failed => 0, expired => 0 }, records => [] }, 'ok'); }
}
{
    package Local::EventAdminEmitter;
    sub new { return bless { events => [] }, $_[0]; }
    sub emit { my ($self, @args) = @_; push @{$self->{events}}, \@args; return (1, 'queued'); }
}

my $config = Local::EventAdminConfig->new();
my $queue = bless {}, 'Local::EventAdminQueue';
my $emitter = Local::EventAdminEmitter->new();
my $selected = Orm::Broker::Handler->handle_frame(
    '{"backend":"valkey","operation":"provider.backend.selected","version":1}' . "\n",
    0, undef, undef, undef, $config, $queue, $emitter,
);
like($selected, qr/"queued":true/, 'returns bounded backend event enqueue state');
is_deeply($emitter->{events}, [['backend.selected', { backend => 'valkey' }]],
    'emits a fixed backend-selected event through the broker emitter');
my $selectedDenied = Orm::Broker::Handler->handle_frame(
    '{"backend":"redis","operation":"provider.backend.selected","version":1}' . "\n",
    1001, undef, undef, undef, $config, $queue, $emitter,
);
like($selectedDenied, qr/"error":"not_authorized"/, 'denies backend telemetry to non-root peers');
my $status = Orm::Broker::Handler->handle_frame(
    '{"operation":"provider.events.status","version":1}' . "\n", 0, undef, undef, undef, $config, $queue, undef,
);
like($status, qr/"key_configured":true/, 'exposes only a boolean for signing-key status');
unlike($status, qr/do-not-return-this-key|aaaaaaaa/, 'never returns key material');

my $configure = Orm::Broker::Handler->handle_frame(
    '{"destination":"https://hooks.example.net/orm","enabled":true,"operation":"provider.events.configure","rotate_key":true,"version":1}' . "\n",
    0, undef, undef, undef, $config, $queue, undef,
);
like($configure, qr/"key_rotated":true/, 'returns whether the root broker rotated a signing key');
unlike($configure, qr/do-not-return-this-key|aaaaaaaa/, 'configuration reply redacts the key');
is_deeply($config->{saved}, [[ 'https://hooks.example.net/orm', '1', '1' ]],
    'forwards only destination, enabled state, and rotation intent');

my $denied = Orm::Broker::Handler->handle_frame(
    '{"operation":"provider.events.status","version":1}' . "\n", 1001, undef, undef, undef, $config, $queue, undef,
);
like($denied, qr/"error":"not_authorized"/, 'denies event settings to account-scoped broker peers');

my $queue_status = Orm::Broker::Handler->handle_frame(
    '{"operation":"provider.events.queue.status","version":1}' . "\n", 0, undef, undef, undef, $config, $queue, undef,
);
like($queue_status, qr/"pending":2/, 'returns bounded queue counts to WHM root');

done_testing();
