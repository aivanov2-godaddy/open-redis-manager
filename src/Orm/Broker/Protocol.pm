package Orm::Broker::Protocol;
use strict;
use warnings;
use Exporter qw(import);
use JSON::PP ();

our @EXPORT_OK = qw(parse_request encode_response max_frame_bytes);
my $MAX_FRAME_BYTES = 4096;
my $MAX_RESPONSE_BYTES = 262144;
my $JSON = JSON::PP->new->canonical(1)->utf8(1)->allow_nonref(0);

sub max_frame_bytes { return $MAX_FRAME_BYTES; }

sub parse_request {
    my ($frame) = @_;
    return undef if !defined($frame) || ref($frame);
    return undef if length($frame) > $MAX_FRAME_BYTES;
    if ($frame =~ /\A\{"offset":(0|[1-9][0-9]{0,5}),"operation":"fleet\.list","version":1\}\n\z/) {
        return { offset => 0 + $1, operation => 'fleet.list', version => 1 };
    }
    if ($frame =~ /\A\{"operation":"fleet\.summary","version":1\}\n\z/) {
        return { operation => 'fleet.summary', version => 1 };
    }
    if ($frame =~ /\A\{"operation":"fleet\.auto_provision","username":"([a-zA-Z0-9_-]{1,16})","version":1\}\n\z/) {
        return { operation => 'fleet.auto_provision', username => $1, version => 1 };
    }
    if ($frame =~ /\A\{"command_class":"(ping|info_server|info_memory|info_clients|info_stats|dbsize)","operation":"fleet\.diagnostics","username":"([a-zA-Z0-9_-]{1,16})","version":1\}\n\z/) {
        return { command_class => $1, operation => 'fleet.diagnostics', username => $2, version => 1 };
    }
    if ($frame =~ /\A\{"operation":"fleet\.recovery\.scan","username":"([a-zA-Z0-9_-]{1,16})","version":1\}\n\z/) {
        return { operation => 'fleet.recovery.scan', username => $1, version => 1 };
    }
    if ($frame =~ /\A\{"operation":"fleet\.recovery\.repair","repair":"(start|config_rebuild)","username":"([a-zA-Z0-9_-]{1,16})","version":1\}\n\z/) {
        return { operation => 'fleet.recovery.repair', repair => $1, username => $2, version => 1 };
    }
    if ($frame =~ /\A\{"operation":"fleet\.auth\.rotate","username":"([a-zA-Z0-9_-]{1,16})","version":1\}\n\z/) {
        return { operation => 'fleet.auth.rotate', username => $1, version => 1 };
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
    if ($frame =~ /\A\{"operation":"fleet\.backup\.batch\.create","targets":\["([a-zA-Z0-9_-]{1,16})"(?:,"([a-zA-Z0-9_-]{1,16})")?\],"version":1\}\n\z/) {
        my @usernames = grep { defined($_) } ($1, $2);
        my %seen;
        return undef if grep { $seen{$_}++ } @usernames;
        return { operation => 'fleet.backup.batch.create', targets => [map { { username => $_ } } @usernames], version => 1 };
    }
    if ($frame =~ /\A\{"operation":"fleet\.backup\.batch\.restore","targets":\[\{"backup_id":"(snapshot-[0-9]{10}-[a-f0-9]{8}[.]rdb)","username":"([a-zA-Z0-9_-]{1,16})"\}(?:,\{"backup_id":"(snapshot-[0-9]{10}-[a-f0-9]{8}[.]rdb)","username":"([a-zA-Z0-9_-]{1,16})"\})?\],"version":1\}\n\z/) {
        my @targets = ({ backup_id => $1, username => $2 });
        push @targets, { backup_id => $3, username => $4 } if defined($3);
        my %seen;
        return undef if grep { $seen{$_->{username}}++ } @targets;
        return { operation => 'fleet.backup.batch.restore', targets => \@targets, version => 1 };
    }
    if ($frame =~ /\A\{"operation":"fleet\.migrate","target_backend":"valkey","username":"([a-zA-Z0-9_-]{1,16})","version":1,"writes_quiesced":true\}\n\z/) {
        return { operation => 'fleet.migrate', target_backend => 'valkey', username => $1, version => 1, writes_quiesced => 1 };
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
    if ($frame =~ /\A\{"operation":"provider\.events\.(status|queue\.status)","version":1\}\n\z/) {
        return { operation => 'provider.events.' . $1, version => 1 };
    }
    if ($frame =~ /\A\{"destination":"([A-Za-z0-9:\/._~!\$&'()*+,;=@%-]{0,2048})","enabled":(true|false),"operation":"provider\.events\.configure","rotate_key":(true|false),"version":1\}\n\z/) {
        return {
            destination => $1,
            enabled => $2 eq 'true' ? 1 : 0,
            operation => 'provider.events.configure',
            rotate_key => $3 eq 'true' ? 1 : 0,
            version => 1,
        };
    }
    if ($frame =~ /\A\{"backend":"(redis|valkey)","operation":"provider\.backend\.selected","version":1\}\n\z/) {
        return { backend => $1, operation => 'provider.backend.selected', version => 1 };
    }
    return undef if $frame !~ /\A\{"operation":"(identity|instance\.status|instance\.auth\.status|instance\.auth\.rotate|instance\.auth\.disable|instance\.metrics|instance\.provision|instance\.start|instance\.stop|backup\.create|backup\.list|provider\.exposure|provider\.branding|provider\.resellers)","version":1\}\n\z/;

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
