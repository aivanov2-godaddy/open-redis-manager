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
    return undef if $frame ne '{"operation":"identity","version":1}' . "\n";

    return { operation => 'identity', version => 1 };
}

sub encode_response {
    my ($response) = @_;
    return undef if ref($response) ne 'HASH';

    my $encoded = eval { $JSON->encode($response) . "\n" };
    return undef if !defined($encoded) || length($encoded) > $MAX_FRAME_BYTES;
    return $encoded;
}

1;
