package Orm::Broker::Protocol;
use strict;
use warnings;
use Exporter qw(import);
use JSON::PP ();

our @EXPORT_OK = qw(parse_request encode_response max_frame_bytes);
my $MAX_FRAME_BYTES = 4096;
my $MAX_RESPONSE_BYTES = 40960;
my $JSON = JSON::PP->new->canonical(1)->utf8(1)->allow_nonref(0);

sub max_frame_bytes { return $MAX_FRAME_BYTES; }

sub parse_request {
    my ($frame) = @_;
    return undef if !defined($frame) || ref($frame);
    return undef if length($frame) > $MAX_FRAME_BYTES;
    if ($frame =~ /\A\{"offset":(0|[1-9][0-9]{0,5}),"operation":"fleet\.list","version":1\}\n\z/) {
        return { offset => 0 + $1, operation => 'fleet.list', version => 1 };
    }
    if ($frame =~ /\A\{"action":"(start|stop|restart)","operation":"fleet\.control","username":"([a-zA-Z0-9_-]{1,16})","version":1\}\n\z/) {
        return { action => $1, operation => 'fleet.control', username => $2, version => 1 };
    }
    if ($frame =~ /\A\{"operation":"fleet\.backup\.create","username":"([a-zA-Z0-9_-]{1,16})","version":1\}\n\z/) {
        return { operation => 'fleet.backup.create', username => $1, version => 1 };
    }
    if ($frame =~ /\A\{"backup_id":"(snapshot-[0-9]{10}-[a-f0-9]{8}[.]rdb)","operation":"fleet\.backup\.restore","username":"([a-zA-Z0-9_-]{1,16})","version":1\}\n\z/) {
        return { backup_id => $1, operation => 'fleet.backup.restore', username => $2, version => 1 };
    }
    if ($frame =~ /\A\{"backup_id":"(snapshot-[0-9]{10}-[a-f0-9]{8}[.]rdb)","operation":"backup\.restore","version":1\}\n\z/) {
        return { backup_id => $1, operation => 'backup.restore', version => 1 };
    }
    if ($frame =~ /\A\{"operation":"metrics\.history","range":"(24h|7d)","version":1\}\n\z/) {
        return { operation => 'metrics.history', range => $1, version => 1 };
    }
    if ($frame =~ /\A\{"operation":"instance\.provision","preset":"(wordpress|laravel|magento|session|generic)","version":1\}\n\z/) {
        return { operation => 'instance.provision', preset => $1, version => 1 };
    }
    if ($frame =~ /\A\{"maxclients":([1-9][0-9]{0,2}),"maxmemory_policy":"(allkeys-lru|allkeys-lfu|allkeys-random|volatile-lru|volatile-lfu|volatile-random|volatile-ttl|noeviction)","memory_mib":([1-9][0-9]{0,2}),"operation":"instance\.configure","timeout":(0|[1-9][0-9]{0,2}),"version":1\}\n\z/) {
        my ($maxclients, $policy, $memory_mib, $timeout) = (0 + $1, $2, 0 + $3, 0 + $4);
        return undef if $maxclients < 10 || $maxclients > 100
            || $memory_mib < 8 || $memory_mib > 64 || $timeout > 300;
        return {
            maxclients => $maxclients,
            maxmemory_policy => $policy,
            memory_mib => $memory_mib,
            operation => 'instance.configure',
            timeout => $timeout,
            version => 1,
        };
    }
    return undef if $frame !~ /\A\{"operation":"(identity|instance\.status|instance\.metrics|instance\.provision|instance\.start|instance\.stop|backup\.create|backup\.list)","version":1\}\n\z/;

    my ($operation) = $frame =~ /\A\{"operation":"([^"\\]+)",/;
    return undef if !defined($operation);
    return { operation => $operation, version => 1 };
}

sub encode_response {
    my ($response) = @_;
    return undef if ref($response) ne 'HASH';

    my $encoded = eval { $JSON->encode($response) . "\n" };
    return undef if !defined($encoded) || length($encoded) > $MAX_RESPONSE_BYTES;
    return $encoded;
}

1;
