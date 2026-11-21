package Orm::Broker::PodmanMetricsCollector;
use strict;
use warnings;
use Fcntl qw(O_CREAT O_EXCL O_RDONLY O_RDWR O_WRONLY O_NOFOLLOW :mode LOCK_EX LOCK_UN);
use IO::Select;
use IO::Socket::UNIX;
use JSON::PP ();
use Socket qw(SOL_SOCKET SO_PEERCRED SOCK_STREAM);
use File::Basename qw(dirname);
use File::Spec;
use Cwd qw(realpath);
use Errno qw(ENOENT);
use Digest::SHA qw(sha256_hex);

my $MAX_ACCOUNT_ENTRIES = 10_000;
my $MAX_CONTAINERS_PER_ACCOUNT = 32;
my $MAX_PROBES_PER_RUN = 256;
my $MAX_PODMAN_DIRECTORY_ENTRIES = 1024;
my $MAX_DISCOVERED_CONTAINERS = $MAX_ACCOUNT_ENTRIES * $MAX_PODMAN_DIRECTORY_ENTRIES;
my $MAX_SNAPSHOT_BYTES = 4096;
my $MAX_INFO_BYTES = 65_536;
my $MAX_COUNTER = 1_000_000_000_000_000;
my $MAX_SNAPSHOT_AGE_SECONDS = 1800;
my $MAX_BASELINE_AGE_SECONDS = 93600;
my $MAX_BASELINE_BYTES = 262144;
my %METRIC_FIELDS = map { $_ => 1 } qw(
    connected_clients evicted_keys keyspace_hits keyspace_misses memory_used_bytes total_commands_processed
);
my %COUNTER_FIELDS = map { $_ => 1 } qw(evicted_keys keyspace_hits keyspace_misses total_commands_processed);

sub new {
    my ($class, %args) = @_;
    return bless {
        account_root => $args{account_root} // '/var/cpanel/users',
        snapshot_path => $args{snapshot_path} // '/var/lib/orm-podman/summary.json',
        baseline_path => $args{baseline_path} // dirname($args{snapshot_path} // '/var/lib/orm-podman/summary.json') . '/counter-baseline.json',
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
    my @process_samples;
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
            if (defined($values->{run_id}) && $values->{run_id} =~ /\A[0-9a-fA-F]{40}\z/) {
                my %counters = map { $_ => 0 + $values->{$_} } keys %COUNTER_FIELDS;
                $counters{acl_access_denied_auth} = 0 + $values->{acl_access_denied_auth}
                    if defined($values->{acl_access_denied_auth});
                push @process_samples, { token => sha256_hex(lc($values->{run_id})), counters => \%counters };
            }
        }
    }

    my $counter_window = _counter_window($self->{baseline_path}, $sampled_at, \@process_samples,
        $scan_complete && $unmeasured == 0 && $skipped == 0 && $unverified == 0,
        $reachable, $self->{expected_owner_uid}, $self->{expected_owner_gid});
    my $snapshot = {
        backend_counts => \%backend,
        counter_window => $counter_window,
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
        version => 2,
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
        my $peer_uid = _peer_uid_from_credentials($credentials);
        die "peer identity mismatch\n" if !defined($peer_uid) || $peer_uid != $uid;
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
        my %seen_info;
        for my $line (split /\r?\n/, $body) {
            next if $line eq '' || $line =~ /\A[#;]/;
            my ($key, $value) = split /:/, $line, 2;
            next if !defined($value) || $key !~ /\A(?:run_id|used_memory|connected_clients|total_commands_processed|evicted_keys|keyspace_hits|keyspace_misses|acl_access_denied_auth)\z/;
            die "duplicate INFO field\n" if $seen_info{$key}++;
            if ($key eq 'run_id') {
                $info{$key} = $value if $value =~ /\A[0-9a-fA-F]{40}\z/;
                next;
            }
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
            run_id => $info{run_id},
        };
        $result->{acl_access_denied_auth} = $info{acl_access_denied_auth}
            if exists($info{acl_access_denied_auth});
        1;
    } or $result = undef;
    alarm(0);
    return $result;
}

