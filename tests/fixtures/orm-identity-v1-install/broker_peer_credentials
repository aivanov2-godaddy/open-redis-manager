package Orm::Broker::PeerCredentials;
use strict;
use warnings;
use Socket qw(SOL_SOCKET);

# Linux UAPI: SO_PEERCRED is 17 and returns struct ucred (pid_t, uid_t, gid_t).
sub uid_from_socket {
    my ($class, $socket) = @_;
    return undef if $^O ne 'linux' || !defined($socket);

    my $credentials = getsockopt($socket, SOL_SOCKET, 17);
    return undef if !defined($credentials) || length($credentials) != 12;
    my ($pid, $uid, $gid) = unpack('l3', $credentials);
    return undef if !defined($pid) || !defined($uid) || !defined($gid) || $uid < 0;
    return $uid;
}

1;
