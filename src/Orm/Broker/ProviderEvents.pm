package Orm::Broker::ProviderEvents;
use strict;
use warnings;
use Exporter qw(import);
use Digest::SHA qw(hmac_sha256_hex);
use JSON::PP ();
use Time::Local qw(timegm);

our @EXPORT_OK = qw(event_catalog build_envelope canonical_bytes sign_envelope verify_envelope);
my $JSON = JSON::PP->new->canonical(1)->utf8(1)->allow_nonref(0);
my %EVENTS = map { $_ => 1 } qw(
    backend.selected policy.denied quota.reached
    instance.provisioned instance.started instance.stopped instance.restarted instance.failed
);
my %OPERATIONS = map { $_ => 1 } qw(
    instance.provision instance.start instance.stop instance.restart
    instance.configure backup.create backup.restore backend.select
);
my %REASONS = map { $_ => 1 } qw(
    not_authorized quota_exceeded policy_disabled invalid_state unsupported_backend service_failed
);
my %QUOTAS = map { $_ => 1 } qw(instances memory_mib);
my %BACKENDS = map { $_ => 1 } qw(redis valkey);

sub event_catalog { return [sort keys %EVENTS]; }

sub _valid_timestamp {
    my ($value) = @_;
    return if !defined($value) || ref($value)
        || $value !~ /\A(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})Z\z/;
    my ($year, $month, $day, $hour, $minute, $second) = map { 0 + $_ } ($1, $2, $3, $4, $5, $6);
    return if $month < 1 || $month > 12 || $day < 1 || $day > 31
        || $hour > 23 || $minute > 59 || $second > 59;
    my $epoch = eval { timegm($second, $minute, $hour, $day, $month - 1, $year) };
    return if !defined($epoch);
    my @parts = gmtime($epoch);
    return if $parts[5] + 1900 != $year || $parts[4] + 1 != $month || $parts[3] != $day;
    return $epoch;
}

sub _metadata_valid {
    my ($type, $metadata) = @_;
    return 0 if ref($metadata) ne 'HASH';
    my %allowed = (
        'backend.selected' => { backend => \%BACKENDS },
        'policy.denied' => { operation => \%OPERATIONS, reason_code => \%REASONS },
        'quota.reached' => { quota_kind => \%QUOTAS },
        'instance.provisioned' => { backend => \%BACKENDS },
        'instance.started' => { backend => \%BACKENDS },
        'instance.stopped' => { backend => \%BACKENDS },
        'instance.restarted' => { backend => \%BACKENDS },
        'instance.failed' => { backend => \%BACKENDS, operation => \%OPERATIONS, reason_code => \%REASONS },
    );
    my $fields = $allowed{$type};
    return 0 if !defined($fields);
    return 0 if grep { !exists($fields->{$_}) } keys %$metadata;
    return 0 if grep { !exists($metadata->{$_}) } keys %$fields;
    for my $field (keys %$fields) {
        my $value = $metadata->{$field};
        return 0 if !defined($value) || ref($value) || !$fields->{$field}->{$value};
    }
    return 1;
}

sub build_envelope {
    my ($type, $metadata, %args) = @_;
    return (undef, 'invalid_event') if !defined($type) || ref($type) || !$EVENTS{$type}
        || !_metadata_valid($type, $metadata);
    my $event_id = $args{event_id};
    if (!defined($event_id)) {
        my $random = '';
        my $random_source;
        if (!open($random_source, '<:raw', '/dev/urandom')) {
            return (undef, 'random_unavailable');
        }
        my $read = read($random_source, $random, 16);
        close($random_source);
        return (undef, 'random_unavailable') if !defined($read) || $read != 16;
        $event_id = unpack('H*', $random);
    }
    return (undef, 'invalid_event_id') if ref($event_id) || $event_id !~ /\A[a-f0-9]{32}\z/;
    my $occurred_at = $args{occurred_at};
    if (!defined($occurred_at)) {
        my @utc = gmtime(defined($args{now}) ? $args{now} : time());
        $occurred_at = sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ',
            $utc[5] + 1900, $utc[4] + 1, $utc[3], $utc[2], $utc[1], $utc[0]);
    }
    return (undef, 'invalid_timestamp') if !_valid_timestamp($occurred_at);
    my $envelope = {
        event_id => $event_id,
        event_type => $type,
        metadata => { %$metadata },
        occurred_at => $occurred_at,
        schema_version => 1,
    };
    my $bytes = canonical_bytes($envelope);
    return (undef, 'event_too_large') if !defined($bytes) || length($bytes) > 16384;
    return ($envelope, undef);
}

sub canonical_bytes {
    my ($envelope) = @_;
    return if ref($envelope) ne 'HASH';
    return eval { $JSON->encode($envelope) };
}

sub sign_envelope {
    my ($envelope, $key) = @_;
    return if !defined($key) || ref($key) || length($key) < 32 || length($key) > 128;
    my $bytes = canonical_bytes($envelope);
    return if !defined($bytes) || length($bytes) > 16384;
    return hmac_sha256_hex($bytes, $key);
}

sub verify_envelope {
    my ($envelope, $signature, $key, %args) = @_;
    return (0, 'invalid_signature') if !defined($signature) || ref($signature)
        || $signature !~ /\A[a-f0-9]{64}\z/;
    return (0, 'invalid_key') if !defined($key) || ref($key) || length($key) < 32 || length($key) > 128;
    return (0, 'invalid_envelope') if ref($envelope) ne 'HASH';
    my %envelope_keys = map { $_ => 1 } qw(event_id event_type metadata occurred_at schema_version);
    return (0, 'invalid_envelope') if (grep { !$envelope_keys{$_} } keys %$envelope)
        || (grep { !exists($envelope->{$_}) } keys %envelope_keys)
        || ($envelope->{schema_version} // 0) != 1
        || !defined($envelope->{event_type}) || !$EVENTS{$envelope->{event_type}}
        || !_metadata_valid($envelope->{event_type}, $envelope->{metadata})
        || !defined($envelope->{event_id}) || ref($envelope->{event_id})
        || $envelope->{event_id} !~ /\A[a-f0-9]{32}\z/;
    my $epoch = _valid_timestamp($envelope->{occurred_at});
    return (0, 'invalid_timestamp') if !defined($epoch);
    my $now = defined($args{now}) ? $args{now} : time();
    my $max_age = defined($args{max_age_seconds}) ? $args{max_age_seconds} : 300;
    return (0, 'invalid_timestamp') if ref($max_age) || $max_age !~ /\A[1-9][0-9]{0,5}\z/ || $max_age > 86_400;
    return (0, 'stale_timestamp') if $epoch < $now - $max_age || $epoch > $now + 60;
    my $seen = $args{seen_ids};
    return (0, 'duplicate_event') if ref($seen) eq 'HASH' && $seen->{$envelope->{event_id}};
    my $expected = sign_envelope($envelope, $key);
    return (0, 'invalid_envelope') if !defined($expected);
    my $difference = 0;
    for my $index (0 .. 63) {
        $difference |= ord(substr($expected, $index, 1)) ^ ord(substr($signature, $index, 1));
    }
    return (0, 'invalid_signature') if $difference != 0;
    $seen->{$envelope->{event_id}} = 1 if ref($seen) eq 'HASH';
    return (1, 'ok');
}

1;