sub _counter_window {
    my ($path, $sampled_at, $samples, $complete, $expected_processes, $uid, $gid) = @_;
    my $unknown = sub { return { status => 'unknown', reason => $_[0], sampled_at => 0 + $sampled_at,
        window_start_at => 0, window_seconds => 0, process_count => 0,
        max_evictions_delta => 0, max_operations_per_second => 0,
        auth_available => JSON::PP::false, max_auth_failures_delta => 0 } };
    return $unknown->('incomplete_scan') if !$complete || ref($samples) ne 'ARRAY' || @{$samples} > $MAX_PROBES_PER_RUN;
    return $unknown->('identity_missing') if @{$samples} != $expected_processes;
    my %current;
    for my $entry (@{$samples}) {
        return $unknown->('invalid_identity') if ref($entry) ne 'HASH'
            || !defined($entry->{token}) || $entry->{token} !~ /\A[0-9a-f]{64}\z/
            || ref($entry->{counters}) ne 'HASH';
        return $unknown->('duplicate_identity') if exists($current{$entry->{token}});
        $current{$entry->{token}} = $entry->{counters};
    }

    my $directory = dirname($path);
    my @dir_stat = lstat($directory);
    return $unknown->('state_unavailable') if !@dir_stat || !S_ISDIR($dir_stat[2])
        || $dir_stat[4] != $uid || $dir_stat[5] != $gid || ($dir_stat[2] & 07777) != 0700
        || !defined(realpath($directory)) || realpath($directory) ne $directory;
    my $lock_path = "$path.lock";
    sysopen(my $lock, $lock_path, O_CREAT | O_RDWR | O_NOFOLLOW, 0600) or return $unknown->('state_unavailable');
    my @lock_stat = stat($lock);
    if (!@lock_stat || !S_ISREG($lock_stat[2]) || $lock_stat[4] != $uid || $lock_stat[5] != $gid
        || $lock_stat[3] != 1 || ($lock_stat[2] & 07777) != 0600 || !flock($lock, LOCK_EX)) {
        close($lock);
        return $unknown->('state_unavailable');
    }

    my ($previous, $reason);
    my @baseline_stat = lstat($path);
    if (!@baseline_stat) {
        $reason = 'first_sample';
    } elsif (!S_ISREG($baseline_stat[2]) || $baseline_stat[4] != $uid || $baseline_stat[5] != $gid
        || $baseline_stat[3] != 1 || ($baseline_stat[2] & 0777) != 0600 || $baseline_stat[7] > $MAX_BASELINE_BYTES) {
        $reason = 'state_unavailable';
    } else {
        $previous = _read_baseline($path, $uid, $gid);
        $reason = defined($previous) ? 'candidate' : 'invalid_baseline';
    }

    my $window;
    if ($reason eq 'candidate') {
        if ($previous->{sampled_at} > $sampled_at || $previous->{sampled_at} == $sampled_at) {
            $reason = 'non_monotonic_time';
        } elsif ($previous->{sampled_at} < $sampled_at - $MAX_BASELINE_AGE_SECONDS) {
            $reason = 'stale_baseline';
        } else {
            my %old = map { $_->{token} => $_->{counters} } @{$previous->{entries}};
            my @old_tokens = sort keys %old;
            my @new_tokens = sort keys %current;
            if (join(',', @old_tokens) ne join(',', @new_tokens)) {
                $reason = 'process_set_changed';
            } elsif (!@new_tokens) {
                $reason = 'no_processes';
            } else {
                my $seconds = $sampled_at - $previous->{sampled_at};
                my ($max_evictions, $max_operations, $max_auth, $auth_available) = (0, 0, 0, 1);
                my $reset = 0;
                for my $token (@new_tokens) {
                    my $before = $old{$token};
                    my $after = $current{$token};
                    for my $metric (keys %COUNTER_FIELDS) {
                        if (!defined($before->{$metric}) || !defined($after->{$metric})
                            || $after->{$metric} < $before->{$metric}) { $reset = 1; last; }
                    }
                    last if $reset;
                    my $evictions = $after->{evicted_keys} - $before->{evicted_keys};
                    my $commands = $after->{total_commands_processed} - $before->{total_commands_processed};
                    $max_evictions = $evictions if $evictions > $max_evictions;
                    my $ops = int($commands / $seconds);
                    $max_operations = $ops if $ops > $max_operations;
                    if (!defined($before->{acl_access_denied_auth}) || !defined($after->{acl_access_denied_auth})) {
                        $auth_available = 0;
                    } else {
                        my $auth_delta = $after->{acl_access_denied_auth} - $before->{acl_access_denied_auth};
                        if ($auth_delta < 0) { $reset = 1; last; }
                        $max_auth = $auth_delta if $auth_delta > $max_auth;
                    }
                }
                $reason = 'counter_reset' if $reset;
                if (!$reset) {
                    $window = { status => 'measured', reason => 'matched_process_set', sampled_at => 0 + $sampled_at,
                        window_start_at => 0 + $previous->{sampled_at}, window_seconds => 0 + $seconds,
                        process_count => 0 + scalar(@new_tokens), max_evictions_delta => 0 + $max_evictions,
                        max_operations_per_second => 0 + $max_operations,
                        auth_available => $auth_available ? JSON::PP::true : JSON::PP::false,
                        max_auth_failures_delta => $auth_available ? 0 + $max_auth : 0 };
                    $reason = 'measured';
                }
            }
        }
    }

    if ($reason ne 'state_unavailable' && $reason ne 'non_monotonic_time') {
        my $baseline = { version => 1, sampled_at => 0 + $sampled_at,
            entries => [map { { token => $_, counters => $current{$_} } } sort keys %current] };
        _write_baseline($path, $baseline, $uid, $gid) or do { $window = undef; $reason = 'state_unavailable'; };
    }
    close($lock);
    return $window if defined($window);
    return $unknown->($reason);
}

