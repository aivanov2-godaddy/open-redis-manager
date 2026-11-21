use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use Fcntl qw(O_CREAT O_RDWR :flock);
use lib 'src';
use Orm::Broker::ProviderEvents qw(build_envelope sign_envelope);
use Orm::Broker::ProviderEventQueue;

if ($^O eq 'MSWin32') {
    plan skip_all => 'provider event queue security tests require Linux owner and mode semantics';
}

my $directory = tempdir(CLEANUP => 1);
chmod 0700, $directory or die "chmod failed";
my $queue = Orm::Broker::ProviderEventQueue->new(directory => $directory, owner_uid => $<);
my $key = 'q' x 32;
my $now = time();
my ($event, $error) = build_envelope('instance.started', { backend => 'redis' }, now => $now);
is($error, undef, 'builds event for the outbox');
my $signature = sign_envelope($event, $key);
is_deeply([$queue->enqueue($event, $signature, $key, $now)], [1, 'queued'], 'persists a signed event');
is_deeply([$queue->enqueue($event, $signature, $key, $now)], [0, 'duplicate_event'], 'rejects a duplicate event id');

my ($claim, $claim_status) = $queue->claim_due($now);
is($claim_status, 'claimed', 'atomically claims a due event');
is($claim->{attempts}, 1, 'increments the attempt count on claim');
is_deeply([$queue->finish_attempt($claim->{id}, 'retryable', 503, $now)], [1, 'pending'], 'schedules retry after a transient response');
my ($early, $early_status) = $queue->claim_due($now + 10);
is_deeply([$early, $early_status], [undef, 'empty'], 'does not retry before its backoff expires');
my ($retry) = $queue->claim_due($now + 60);
is($retry->{attempts}, 2, 'claims retry and increments attempts');
is_deeply([$queue->finish_attempt($retry->{id}, 'delivered', 204, $now + 60)], [1, 'delivered'], 'records successful delivery without response content');

my ($state, $status) = $queue->status($now + 61);
is($status, 'ok', 'returns bounded operator status');
is($state->{counts}->{delivered}, 1, 'counts delivered events');
ok(!exists($state->{records}->[0]->{event}) && !exists($state->{records}->[0]->{signature}), 'status omits payloads and signatures');

my ($expired_event) = build_envelope('quota.reached', { quota_kind => 'instances' }, now => $now);
my $expired_signature = sign_envelope($expired_event, $key);
is_deeply([$queue->enqueue($expired_event, $expired_signature, $key, $now)], [1, 'queued'], 'accepts a second event');
my ($contended_event) = build_envelope('instance.started', { backend => 'redis' },
    event_id => '2123456789abcdef0123456789abcdef', now => $now);
my $contended_signature = sign_envelope($contended_event, $key);
sysopen(my $held_lock, "$directory/.queue.lock", O_CREAT | O_RDWR, 0600) or die "open held queue lock: $!";
flock($held_lock, LOCK_EX) or die "hold queue lock: $!";
my $contended_started = time();
is_deeply([$queue->enqueue($contended_event, $contended_signature, $key, $now)],
    [undef, 'lock_failed'], 'fails fast when another broker process holds the outbox lock');
cmp_ok(time() - $contended_started, '<', 2, 'queue contention does not block a cache operation');
flock($held_lock, LOCK_UN) or die "release queue lock: $!";
close($held_lock) or die "close held queue lock: $!";
my (undef, $empty_status) = $queue->claim_due($now + 86_401);
is($empty_status, 'empty', 'expires old events instead of delivering them');
my ($expired_state) = $queue->status($now + 86_402);
is($expired_state->{counts}->{expired}, 1, 'reports expired events');

done_testing();
