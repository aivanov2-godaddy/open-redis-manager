use strict;
use warnings;
use Test::More;
use lib 'src';
use Orm::Broker::ProviderEvents qw(event_catalog build_envelope canonical_bytes sign_envelope verify_envelope);

my $now = 1_795_220_000;
my ($event, $error) = build_envelope('instance.started', { backend => 'redis' },
    event_id => '0123456789abcdef0123456789abcdef', now => $now);
is($error, undef, 'constructs a fixed catalog event');
is_deeply(event_catalog(), [qw(
    backend.selected instance.failed instance.provisioned instance.restarted
    instance.started instance.stopped policy.denied quota.reached
)], 'exposes a stable event catalog');
is(canonical_bytes($event), '{"event_id":"0123456789abcdef0123456789abcdef","event_type":"instance.started","metadata":{"backend":"redis"},"occurred_at":"2026-11-21T00:13:20Z","schema_version":1}', 'canonical bytes are stable and key-sorted');

my $key = 'k' x 32;
my $signature = sign_envelope($event, $key);
like($signature, qr/\A[a-f0-9]{64}\z/, 'signs exact canonical bytes with HMAC-SHA-256');
my %seen;
is_deeply([verify_envelope($event, $signature, $key, now => $now, seen_ids => \%seen)], [1, 'ok'], 'accepts fresh signed event');
is_deeply([verify_envelope($event, $signature, $key, now => $now, seen_ids => \%seen)], [0, 'duplicate_event'], 'rejects replayed event ID');
my ($delayed_event) = build_envelope('instance.started', { backend => 'redis' },
    event_id => '1123456789abcdef0123456789abcdef', now => $now - 1800);
my $delayed_signature = sign_envelope($delayed_event, $key);
is_deeply([verify_envelope($delayed_event, $delayed_signature, $key, now => $now)],
    [0, 'stale_timestamp'], 'default receiver freshness window rejects delayed events');
is_deeply([verify_envelope($delayed_event, $delayed_signature, $key, now => $now, max_age_seconds => 86_400)],
    [1, 'ok'], 'allows signed queued events during the bounded retry window');
is_deeply([verify_envelope($event, $signature, $key, now => $now, max_age_seconds => 86_401)],
    [0, 'invalid_timestamp'], 'caps configurable freshness at the queue expiry');
is_deeply([verify_envelope($event, $signature, 'x' x 32, now => $now)], [0, 'invalid_signature'], 'rejects signature made with a different key');
my $extended = { %$event, payload => 'unapproved' };
my $extended_signature = sign_envelope($extended, $key);
is_deeply([verify_envelope($extended, $extended_signature, $key, now => $now)], [0, 'invalid_envelope'], 'rejects unsigned-schema extensions even when signed');

is_deeply([verify_envelope($event, $signature, $key, now => $now + 301)], [0, 'stale_timestamp'], 'rejects stale signed timestamp');
my $future = { %$event, occurred_at => '2026-11-21T00:14:21Z' };
my $future_signature = sign_envelope($future, $key);
is_deeply([verify_envelope($future, $future_signature, $key, now => $now)], [0, 'stale_timestamp'], 'rejects timestamps beyond future tolerance');

is((build_envelope('arbitrary.event', { value => 'x' }, now => $now))[1], 'invalid_event', 'rejects event types outside the catalog');
is((build_envelope('instance.started', { backend => 'redis', account => 'alice' }, now => $now))[1], 'invalid_event', 'rejects unapproved metadata and account identifiers');
is((build_envelope('policy.denied', { operation => 'instance.stop', reason_code => 'not_authorized', text => 'secret' }, now => $now))[1], 'invalid_event', 'rejects free-form metadata');
is((build_envelope('instance.started', { backend => 'redis' }, event_id => 'not-random', now => $now))[1], 'invalid_event_id', 'validates random event ID shape');
is((build_envelope('instance.started', { backend => 'redis' }, event_id => '0123456789abcdef0123456789abcdef', occurred_at => '2026-02-31T00:00:00Z'))[1], 'invalid_timestamp', 'rejects impossible UTC dates');
is((build_envelope('instance.started', { backend => 'redis' }, event_id => '0123456789abcdef0123456789abcdef', now => $now))[1], undef, 'accepts a valid schema envelope');

done_testing();
