package Orm::Broker::PodmanMetricsCollector;
use strict;
use warnings;
use Fcntl qw(O_CREAT O_EXCL O_RDONLY O_WRONLY O_NOFOLLOW :mode);
use IO::Select;
use IO::Socket::UNIX;
use JSON::PP ();
use Socket qw(SOL_SOCKET SO_PEERCRED SOCK_STREAM);
use File::Basename qw(dirname);
use File::Spec;
use Cwd qw(realpath);
use Errno qw(ENOENT);

my $MAX_ACCOUNT_ENTRIES = 10_000;
my $MAX_CONTAINERS_PER_ACCOUNT = 32;
my $MAX_PROBES_PER_RUN = 256;
my $MAX_PODMAN_DIRECTORY_ENTRIES = 1024;
my $MAX_DISCOVERED_CONTAINERS = $MAX_ACCOUNT_ENTRIES * $MAX_PODMAN_DIRECTORY_ENTRIES;
my $MAX_SNAPSHOT_BYTES = 4096;
my $MAX_INFO_BYTES = 65_536;
my $MAX_COUNTER = 1_000_000_000_000_000;
my $MAX_SNAPSHOT_AGE_SECONDS = 1800;
my %METRIC_FIELDS = map { $_ => 1 } qw(
    connected_clients evicted_keys keyspace_hits keyspace_misses memory_used_bytes total_commands_processed
);

sub new {
    my ($class, %args) = @_;
    return bless {
        account_root => $args{account_root} // '/var/cpanel/users',
        snapshot_path => $args{snapshot_path} // '/var/lib/orm-podman/summary.json',
        resolver => $args{resolver},
        expected_owner_uid => defined($args{expected_owner_uid}) ? $args{expected_owner_uid} : 0,
        expected_owner_gid => defined($args{expected_owner_gid}) ? $args{expected_owner_gid} : 0,
        read_names => $args{read_names},
        lookup_home => $args{lookup_home},
        list_names => $args{list_names},
        probe => $args{probe},
        clock => $args{clock} // sub { time },
        max_accounts => $args{max_accounts} // $MAX_ACCOUNT_ENTRIES,
        max_containers_per_account => $args{max_containers_per_account} // $MAX_CONTAINERS_PER_ACCOUNT,
        max_probes => $args{max_probes} // $MAX_PROBES_PER_RUN,
    }, $class;
}

