package Orm::Broker::Server;
use strict;
use warnings;
use Errno qw(EAGAIN EWOULDBLOCK EINTR);
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK :mode);
use IO::Select;
use IO::Socket::UNIX;
use JSON::PP ();
use Socket qw(SOCK_STREAM);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);
use Orm::Broker::AccountResolver;
use Orm::Broker::Handler;
use Orm::Broker::PeerCredentials;
use Orm::Broker::InstanceManager;
use Orm::Broker::FleetInventory;
use Orm::Broker::Protocol qw(max_frame_bytes encode_response);

my $MAX_CLIENTS = 64;
my $CLIENT_TIMEOUT_SECONDS = 5;
my $IDENTITY_RATE_LIMIT_PER_SECOND = 16;
my $MUTATION_RATE_LIMIT_PER_SECOND = 2;

sub run {
    my ($class, %args) = @_;
    my $socket_path = $args{socket_path} // '/run/orm/broker.sock';
    my $account_root = $args{account_root} // '/var/cpanel/users';
    die "ORM broker requires Linux\n" if $^O ne 'linux';
    die "ORM broker must run as root\n" if $> != 0;
    die "ORM broker socket path must be absolute\n" if $socket_path !~ m{\A/};
    die "ORM broker account root must be absolute\n" if $account_root !~ m{\A/};

    my $runtime_dir = $socket_path;
    $runtime_dir =~ s{/[^/]+\z}{};
    my @directory_stat = lstat($runtime_dir);
    die "ORM broker runtime directory is not trusted\n"
        if !@directory_stat || !S_ISDIR($directory_stat[2])
        || $directory_stat[4] != 0 || ($directory_stat[2] & 0022) != 0;
    die "ORM broker socket path already exists\n" if lstat($socket_path);

    my $resolver = Orm::Broker::AccountResolver->new(account_root => $account_root);
    my $instance_manager = Orm::Broker::InstanceManager->new(
        resolver => $resolver,
        quota_lock_path => "$runtime_dir/reseller-quota.lock",
    );
    my $fleet_inventory = Orm::Broker::FleetInventory->new(
        resolver => $resolver,
        instance_manager => $instance_manager,
    );
    my $old_umask = umask(0111);
    my $server = IO::Socket::UNIX->new(
        Type => SOCK_STREAM,
        Local => $socket_path,
        Listen => $MAX_CLIENTS,
    );
    umask($old_umask);
    die "ORM broker could not create its socket\n" if !$server;
    chmod(0666, $socket_path) or die "ORM broker could not set socket permissions\n";
    chown(0, 0, $socket_path) or die "ORM broker could not set socket ownership\n";

    my @socket_stat = lstat($socket_path);
    die "ORM broker socket failed ownership validation\n"
        if !@socket_stat || !S_ISSOCK($socket_stat[2])
        || $socket_stat[4] != 0 || ($socket_stat[2] & 0777) != 0666;
    my ($socket_device, $socket_inode) = @socket_stat[0, 1];

    my $listener_flags = fcntl($server, F_GETFL, 0);
    die "ORM broker could not configure its listener\n" if !defined($listener_flags)
        || !fcntl($server, F_SETFL, $listener_flags | O_NONBLOCK);

    my $selector = IO::Select->new($server);
    my %clients;
    my %rates;
    my $last_rate_prune = clock_gettime(CLOCK_MONOTONIC);

    while (1) {
        my $now = clock_gettime(CLOCK_MONOTONIC);
        for my $fd (keys %clients) {
            if ($now - $clients{$fd}->{accepted_at} > $CLIENT_TIMEOUT_SECONDS) {
                _close_client($selector, \%clients, $fd);
            }
        }

        my @readable = $selector->can_read(0.1);
        for my $ready (@readable) {
            if (fileno($ready) == fileno($server)) {
                my $client = $server->accept();
                next if !$client;
                if (scalar(keys %clients) >= $MAX_CLIENTS) {
                    close($client);
                    next;
                }

                my $uid = Orm::Broker::PeerCredentials->uid_from_socket($client);
                if (!defined($uid)) {
                    close($client);
                    next;
                }
                my $flags = fcntl($client, F_GETFL, 0);
                if (!defined($flags) || !fcntl($client, F_SETFL, $flags | O_NONBLOCK)) {
                    close($client);
                    next;
                }

                my $fd = fileno($client);
                $clients{$fd} = {
                    socket => $client,
                    uid => $uid,
                    buffer => '',
                    accepted_at => $now,
                };
                $selector->add($client);
                next;
            }

            my $fd = fileno($ready);
            next if !exists($clients{$fd});
            my $chunk = '';
            my $read_bytes = sysread($ready, $chunk, max_frame_bytes() + 1);
            if (!defined($read_bytes)) {
                next if $! == EAGAIN || $! == EWOULDBLOCK || $! == EINTR;
                _close_client($selector, \%clients, $fd);
                next;
            }
            if ($read_bytes == 0) {
                my $frame = $clients{$fd}->{buffer};
                my $request = Orm::Broker::Protocol::parse_request($frame);
                if (!$request) {
                    _write_and_close($selector, \%clients, $fd, {
                        error => 'invalid_request', success => JSON::PP::false, version => 1,
                    });
                    next;
                }
                my $peer_uid = $clients{$fd}->{uid};
                my $limit = $request->{operation} eq 'identity'
                    ? $IDENTITY_RATE_LIMIT_PER_SECOND
                    : $request->{operation} eq 'fleet.list' || $request->{operation} eq 'fleet.diagnostics'
                        || $request->{operation} eq 'provider.resellers' ? 1
                    : ($request->{operation} eq 'instance.metrics' || $request->{operation} eq 'metrics.history') ? 4
                    : ($request->{operation} eq 'backup.create' || $request->{operation} eq 'backup.restore'
                        || $request->{operation} eq 'fleet.control'
                        || $request->{operation} eq 'fleet.backup.create'
                        || $request->{operation} eq 'fleet.backup.restore'
                        || $request->{operation} eq 'fleet.migrate') ? 1
                    : $MUTATION_RATE_LIMIT_PER_SECOND;
                my $rate_window = $request->{operation} eq 'fleet.diagnostics' ? 5
                    : ($request->{operation} eq 'backup.create' || $request->{operation} eq 'backup.restore'
                    || $request->{operation} eq 'fleet.backup.create' || $request->{operation} eq 'fleet.backup.restore'
                    || $request->{operation} eq 'fleet.migrate') ? 60 : 1;
                my $root_read = $request->{operation} =~ /\A(?:fleet\.list|fleet\.diagnostics|fleet\.control|fleet\.backup\.(?:create|restore)|fleet\.migrate|provider\.resellers)\z/ ? 1 : 0;
                my $rate_bucket = $request->{operation} eq 'fleet.control'
                    ? 'fleet.control'
                    : $request->{operation} eq 'fleet.list' ? 'fleet.list'
                    : $request->{operation} eq 'provider.resellers' ? 'provider.resellers'
                    : $request->{operation} eq 'provider.exposure' ? 'provider.exposure'
                    : $request->{operation} eq 'provider.branding' ? 'provider.branding'
                    : $request->{operation} eq 'fleet.diagnostics'
                        ? 'fleet.diagnostics:' . $request->{username}
                    : $request->{operation} =~ /\Afleet\.backup\./
                        ? 'fleet.backup:' . $request->{username}
                    : $request->{operation} eq 'fleet.migrate'
                        ? 'fleet.migrate:' . $request->{username}
                        : $rate_window;
                if (!_rate_allowed(\%rates, $peer_uid, $now, $limit, $root_read, $rate_window, $rate_bucket)) {
                    _write_and_close($selector, \%clients, $fd, {
                        error => 'rate_limited', success => JSON::PP::false, version => 1,
                    });
                    next;
                }
                my $response = Orm::Broker::Handler->handle_frame(
                    $frame, $peer_uid, $resolver, $instance_manager, $fleet_inventory
                );
                _write_and_close_encoded($selector, \%clients, $fd, $response);
                next;
            }

            $clients{$fd}->{buffer} .= $chunk;
            if (length($clients{$fd}->{buffer}) > max_frame_bytes()) {
                _write_and_close($selector, \%clients, $fd, {
                    error => 'invalid_request', success => JSON::PP::false, version => 1,
                });
                next;
            }
            if (index($clients{$fd}->{buffer}, "\n") >= 0) {
                my $newline = index($clients{$fd}->{buffer}, "\n");
                if ($newline != length($clients{$fd}->{buffer}) - 1) {
                    _write_and_close($selector, \%clients, $fd, {
                        error => 'invalid_request', success => JSON::PP::false, version => 1,
                    });
                    next;
                }
            }
        }

        if ($now - $last_rate_prune > 60) {
            for my $uid (keys %rates) {
                delete $rates{$uid} if $now - $rates{$uid}->{started_at} > 60;
            }
            $last_rate_prune = $now;
        }
    }
}

