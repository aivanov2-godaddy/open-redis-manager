use strict;
use warnings;
use Test::More;
use lib 'src';
use Orm::Broker::ProviderEventEmitter;
use Orm::Broker::ProviderEvents qw(verify_envelope);

{
    package Local::EventConfig;
    sub new { return bless { enabled => $_[1], key => $_[2] }, $_[0]; }
    sub load {
        my ($self) = @_;
        return ({ enabled => $self->{enabled}, signing_key => $self->{key} }, 'ok');
    }
}
{
    package Local::EventQueue;
    sub new { return bless { calls => [], fail => $_[1] }, $_[0]; }
    sub enqueue {
        my ($self, @args) = @_;
        die 'simulated local queue failure' if $self->{fail};
        push @{$self->{calls}}, \@args;
        return (1, 'queued');
    }
}

my $key = 'q' x 32;
my $disabled_queue = Local::EventQueue->new();
my $disabled = Orm::Broker::ProviderEventEmitter->new(
    config_store => Local::EventConfig->new(0, unpack('H*', $key)), queue => $disabled_queue,
);
is_deeply([$disabled->emit('instance.started', { backend => 'redis' }, 1_795_220_000)],
    [0, 'disabled'], 'disabled-by-default configuration does not enqueue');
is(scalar @{$disabled_queue->{calls}}, 0, 'disabled delivery makes no queue writes');

my $queue = Local::EventQueue->new();
my $emitter = Orm::Broker::ProviderEventEmitter->new(
    config_store => Local::EventConfig->new(1, unpack('H*', $key)), queue => $queue,
    event_id_generator => sub { return '0123456789abcdef0123456789abcdef'; },
);
is_deeply([$emitter->emit('instance.started', { backend => 'redis' }, 1_795_220_000)],
    [1, 'queued'], 'signs and queues an allowlisted event');
is(scalar @{$queue->{calls}}, 1, 'writes one event envelope');
my ($event, $signature, $used_key, $event_time) = @{$queue->{calls}->[0]};
is($used_key, $key, 'uses the root-owned signing key only at the local queue boundary');
is($event_time, 1_795_220_000, 'passes the event timestamp to the bounded queue');
is_deeply([verify_envelope($event, $signature, $key, now => 1_795_220_000)], [1, 'ok'],
    'queued event carries a valid signature');

my $broken = Orm::Broker::ProviderEventEmitter->new(
    config_store => Local::EventConfig->new(1, unpack('H*', $key)), queue => Local::EventQueue->new(1),
    event_id_generator => sub { return '1123456789abcdef0123456789abcdef'; },
);
is_deeply([$broken->emit('instance.started', { backend => 'redis' }, 1_795_220_000)],
    [0, 'emit_failed'], 'contains local outbox errors so cache operations can continue');

done_testing();
