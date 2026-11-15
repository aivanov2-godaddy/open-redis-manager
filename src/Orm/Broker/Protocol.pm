package Orm::Broker::Protocol;
use strict;
use warnings;
use Exporter qw(import);
use JSON::PP ();

our @EXPORT_OK = qw(parse_request encode_response max_frame_bytes);
my $MAX_FRAME_BYTES = 4096;
my $JSON = JSON::PP->new->canonical(1)->utf8(1)->allow_nonref(0);

sub max_frame_bytes { return $MAX_FRAME_BYTES; }

sub parse_request {
    my ($frame) = @_;
    return undef if !defined($frame) || ref($frame);
    return undef if length($frame) > $MAX_FRAME_BYTES;
    if ($frame =~ /\A\{"offset":(0|[1-9][0-9]{0,5}),"operation":"fleet\.list","version":1\}\n\z/) {
        return { offset => 0 + $1, operation => 'fleet.list', version => 1 };
    }
    if ($frame =~ /\A\{"operation":"instance\.provision","preset":"(wordpress|laravel|magento|session|generic)","version":1\}\n\z/) {
        return { operation => 'instance.provision', preset => $1, version => 1 };
    }
    return undef if $frame !~ /\A\{"operation":"(identity|instance\.status|instance\.metrics|instance\.provision|instance\.start|instance\.stop)","version":1\}\n\z/;

    my ($operation) = $frame =~ /\A\{"operation":"([^"\\]+)",/;
    return undef if !defined($operation);
    return { operation => $operation, version => 1 };
}

sub encode_response {
    my ($response) = @_;
    return undef if ref($response) ne 'HASH';

    my $encoded = eval { $JSON->encode($response) . "\n" };
    return undef if !defined($encoded) || length($encoded) > $MAX_FRAME_BYTES;
    return $encoded;
}

1;