sub collect {
    my ($self) = @_;
    my $sampled_at = int($self->{clock}->());
    my %backend = (redis => 0, valkey => 0);
    my %sampled_backend = (redis => 0, valkey => 0);
    my %metrics = map { $_ => 0 } sort keys %METRIC_FIELDS;
    my ($discovered, $sampled, $reachable, $unmeasured, $skipped, $unverified) = (0, 0, 0, 0, 0, 0);
    my $scan_complete = 1;
    my $accounts = $self->_account_names();
    if (!defined($accounts)) {
        $scan_complete = 0;
        $accounts = [];
    }

    ACCOUNT: for my $username (@{$accounts}) {
        my $account = eval { $self->{resolver}->resolve_name($username) };
        if (ref($account) ne 'HASH' || ($account->{name} // '') ne $username
            || !defined($account->{uid}) || $account->{uid} !~ /\A[1-9][0-9]*\z/) {
            ++$unverified;
            $scan_complete = 0;
            next ACCOUNT;
        }
        my $home = eval { $self->{lookup_home}->($account) }
            if ref($self->{lookup_home}) eq 'CODE';
        if (!defined($home)) {
            my @entry = getpwuid($account->{uid});
            $home = $entry[7] if @entry;
        }
        if (!defined($home) || ref($home) || $home !~ m{\A/[^\0]*\z}) {
            ++$unverified;
            $scan_complete = 0;
            next ACCOUNT;
        }
        my $container_names = $self->_container_names($username, $home, $account->{uid});
        if (!defined($container_names)) {
            ++$unverified;
            $scan_complete = 0;
            next ACCOUNT;
        }
        if (@{$container_names} > $self->{max_containers_per_account}) {
            my $excess = @{$container_names} - $self->{max_containers_per_account};
            $discovered += $excess;
            $skipped += $excess;
            for my $extra (@{$container_names}[$self->{max_containers_per_account} .. $#{$container_names}]) {
                ++$backend{$extra =~ /\Aea-redis/ ? 'redis' : 'valkey'};
            }
            splice @{$container_names}, $self->{max_containers_per_account};
            $scan_complete = 0;
        }
        for my $container (@{$container_names}) {
            my $backend_name = $container =~ /\Aea-redis/ ? 'redis' : 'valkey';
            ++$discovered;
            ++$backend{$backend_name};
            if ($sampled >= $self->{max_probes}) {
                ++$skipped;
                $scan_complete = 0;
                next;
            }
            ++$sampled;
            ++$sampled_backend{$backend_name};
            my $socket = $self->_validated_socket($username, $home, $account->{uid}, $container, $backend_name);
            if (!defined($socket)) {
                ++$unmeasured;
                $scan_complete = 0;
                next;
            }
            my $values = ref($self->{probe}) eq 'CODE'
                ? eval { $self->{probe}->($socket, 0 + $account->{uid}) }
                : _probe_socket($socket, 0 + $account->{uid});
            if (!_valid_metrics($values)) {
                ++$unmeasured;
                $scan_complete = 0;
                next;
            }
            ++$reachable;
            $metrics{$_} += $values->{$_} for keys %METRIC_FIELDS;
        }
    }

    my $snapshot = {
        backend_counts => \%backend,
        discovered_count => 0 + $discovered,
        metrics => \%metrics,
        partial => ($scan_complete && $unmeasured == 0 && $skipped == 0) ? JSON::PP::false : JSON::PP::true,
        sampled_at => $sampled_at,
        sampled_backend_counts => \%sampled_backend,
        sampled_count => 0 + $sampled,
        scan_complete => $scan_complete ? JSON::PP::true : JSON::PP::false,
        unmeasured_count => 0 + $unmeasured,
        unverified_account_count => 0 + $unverified,
        reachable_count => 0 + $reachable,
        skipped_count => 0 + $skipped,
        success => JSON::PP::true,
        version => 1,
    };
    return $snapshot;
}

sub collect_and_write {
    my ($self) = @_;
    my $snapshot = $self->collect();
    return 0 if !_write_snapshot($self->{snapshot_path}, $snapshot, $self->{expected_owner_uid}, $self->{expected_owner_gid});
    return $snapshot;
}

sub read_snapshot {
    my ($class, $path, %args) = @_;
    $path //= '/var/lib/orm-podman/summary.json';
    my $expected_uid = defined($args{expected_owner_uid}) ? $args{expected_owner_uid} : 0;
    my $now = defined($args{now}) ? $args{now} : time;
    my $max_age = defined($args{max_age}) ? $args{max_age} : $MAX_SNAPSHOT_AGE_SECONDS;
    my $directory = dirname($path);
    return undef if !_trusted_directory($directory, $expected_uid)
        || ((lstat($directory))[2] & 0777) != 0700;
    my @path_stat = lstat($path);
    return undef if !@path_stat || !S_ISREG($path_stat[2]) || $path_stat[4] != $expected_uid
        || $path_stat[3] != 1 || ($path_stat[2] & 0777) != 0600 || $path_stat[7] > $MAX_SNAPSHOT_BYTES;
    sysopen(my $handle, $path, O_RDONLY | O_NOFOLLOW) or return undef;
    my @file_stat = stat($handle);
    if (!@file_stat || !S_ISREG($file_stat[2]) || $file_stat[4] != $expected_uid
        || $file_stat[3] != 1 || ($file_stat[2] & 0777) != 0600 || $file_stat[7] > $MAX_SNAPSHOT_BYTES
        || $file_stat[0] != $path_stat[0] || $file_stat[1] != $path_stat[1]) {
        close($handle);
        return undef;
    }
    local $/;
    my $raw = <$handle>;
    my $closed = close($handle);
    return undef if !defined($raw) || !$closed || length($raw) > $MAX_SNAPSHOT_BYTES;
    my $snapshot = eval { JSON::PP->new->decode($raw) };
    return undef if !_valid_snapshot($snapshot)
        || $snapshot->{sampled_at} > $now || $snapshot->{sampled_at} < $now - $max_age;
    return $snapshot;
}

sub _account_names {
    my ($self) = @_;
    my @root_stat = lstat($self->{account_root});
    return undef if !@root_stat || !S_ISDIR($root_stat[2]) || $root_stat[4] != $self->{expected_owner_uid}
        || ($root_stat[2] & 0022) != 0;
    my @names;
    if (ref($self->{read_names}) eq 'CODE') {
        @names = eval { $self->{read_names}->($self->{account_root}) };
        return undef if $@;
    } else {
        opendir(my $directory, $self->{account_root}) or return undef;
        while (my $name = readdir($directory)) {
            next if $name eq '.' || $name eq '..';
            push @names, $name;
            if (@names > $self->{max_accounts}) {
                closedir($directory);
                return undef;
            }
        }
        closedir($directory) or return undef;
    }
    return undef if @names > $self->{max_accounts};
    my %seen;
    return [sort grep { defined($_) && !ref($_) && /\A[a-zA-Z0-9_-]{1,16}\z/ && !$seen{$_}++ } @names];
}

sub _container_names {
    my ($self, $username, $home, $uid) = @_;
    my $root = "$home/ea-podman.d";
    return undef if !_trusted_directory($home, $uid);
    my @root_stat = lstat($root);
    return [] if !@root_stat && $! == ENOENT;
    return undef if !@root_stat || !_trusted_directory($root, $uid);
    opendir(my $directory, $root) or return undef;
    my @names;
    my $entries = 0;
    while (my $name = readdir($directory)) {
        next if $name eq '.' || $name eq '..';
        if (++$entries > $MAX_PODMAN_DIRECTORY_ENTRIES) {
            closedir($directory);
            return undef;
        }
        next if $name !~ /\Aea-(?:redis|valkey)[0-9]{2,4}\Q.$username.\E[0-9]{2,3}\z/;
        push @names, $name;
    }
    my $closed = closedir($directory);
    return undef if !$closed;
    return \@names;
}

sub _validated_socket {
    my ($self, $username, $home, $uid, $container, $backend) = @_;
    return undef if $container !~ /\Aea-(?:redis|valkey)[0-9]{2,4}\Q.$username.\E[0-9]{2,3}\z/;
    my $root = "$home/ea-podman.d";
    my $directory = "$root/$container";
    return undef if !_trusted_directory($home, $uid) || !_trusted_directory($root, $uid)
        || !_trusted_directory($directory, $uid);
    my $path = "$directory/" . ($backend eq 'redis' ? 'redis.sock' : 'valkey.sock');
    my @socket_stat = lstat($path);
    return undef if !@socket_stat || !S_ISSOCK($socket_stat[2]) || $socket_stat[4] != $uid
        || ($socket_stat[2] & 0007) != 0 || File::Spec->canonpath($path) ne $path;
    return { path => $path, device => $socket_stat[0], inode => $socket_stat[1], uid => $uid };
}

sub _trusted_directory {
    my ($path, $uid) = @_;
    my @stat = lstat($path);
    return 0 if !@stat || !S_ISDIR($stat[2]) || $stat[4] != $uid || ($stat[2] & 0022) != 0;
    my $real = realpath($path);
    return defined($real) && $real eq $path ? 1 : 0;
}

sub _probe_socket {
    my ($socket_info, $uid) = @_;
    return undef if ref($socket_info) ne 'HASH' || !defined($socket_info->{path});
    my @before = lstat($socket_info->{path});
    return undef if !@before || !S_ISSOCK($before[2]) || $before[4] != $uid
        || $before[0] != $socket_info->{device} || $before[1] != $socket_info->{inode};
    my $result;
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm(2);
        my $socket = IO::Socket::UNIX->new(Type => SOCK_STREAM, Peer => $socket_info->{path}, Timeout => 1)
            or die "connect failed\n";
        my $credentials = eval { $socket->getsockopt(SOL_SOCKET, SO_PEERCRED) };
        die "peer credentials unavailable\n" if !defined($credentials) || length($credentials) < 12;
        my (undef, undef, $peer_uid) = unpack('iii', $credentials);
        die "peer identity mismatch\n" if $peer_uid != $uid;
        my @after = lstat($socket_info->{path});
        die "socket changed\n" if !@after || $after[0] != $socket_info->{device}
            || $after[1] != $socket_info->{inode} || $after[4] != $uid || !S_ISSOCK($after[2]);
        binmode($socket);
        my $request = "*2\r\n\$4\r\nINFO\r\n\$3\r\nALL\r\n";
        my $written = syswrite($socket, $request);
        die "write failed\n" if !defined($written) || $written != length($request);
        my $select = IO::Select->new($socket);
        my $raw = '';
        while (1) {
            my @ready = $select->can_read(0.5);
            die "read timeout\n" if !@ready;
            my $chunk = '';
            my $read = sysread($socket, $chunk, 4096);
            die "read failed\n" if !defined($read) || !$read;
            $raw .= $chunk;
            die "response too large\n" if length($raw) > $MAX_INFO_BYTES;
            last if $raw =~ /\r\n\z/ && $raw =~ /^\$([0-9]+)\r\n/s && length($raw) >= $1 + length("\$$1\r\n") + 2;
        }
        close($socket);
        alarm(0);
        my ($size, $body) = $raw =~ /\A\$([0-9]{1,6})\r\n(.*)\r\n\z/s;
        die "invalid response\n" if !defined($size) || $size != length($body);
        my %info;
        for my $line (split /\r?\n/, $body) {
            next if $line eq '' || $line =~ /\A[#;]/;
            my ($key, $value) = split /:/, $line, 2;
            next if !defined($value) || $key !~ /\A(?:used_memory|connected_clients|total_commands_processed|evicted_keys|keyspace_hits|keyspace_misses)\z/;
            die "invalid counter\n" if $value !~ /\A[0-9]{1,16}\z/ || $value > $MAX_COUNTER;
            $info{$key} = 0 + $value;
        }
        die "incomplete counters\n" if grep { !exists($info{$_}) } qw(used_memory connected_clients total_commands_processed evicted_keys keyspace_hits keyspace_misses);
        $result = {
            connected_clients => $info{connected_clients},
            evicted_keys => $info{evicted_keys},
            keyspace_hits => $info{keyspace_hits},
            keyspace_misses => $info{keyspace_misses},
            memory_used_bytes => $info{used_memory},
            total_commands_processed => $info{total_commands_processed},
        };
        1;
    } or $result = undef;
    alarm(0);
    return $result;
}

sub _valid_metrics {
    my ($metrics) = @_;
    return 0 if ref($metrics) ne 'HASH' || (keys %{$metrics}) != scalar(keys %METRIC_FIELDS);
    for my $field (keys %METRIC_FIELDS) {
        return 0 if !exists($metrics->{$field}) || !defined($metrics->{$field})
            || ref($metrics->{$field}) || $metrics->{$field} !~ /\A[0-9]+\z/
            || $metrics->{$field} > $MAX_COUNTER;
    }
    return 1;
}

sub _valid_snapshot {
    my ($snapshot) = @_;
    return 0 if ref($snapshot) ne 'HASH';
    my @expected = sort qw(backend_counts discovered_count metrics partial reachable_count sampled_at sampled_backend_counts sampled_count scan_complete skipped_count success unmeasured_count unverified_account_count version);
    my @actual = sort keys %{$snapshot};
    return 0 if join(',', @actual) ne join(',', @expected);
    return 0 if ($snapshot->{version} // 0) != 1 || !JSON::PP::is_bool($snapshot->{success}) || !$snapshot->{success};
    return 0 if !defined($snapshot->{sampled_at}) || $snapshot->{sampled_at} !~ /\A[0-9]{1,12}\z/;
    for my $field (qw(discovered_count sampled_count reachable_count unmeasured_count skipped_count unverified_account_count)) {
        return 0 if !defined($snapshot->{$field}) || $snapshot->{$field} !~ /\A[0-9]{1,8}\z/ || $snapshot->{$field} > $MAX_DISCOVERED_CONTAINERS;
    }
    return 0 if $snapshot->{sampled_count} != $snapshot->{reachable_count} + $snapshot->{unmeasured_count};
    return 0 if $snapshot->{sampled_count} + $snapshot->{skipped_count} != $snapshot->{discovered_count};
    return 0 if !JSON::PP::is_bool($snapshot->{partial}) || !JSON::PP::is_bool($snapshot->{scan_complete});
    return 0 if $snapshot->{scan_complete}
        && ($snapshot->{unmeasured_count} > 0 || $snapshot->{skipped_count} > 0 || $snapshot->{unverified_account_count} > 0);
    for my $field (qw(backend_counts sampled_backend_counts)) {
        my $counts = $snapshot->{$field};
        return 0 if ref($counts) ne 'HASH' || join(',', sort keys %{$counts}) ne 'redis,valkey';
        for my $backend (qw(redis valkey)) {
            return 0 if !defined($counts->{$backend}) || $counts->{$backend} !~ /\A[0-9]{1,8}\z/
                || $counts->{$backend} > $MAX_DISCOVERED_CONTAINERS;
        }
    }
    return 0 if $snapshot->{backend_counts}->{redis} + $snapshot->{backend_counts}->{valkey} != $snapshot->{discovered_count}
        || $snapshot->{sampled_backend_counts}->{redis} + $snapshot->{sampled_backend_counts}->{valkey} != $snapshot->{sampled_count};
    my $expected_partial = !$snapshot->{scan_complete} || $snapshot->{unmeasured_count} > 0
        || $snapshot->{skipped_count} > 0 || $snapshot->{unverified_account_count} > 0;
    return 0 if ($snapshot->{partial} ? 1 : 0) != ($expected_partial ? 1 : 0);
    return 0 if ref($snapshot->{metrics}) ne 'HASH' || join(',', sort keys %{$snapshot->{metrics}}) ne join(',', sort keys %METRIC_FIELDS);
    for my $metric (keys %METRIC_FIELDS) {
        return 0 if !defined($snapshot->{metrics}->{$metric}) || $snapshot->{metrics}->{$metric} !~ /\A[0-9]{1,18}\z/
            || $snapshot->{metrics}->{$metric} > $MAX_COUNTER * $MAX_PROBES_PER_RUN;
    }
    return 1;
}

sub _write_snapshot {
    my ($path, $snapshot, $expected_uid, $expected_gid) = @_;
    return 0 if !_valid_snapshot($snapshot);
    my $directory = dirname($path);
    my @directory_stat = lstat($directory);
    return 0 if !@directory_stat || !S_ISDIR($directory_stat[2]) || $directory_stat[4] != $expected_uid
        || ($directory_stat[2] & 0777) != 0700;
    my $temporary = "$path.tmp.$$";
    return 0 if lstat($temporary);
    my $json = JSON::PP->new->canonical(1)->encode($snapshot);
    return 0 if length($json) > $MAX_SNAPSHOT_BYTES;
    sysopen(my $handle, $temporary, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0600) or return 0;
    my $ok = chmod(0600, $temporary) && chown($expected_uid, $expected_gid, $temporary);
    my $offset = 0;
    while ($ok && $offset < length($json)) {
        my $written = syswrite($handle, $json, length($json) - $offset, $offset);
        if (!defined($written) || !$written) { $ok = 0; last; }
        $offset += $written;
    }
    $ok = 0 if !close($handle);
    if ($ok) {
        my @temp_stat = lstat($temporary);
        $ok = @temp_stat && S_ISREG($temp_stat[2]) && $temp_stat[4] == $expected_uid
            && $temp_stat[3] == 1 && ($temp_stat[2] & 0777) == 0600;
    }
    if ($ok) {
        if (lstat($path)) {
            my @old = lstat($path);
            $ok = @old && S_ISREG($old[2]) && $old[4] == $expected_uid && $old[3] == 1 && ($old[2] & 0777) == 0600;
        }
    }
    if ($ok) { $ok = rename($temporary, $path) ? 1 : 0; }
    unlink($temporary) if !$ok && lstat($temporary);
    return $ok;
}

1;
