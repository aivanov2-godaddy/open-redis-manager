package Orm::Broker::ProviderEventQueue;
use strict;
use warnings;
use Fcntl qw(O_CREAT O_EXCL O_RDONLY O_RDWR O_WRONLY O_NOFOLLOW :flock :mode);
use IO::Handle;
use JSON::PP ();
use Orm::Broker::ProviderEvents qw(verify_envelope canonical_bytes);

my $JSON = JSON::PP->new->canonical(1)->utf8(1)->allow_nonref(0);
my $MAX_RECORDS = 256;
my $MAX_BYTES = 1_048_576;
my $MAX_RECORD_BYTES = 18_432;
my $MAX_AGE = 86_400;
my $MAX_ATTEMPTS = 8;

sub new {
    my ($class, %args) = @_;
    return bless {
        directory => $args{directory} // '/var/lib/orm-events/outbox',
        owner_uid => defined($args{owner_uid}) ? $args{owner_uid} : 0,
    }, $class;
}

sub _safe_directory {
    my ($self) = @_;
    my @st = lstat($self->{directory});
    return 0 if !@st || !S_ISDIR($st[2]) || S_ISLNK($st[2])
        || $st[4] != $self->{owner_uid} || ($st[2] & 07777) != 0700;
    return 1;
}

sub _locked {
    my ($self, $callback) = @_;
    return (undef, 'unsafe_directory') if !$self->_safe_directory();
    my $path = $self->{directory} . '/.queue.lock';
    my $mode = O_CREAT | O_RDWR | O_NOFOLLOW;
    return (undef, 'lock_failed') if !sysopen(my $lock, $path, $mode, 0600);
    my @st = stat($lock);
    if (!@st || !S_ISREG($st[2]) || $st[4] != $self->{owner_uid} || ($st[2] & 07777) != 0600
        || !flock($lock, LOCK_EX | LOCK_NB)) {
        close($lock);
        return (undef, 'lock_failed');
    }
    my @result = eval { $callback->() };
    my $failed = $@;
    flock($lock, LOCK_UN);
    close($lock);
    return (undef, 'queue_failed') if $failed;
    return @result;
}

