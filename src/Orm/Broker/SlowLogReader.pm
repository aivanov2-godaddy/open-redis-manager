package Orm::Broker::SlowLogReader;
use strict;
use warnings;

my $MAX_REPLY_BYTES = 65536;
my $MAX_FETCHED_ENTRIES = 11;
my $MAX_RETURNED_ENTRIES = 10;
my $MAX_ARGUMENTS = 128;
my $MAX_BULK_BYTES = 65536;
my $MAX_INTEGER = 9_000_000_000_000_000;

sub parse_handle {
    my ($class, $handle) = @_;
    return undef if !defined($handle);
    my $state = { handle => $handle, bytes => 0 };
    my $count = _read_array_length($state, $MAX_FETCHED_ENTRIES);
    return undef if !defined($count);

    my @entries;
    for (1 .. $count) {
        my $fields = _read_array_length($state, 7);
        return undef if !defined($fields) || ($fields != 6 && $fields != 7);
        my $id = _read_integer($state);
        my $timestamp = _read_integer($state);
        my $duration = _read_integer($state);
        return undef if !defined($id) || !defined($timestamp) || !defined($duration)
            || $timestamp > 253402300799;

        my $argument_count = _read_array_length($state, $MAX_ARGUMENTS);
        return undef if !defined($argument_count) || $argument_count < 1;
        my $command = _read_bulk_string($state, $argument_count == 0 ? 0 : 1);
        return undef if !defined($command);
        for (2 .. $argument_count) {
            return undef if !defined(_read_bulk_string($state, 0));
        }

        # Client address and name are intentionally consumed and discarded.
        return undef if !defined(_read_bulk_string($state, 0));
        return undef if !defined(_read_bulk_string($state, 0));
        if ($fields == 7) {
            my $total_arguments = _read_integer($state);
            return undef if !defined($total_arguments) || $total_arguments < $argument_count;
        }

        my $safe_command = $command =~ /\A[A-Za-z][A-Za-z0-9_.|]{0,63}\z/
            ? lc($command) : 'other';
        push @entries, {
            command => $safe_command,
            duration_usec => $duration,
            timestamp => $timestamp,
        };
    }

    my $truncated = @entries > $MAX_RETURNED_ENTRIES ? 1 : 0;
    splice(@entries, $MAX_RETURNED_ENTRIES) if $truncated;
    return { entries => \@entries, truncated => $truncated };
}

sub expect_simple_ok {
    my ($class, $handle) = @_;
    return 0 if !defined($handle);
    my $state = { handle => $handle, bytes => 0 };
    my $marker = _read_bytes($state, 1);
    my $line = _read_line($state);
    return defined($marker) && $marker eq '+' && defined($line) && $line eq 'OK';
}

sub _read_array_length {
    my ($state, $maximum) = @_;
    my $marker = _read_bytes($state, 1);
    my $line = _read_line($state);
    return undef if !defined($marker) || $marker ne '*' || !defined($line)
        || $line !~ /\A(?:0|[1-9][0-9]{0,5})\z/;
    my $length = 0 + $line;
    return undef if $length > $maximum;
    return $length;
}

sub _read_integer {
    my ($state) = @_;
    my $marker = _read_bytes($state, 1);
    my $line = _read_line($state);
    return undef if !defined($marker) || $marker ne ':' || !defined($line)
        || $line !~ /\A(?:0|[1-9][0-9]{0,15})\z/ || $line > $MAX_INTEGER;
    return 0 + $line;
}

sub _read_bulk_string {
    my ($state, $capture) = @_;
    my $marker = _read_bytes($state, 1);
    my $line = _read_line($state);
    return undef if !defined($marker) || $marker ne '$' || !defined($line);
    return '' if $line eq '-1' && !$capture;
    return undef if $line !~ /\A(?:0|[1-9][0-9]{0,5})\z/;
    my $length = 0 + $line;
    return undef if $length > $MAX_BULK_BYTES;
    my $value = _read_bytes($state, $length, $capture && $length <= 64);
    return undef if !defined($value);
    my $terminator = _read_bytes($state, 2);
    return undef if !defined($terminator) || $terminator ne "\r\n";
    return $value;
}

sub _read_line {
    my ($state) = @_;
    my $line = '';
    while (length($line) <= 32) {
        my $byte = _read_bytes($state, 1);
        return undef if !defined($byte);
        if ($byte eq "\r") {
            my $lf = _read_bytes($state, 1);
            return defined($lf) && $lf eq "\n" ? $line : undef;
        }
        return undef if $byte eq "\n" || ord($byte) < 0x20 || ord($byte) > 0x7e;
        $line .= $byte;
    }
    return undef;
}

sub _read_bytes {
    my ($state, $length, $capture) = @_;
    return '' if $length == 0;
    return undef if $state->{bytes} + $length > $MAX_REPLY_BYTES;
    my $keep = !defined($capture) || $capture;
    my $value = '';
    my $remaining = $length;
    while ($remaining > 0) {
        my $chunk = '';
        my $wanted = $remaining > 4096 ? 4096 : $remaining;
        my $read = read($state->{handle}, $chunk, $wanted);
        return undef if !defined($read) || $read == 0;
        $state->{bytes} += $read;
        $remaining -= $read;
        $value .= $chunk if $keep;
    }
    return $keep ? $value : '';
}

1;