sub _read_baseline {
    my ($path, $uid, $gid) = @_;
    my @before = lstat($path);
    return undef if !@before || !S_ISREG($before[2]) || $before[4] != $uid || $before[5] != $gid
        || $before[3] != 1 || ($before[2] & 07777) != 0600 || $before[7] > $MAX_BASELINE_BYTES;
    sysopen(my $handle, $path, O_RDONLY | O_NOFOLLOW) or return undef;
    my @after = stat($handle);
    if (!@after || !S_ISREG($after[2]) || $after[4] != $uid || $after[5] != $gid || $after[3] != 1
        || ($after[2] & 07777) != 0600 || $after[7] > $MAX_BASELINE_BYTES
        || $after[0] != $before[0] || $after[1] != $before[1]) { close($handle); return undef; }
    local $/;
    my $raw = <$handle>;
    my $closed = close($handle);
    return undef if !defined($raw) || !$closed || length($raw) > $MAX_BASELINE_BYTES || length($raw) != $after[7];
    my $baseline = eval { JSON::PP->new->decode($raw) };
    return undef if ref($baseline) ne 'HASH' || join(',', sort keys %{$baseline}) ne 'entries,sampled_at,version'
        || ($baseline->{version} // 0) != 1 || !defined($baseline->{sampled_at})
        || $baseline->{sampled_at} !~ /\A[0-9]{1,12}\z/ || ref($baseline->{entries}) ne 'ARRAY'
        || @{$baseline->{entries}} > $MAX_PROBES_PER_RUN;
    my %seen;
    for my $entry (@{$baseline->{entries}}) {
        return undef if ref($entry) ne 'HASH' || join(',', sort keys %{$entry}) ne 'counters,token'
            || !defined($entry->{token}) || $entry->{token} !~ /\A[0-9a-f]{64}\z/ || $seen{$entry->{token}}++
            || ref($entry->{counters}) ne 'HASH';
        my %allowed = (%COUNTER_FIELDS, acl_access_denied_auth => 1);
        return undef if grep { !$allowed{$_} } keys %{$entry->{counters}};
        return undef if grep { !defined($entry->{counters}->{$_}) || $entry->{counters}->{$_} !~ /\A[0-9]{1,16}\z/
            || $entry->{counters}->{$_} > $MAX_COUNTER } keys %{$entry->{counters}};
        return undef if grep { !exists($entry->{counters}->{$_}) } keys %COUNTER_FIELDS;
    }
    return $baseline;
}

sub _write_baseline {
    my ($path, $baseline, $uid, $gid) = @_;
    my $directory = dirname($path);
    my @dir = lstat($directory);
    return 0 if !@dir || !S_ISDIR($dir[2]) || $dir[4] != $uid || $dir[5] != $gid
        || ($dir[2] & 07777) != 0700 || !defined(realpath($directory)) || realpath($directory) ne $directory;
    my $json = JSON::PP->new->canonical(1)->encode($baseline);
    return 0 if length($json) > $MAX_BASELINE_BYTES;
    my $temporary = "$path.tmp.$$";
    return 0 if lstat($temporary);
    sysopen(my $handle, $temporary, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0600) or return 0;
    my $ok = chmod(0600, $temporary) && chown($uid, $gid, $temporary);
    my $offset = 0;
    while ($ok && $offset < length($json)) {
        my $written = syswrite($handle, $json, length($json) - $offset, $offset);
        if (!defined($written) || !$written) { $ok = 0; last; }
        $offset += $written;
    }
    $ok = 0 if !close($handle);
    if ($ok) {
        my @temp = lstat($temporary);
        $ok = @temp && S_ISREG($temp[2]) && $temp[4] == $uid && $temp[5] == $gid
            && $temp[3] == 1 && ($temp[2] & 07777) == 0600 && $temp[7] == length($json);
    }
    if ($ok && lstat($path)) {
        my @old = lstat($path);
        $ok = @old && S_ISREG($old[2]) && $old[4] == $uid && $old[5] == $gid
            && $old[3] == 1 && ($old[2] & 07777) == 0600;
    }
    $ok = 0 if $ok && !rename($temporary, $path);
    unlink($temporary) if !$ok && lstat($temporary);
    return $ok ? 1 : 0;
}

sub _peer_uid_from_credentials {
    my ($credentials) = @_;
    return undef if !defined($credentials) || length($credentials) < 12;
    my (undef, $peer_uid, undef) = unpack('iii', $credentials);
    return $peer_uid;
}

sub _valid_metrics {
    my ($metrics) = @_;
    return 0 if ref($metrics) ne 'HASH';
    my %allowed = (%METRIC_FIELDS, run_id => 1, acl_access_denied_auth => 1);
    return 0 if grep { !$allowed{$_} } keys %{$metrics};
    return 0 if grep { !exists($metrics->{$_}) } keys %METRIC_FIELDS;
    for my $field (keys %METRIC_FIELDS) {
        return 0 if !exists($metrics->{$field}) || !defined($metrics->{$field})
            || ref($metrics->{$field}) || $metrics->{$field} !~ /\A[0-9]+\z/
            || $metrics->{$field} > $MAX_COUNTER;
    }
    return 0 if exists($metrics->{run_id}) && (!defined($metrics->{run_id}) || $metrics->{run_id} !~ /\A[0-9a-fA-F]{40}\z/);
    return 0 if exists($metrics->{acl_access_denied_auth}) && (!defined($metrics->{acl_access_denied_auth})
        || ref($metrics->{acl_access_denied_auth}) || $metrics->{acl_access_denied_auth} !~ /\A[0-9]+\z/
        || $metrics->{acl_access_denied_auth} > $MAX_COUNTER);
    return 1;
}

sub _valid_snapshot {
    my ($snapshot) = @_;
    return 0 if ref($snapshot) ne 'HASH';
    my $version = $snapshot->{version} // 0;
    return 0 if $version != 1 && $version != 2;
    my @expected = sort qw(backend_counts discovered_count metrics partial reachable_count sampled_at sampled_backend_counts sampled_count scan_complete skipped_count success unmeasured_count unverified_account_count version);
    push @expected, 'counter_window' if $version == 2;
    @expected = sort @expected;
    my @actual = sort keys %{$snapshot};
    return 0 if join(',', @actual) ne join(',', @expected);
    return 0 if !JSON::PP::is_bool($snapshot->{success}) || !$snapshot->{success};
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
    return 0 if $version == 2 && !_valid_counter_window($snapshot->{counter_window}, $snapshot->{sampled_at});
    return 1;
}

sub _valid_counter_window {
    my ($window, $sampled_at) = @_;
    return 0 if ref($window) ne 'HASH'
        || join(',', sort keys %{$window}) ne 'auth_available,max_auth_failures_delta,max_evictions_delta,max_operations_per_second,process_count,reason,sampled_at,status,window_seconds,window_start_at'
        || !JSON::PP::is_bool($window->{auth_available})
        || !defined($window->{sampled_at}) || $window->{sampled_at} != $sampled_at
        || !defined($window->{status}) || $window->{status} !~ /\A(?:unknown|measured)\z/
        || !defined($window->{reason}) || $window->{reason} !~ /\A(?:first_sample|incomplete_scan|identity_missing|invalid_identity|duplicate_identity|state_unavailable|invalid_baseline|non_monotonic_time|stale_baseline|process_set_changed|counter_reset|no_processes|matched_process_set)\z/;
    for my $field (qw(window_start_at window_seconds process_count max_evictions_delta max_operations_per_second max_auth_failures_delta)) {
        return 0 if !defined($window->{$field}) || ref($window->{$field})
            || $window->{$field} !~ /\A[0-9]{1,18}\z/ || $window->{$field} > $MAX_COUNTER;
    }
    if ($window->{status} eq 'measured') {
        return 0 if $window->{reason} ne 'matched_process_set' || $window->{process_count} < 1
            || $window->{process_count} > $MAX_PROBES_PER_RUN || $window->{window_seconds} < 1
            || $window->{window_seconds} > $MAX_BASELINE_AGE_SECONDS
            || $window->{window_start_at} + $window->{window_seconds} != $sampled_at
            || ($window->{auth_available} ? 0 : $window->{max_auth_failures_delta} != 0);
    } else {
        return 0 if $window->{reason} eq 'matched_process_set' || $window->{window_start_at} != 0
            || $window->{window_seconds} != 0 || $window->{process_count} != 0
            || $window->{max_evictions_delta} != 0 || $window->{max_operations_per_second} != 0
            || $window->{auth_available} || $window->{max_auth_failures_delta} != 0;
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
