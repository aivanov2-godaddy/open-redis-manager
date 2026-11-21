package Orm::Broker::ProviderEventTransport;
use strict;
use warnings;
use Exporter qw(import);
use IO::Socket::SSL qw(SSL_VERIFY_PEER);
use IO::Select;
use Orm::Broker::ProviderEvents qw(canonical_bytes verify_envelope);
use Orm::Broker::ProviderEventEndpoint qw(validate_destination);

our @EXPORT_OK = qw(deliver_event);
my $MAX_RESPONSE = 4096;
my $MAX_REQUEST = 20_000;

sub _result {
    my ($outcome, $code, $status) = @_;
    my %result = (outcome => $outcome, code => $code);
    $result{http_status} = 0 + $status if defined($status) && $status =~ /\A[1-5][0-9]{2}\z/;
    return \%result;
}

sub _write_all {
    my ($socket, $data, $deadline) = @_;
    my $offset = 0;
    while ($offset < length($data)) {
        return 0 if time() >= $deadline;
        my $written = syswrite($socket, $data, length($data) - $offset, $offset);
        return 0 if !defined($written) || $written <= 0;
        $offset += $written;
    }
    return 1;
}

sub _read_headers {
    my ($socket, $deadline) = @_;
    my $selector = IO::Select->new($socket);
    my $response = '';
    while (length($response) <= $MAX_RESPONSE) {
        my $remaining = $deadline - time();
        return (undef, 'timeout') if $remaining <= 0 || !$selector->can_read($remaining);
        my $chunk = '';
        my $read = sysread($socket, $chunk, 1024);
        return (undef, 'network_error') if !defined($read) || $read == 0;
        $response .= $chunk;
        my $header_end = index($response, "\r\n\r\n");
        return (undef, 'response_too_large') if $header_end < 0 && length($response) >= $MAX_RESPONSE;
        next if $header_end < 0;
        return (undef, 'response_too_large') if $header_end + 4 > $MAX_RESPONSE;
        my $headers = substr($response, 0, $header_end);
        my @lines = split /\r\n/, $headers;
        return (undef, 'invalid_response') if !@lines || $lines[0] !~ /\AHTTP\/1\.[01] ([1-5][0-9]{2})(?: [\x20-\x7e]*)?\z/;
        my $status = 0 + $1;
        for my $line (@lines[1 .. $#lines]) {
            return (undef, 'invalid_response') if $line !~ /\A[!#\$%&'*+.^_`|~0-9A-Za-z-]+:[\x20-\x7e\t]*\z/;
            return (undef, 'redirect_rejected', $status) if $line =~ /\Alocation\s*:/i && $status >= 300 && $status < 400;
        }
        return ($status, undef);
    }
    return (undef, 'response_too_large');
}

sub deliver_event {
    my ($destination, $event, $signature, $key, %args) = @_;
    return _result('permanent', 'invalid_event') if ref($event) ne 'HASH'
        || !defined($signature) || $signature !~ /\A[a-f0-9]{64}\z/
        || !defined($key) || ref($key) || length($key) < 32 || length($key) > 128;
    my ($verified) = verify_envelope($event, $signature, $key,
        now => $args{now}, max_age_seconds => 86_400);
    return _result('permanent', 'invalid_event') if !$verified;
    my $body = canonical_bytes($event);
    return _result('permanent', 'invalid_event') if !defined($body) || length($body) > 16_384;
    my ($endpoint, $error) = validate_destination($destination, $args{resolved_addresses});
    return _result($error eq 'dns_failed' ? 'retryable' : 'permanent', $error // 'invalid_destination')
        if !defined($endpoint);
    my $deadline = time() + 10;
    my $socket;
    my $factory = $args{socket_factory};
    for my $address (@{$endpoint->{addresses}}) {
        last if time() >= $deadline;
        $socket = defined($factory) ? $factory->($endpoint->{host}, $address) : IO::Socket::SSL->new(
            PeerAddr => $address,
            PeerPort => 443,
            PeerHost => $endpoint->{host},
            Timeout => 4,
            SSL_hostname => $endpoint->{host},
            SSL_verifycn_name => $endpoint->{host},
            SSL_verifycn_scheme => 'http',
            SSL_verify_mode => SSL_VERIFY_PEER,
            SSL_version => 'TLSv12',
        );
        last if $socket;
    }
    return _result('retryable', 'connect_failed') if !$socket;
    my $host = $endpoint->{host};
    my $request = "POST $endpoint->{path} HTTP/1.1\r\n"
        . "Host: $host\r\n"
        . "User-Agent: Open-Redis-Manager/1\r\n"
        . "Content-Type: application/json\r\n"
        . "Content-Length: " . length($body) . "\r\n"
        . "Connection: close\r\n"
        . "X-ORM-Schema-Version: 1\r\n"
        . "X-ORM-Event-Id: $event->{event_id}\r\n"
        . "X-ORM-Event-Timestamp: $event->{occurred_at}\r\n"
        . "X-ORM-Signature: $signature\r\n\r\n"
        . $body;
    return _result('permanent', 'request_too_large') if length($request) > $MAX_REQUEST;
    my $write_deadline = time() + 5;
    if (!_write_all($socket, $request, $write_deadline)) {
        close($socket);
        return _result('retryable', 'request_failed');
    }
    my ($status, $read_error, $rejected_status) = _read_headers($socket, $deadline);
    close($socket);
    return _result($read_error eq 'timeout' || $read_error eq 'network_error' ? 'retryable' : 'permanent', $read_error, $rejected_status)
        if defined($read_error);
    return _result('delivered', 'accepted', $status) if $status >= 200 && $status < 300;
    return _result('retryable', 'remote_temporary_failure', $status)
        if $status == 408 || $status == 425 || $status == 429 || $status >= 500;
    return _result('permanent', $status >= 300 && $status < 400 ? 'redirect_rejected' : 'remote_rejected', $status);
}

1;