sub _records {
    my ($self) = @_;
    opendir(my $dh, $self->{directory}) or die 'queue_unavailable';
    my @names = sort grep { /\A[0-9a-f]{32}[.]json\z/ } readdir($dh);
    closedir($dh);
    my @records;
    my $bytes = 0;
    for my $name (@names) {
        my $path = $self->{directory} . '/' . $name;
        my @st = lstat($path);
        die 'unsafe_record' if !@st || !S_ISREG($st[2]) || $st[4] != $self->{owner_uid}
            || ($st[2] & 07777) != 0600 || $st[7] > $MAX_RECORD_BYTES;
        sysopen(my $fh, $path, O_RDONLY | O_NOFOLLOW) or die 'queue_read_failed';
        local $/;
        my $raw = <$fh>;
        close($fh);
        my $record = eval { $JSON->decode($raw) };
        die 'invalid_record' if ref($record) ne 'HASH' || ($record->{id} // '') ne substr($name, 0, 32)
            || ($record->{schema} // '') ne 'orm-provider-event-v1'
            || ($record->{state} // '') !~ /\A(?:pending|sending|delivered|failed|expired)\z/
            || ($record->{attempts} // -1) !~ /\A[0-8]\z/
            || ref($record->{event}) ne 'HASH' || ($record->{signature} // '') !~ /\A[a-f0-9]{64}\z/;
        push @records, $record;
        $bytes += $st[7];
    }
    return (\@records, $bytes);
}

sub _write_record {
    my ($self, $record) = @_;
    my $raw = eval { $JSON->encode($record) };
    return 0 if !defined($raw) || length($raw) > $MAX_RECORD_BYTES;
    my $path = $self->{directory} . '/' . $record->{id} . '.json';
    my $temporary = $path . '.' . $$ . '.' . int(rand(1_000_000)) . '.tmp';
    return 0 if !sysopen(my $fh, $temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    binmode($fh);
    my $ok = print {$fh} $raw;
    $ok &&= $fh->flush() if $fh->can('flush');
    $ok &&= $fh->sync();
    close($fh) or $ok = 0;
    if (!$ok || !rename($temporary, $path)) {
        unlink($temporary);
        return 0;
    }
    return 1;
}

sub _prune_records {
    my ($self, $records, $now) = @_;
    for my $record (@$records) {
        my $state = $record->{state} // '';
        my $terminal_at = $record->{finished_at};
        $terminal_at = $record->{expires_at} if $state eq 'expired' && !defined($terminal_at);
        next if $state =~ /\A(?:pending|sending)\z/ || !defined($terminal_at) || $terminal_at > $now - $MAX_AGE;
        my $path = $self->{directory} . '/' . $record->{id} . '.json';
        my @st = lstat($path);
        die 'unsafe_record' if !@st || !S_ISREG($st[2]) || $st[4] != $self->{owner_uid}
            || ($st[2] & 07777) != 0600;
        unlink($path) or die 'record_prune_failed';
    }
    return 1;
}

sub enqueue {
    my ($self, $event, $signature, $key, $now) = @_;
    $now = time() if !defined($now);
    return (0, 'invalid_event') if ref($event) ne 'HASH';
    my ($valid) = verify_envelope($event, $signature, $key, now => $now);
    return (0, 'invalid_event') if !$valid;
    my $bytes = canonical_bytes($event);
    return (0, 'event_too_large') if !defined($bytes) || length($bytes) > 16_384;
    return $self->_locked(sub {
        my ($records, $total) = $self->_records();
        $self->_prune_records($records, $now);
        ($records, $total) = $self->_records();
        my @active = grep { ($_->{state} // '') =~ /\A(?:pending|sending)\z/ && ($_->{expires_at} // 0) > $now } @$records;
        return (0, 'duplicate_event') if grep { ($_->{id} // '') eq $event->{event_id} } @$records;
        my $record = {
            schema => 'orm-provider-event-v1',
            id => $event->{event_id}, event => $event, signature => $signature,
            state => 'pending', attempts => 0, queued_at => 0 + $now,
            next_attempt_at => 0 + $now, expires_at => 0 + $now + $MAX_AGE,
        };
        my $record_bytes = eval { length($JSON->encode($record)) };
        return (0, 'queue_full') if @active >= $MAX_RECORDS || !defined($record_bytes)
            || $total + $record_bytes > $MAX_BYTES;
        return (0, 'persist_failed') if !$self->_write_record($record);
        return (1, 'queued');
    });
}

sub claim_due {
    my ($self, $now) = @_;
    $now = time() if !defined($now);
    return $self->_locked(sub {
        my ($records) = $self->_records();
        for my $record (@$records) {
            if (($record->{state} // '') eq 'sending' && ($record->{claimed_at} // 0) <= $now - 600) {
                $record->{state} = $record->{attempts} >= $MAX_ATTEMPTS ? 'failed' : 'pending';
                my $delay = 30 * (2 ** (($record->{attempts} // 1) - 1));
                $record->{next_attempt_at} = $now + ($delay > 3600 ? 3600 : $delay);
                $record->{finished_at} = 0 + $now if $record->{state} eq 'failed';
                delete $record->{claimed_at};
                $self->_write_record($record) or die 'state_write_failed';
            }
            if (($record->{state} // '') =~ /\A(?:pending|sending)\z/ && ($record->{expires_at} // 0) <= $now) {
                $record->{state} = 'expired';
                $record->{finished_at} = 0 + $now;
                delete $record->{claimed_at};
                $self->_write_record($record) or die 'state_write_failed';
            }
        }
        my @due = sort { $a->{next_attempt_at} <=> $b->{next_attempt_at} || $a->{queued_at} <=> $b->{queued_at} }
            grep { ($_->{state} // '') eq 'pending' && ($_->{next_attempt_at} // 0) <= $now } @$records;
        return (undef, 'empty') if !@due;
        my $record = $due[0];
        $record->{state} = 'sending';
        $record->{attempts}++;
        $record->{claimed_at} = 0 + $now;
        $self->_write_record($record) or die 'state_write_failed';
        return ({ id => $record->{id}, event => $record->{event}, signature => $record->{signature}, attempts => $record->{attempts} }, 'claimed');
    });
}

sub finish_attempt {
    my ($self, $id, $outcome, $http_status, $now) = @_;
    $now = time() if !defined($now);
    return (0, 'invalid_result') if !defined($id) || $id !~ /\A[a-f0-9]{32}\z/
        || !defined($outcome) || $outcome !~ /\A(?:delivered|retryable|permanent)\z/
        || (defined($http_status) && ($http_status !~ /\A[1-5][0-9]{2}\z/));
    return $self->_locked(sub {
        my ($records) = $self->_records();
        $self->_prune_records($records, $now);
        ($records) = $self->_records();
        my ($record) = grep { $_->{id} eq $id } @$records;
        return (0, 'not_found') if !defined($record);
        return (0, 'not_claimed') if $record->{state} ne 'sending';
        delete $record->{claimed_at};
        $record->{last_result} = $outcome;
        $record->{http_status} = 0 + $http_status if defined($http_status);
        if ($outcome eq 'delivered') {
            $record->{state} = 'delivered';
            $record->{finished_at} = 0 + $now;
        } elsif ($outcome eq 'permanent' || $record->{attempts} >= $MAX_ATTEMPTS) {
            $record->{state} = 'failed';
            $record->{finished_at} = 0 + $now;
        } else {
            my $delay = 30 * (2 ** ($record->{attempts} - 1));
            $delay = 3600 if $delay > 3600;
            $record->{state} = 'pending';
            $record->{next_attempt_at} = 0 + $now + $delay + int(rand(11));
        }
        $self->_write_record($record) or die 'state_write_failed';
        return (1, $record->{state});
    });
}

sub status {
    my ($self, $now) = @_;
    $now = time() if !defined($now);
    return $self->_locked(sub {
        my ($records) = $self->_records();
        $self->_prune_records($records, $now);
        ($records) = $self->_records();
        my %counts = map { $_ => 0 } qw(pending sending delivered failed expired);
        my @safe;
        for my $record (@$records) {
            my $state = $record->{state} // 'failed';
            $state = 'expired' if ($record->{expires_at} // 0) <= $now && $state =~ /\A(?:pending|sending)\z/;
            $counts{$state}++ if exists $counts{$state};
            my $record_summary = {
                age_seconds => $now > ($record->{queued_at} // 0) ? 0 + ($now - $record->{queued_at}) : 0,
                state => $state,
                attempts => 0 + ($record->{attempts} // 0),
                next_attempt_at => 0 + ($record->{next_attempt_at} // 0),
            };
            $record_summary->{outcome} = $record->{last_result}
                if ($record->{last_result} // '') =~ /\A(?:delivered|retryable|permanent)\z/;
            push @safe, $record_summary;
        }
        return ({ counts => \%counts, records => \@safe }, 'ok');
    });
}

1;