sub _rate_allowed {
    my ($rates, $uid, $now, $limit, $allow_root, $window_seconds, $bucket) = @_;
    $window_seconds = 1 if !defined($window_seconds) || $window_seconds < 1;
    return 0 if !defined($uid) || ($uid == 0 && !$allow_root);
    $bucket = $window_seconds if !defined($bucket);
    my $rate_key = $uid . ':' . $bucket;
    my $window = $rates->{$rate_key};
    if (!$window || $now - $window->{started_at} >= $window_seconds) {
        $rates->{$rate_key} = { started_at => $now, count => 1 };
        return 1;
    }
    return 0 if $window->{count} >= $limit;
    $window->{count}++;
    return 1;
}

sub _write_and_close {
    my ($selector, $clients, $fd, $response) = @_;
    _write_and_close_encoded($selector, $clients, $fd, encode_response($response));
}

sub _write_and_close_encoded {
    my ($selector, $clients, $fd, $response) = @_;
    if (defined($response) && exists($clients->{$fd})) {
        my $socket = $clients->{$fd}->{socket};
        my $written = syswrite($socket, $response);
        if (defined($written) && $written < length($response)) {
            my $offset = $written;
            while ($offset < length($response)) {
                my $remaining = substr($response, $offset);
                my $count = syswrite($socket, $remaining);
                last if !defined($count) || $count == 0;
                $offset += $count;
            }
        }
    }
    _close_client($selector, $clients, $fd);
}

sub _close_client {
    my ($selector, $clients, $fd) = @_;
    return if !exists($clients->{$fd});
    my $socket = delete($clients->{$fd})->{socket};
    $selector->remove($socket);
    close($socket);
}

1;
