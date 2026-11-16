#!/usr/bin/perl
use strict;
use warnings;
use IO::Socket::UNIX;
use JSON::PP ();
use Socket qw(SHUT_WR);

my $socket = IO::Socket::UNIX->new(
    Type => SOCK_STREAM,
    Peer => '/run/orm/broker.sock',
) or exit 1;
binmode($socket);
print {$socket} "{\"operation\":\"instance.metrics\",\"version\":1}\n" or exit 1;
shutdown($socket, SHUT_WR) or exit 1;

my $response = '';
while (1) {
    my $chunk = '';
    my $read = sysread($socket, $chunk, 4096);
    exit 1 if !defined($read);
    last if $read == 0;
    $response .= $chunk;
    exit 1 if length($response) > 4096;
}
close($socket) or exit 1;
exit 1 if $response !~ /\A[^\n]*\n\z/;
my $decoded = eval { JSON::PP->new->decode(substr($response, 0, -1)) };
exit 1 if ref($decoded) ne 'HASH' || !$decoded->{success} || ($decoded->{version} // 0) != 1;
exit 0;
