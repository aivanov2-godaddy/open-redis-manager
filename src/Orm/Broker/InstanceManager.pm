package Orm::Broker::InstanceManager;
use strict;
use warnings;
use Errno qw(ENOENT);
use Fcntl qw(O_RDONLY O_WRONLY O_RDWR O_CREAT O_EXCL O_NOFOLLOW :mode :flock);
use File::Spec;
use JSON::PP ();
use MIME::Base64 qw(encode_base64);
use POSIX qw(WNOHANG _exit setgid setuid);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);
use Orm::Broker::BackendPolicy;
use Orm::Broker::ProviderPolicy;
use Sys::Syslog qw(:standard :macros);

my %SERVER_BINARIES = (
    redis => [qw(/usr/bin/redis-server /usr/sbin/redis-server /usr/local/bin/redis-server /usr/local/sbin/redis-server)],
    valkey => [qw(/usr/bin/valkey-server /usr/sbin/valkey-server /usr/local/bin/valkey-server /usr/local/sbin/valkey-server)],
);
my %CLIENT_BINARIES = (
    redis => [qw(/usr/bin/redis-cli /usr/sbin/redis-cli /usr/local/bin/redis-cli /usr/local/sbin/redis-cli)],
    valkey => [qw(/usr/bin/valkey-cli /usr/sbin/valkey-cli /usr/local/bin/valkey-cli /usr/local/sbin/valkey-cli)],
);
my %RDB_CHECK_BINARIES = (
    redis => [qw(/usr/bin/redis-check-rdb /usr/sbin/redis-check-rdb /usr/local/bin/redis-check-rdb /usr/local/sbin/redis-check-rdb)],
    valkey => [qw(/usr/bin/valkey-check-rdb /usr/sbin/valkey-check-rdb /usr/local/bin/valkey-check-rdb /usr/local/sbin/valkey-check-rdb)],
);
my $MAX_MEMORY_BYTES = 64 * 1024 * 1024;
my $MAX_INFO_BYTES = 32768;
my $MAX_DIAGNOSTIC_INTEGER = 9_000_000_000_000_000;
my $MAX_COMMANDSTAT_ROWS = 60;
my $MAX_METRICS_AGE_SECONDS = 30 * 24 * 60 * 60;
my $FLEET_METRICS_FRESH_SECONDS = 15 * 60;
my $MAX_SECURITY_METRICS_AGE_SECONDS = 26 * 60 * 60;
my $MAX_SECURITY_METRICS_BYTES = 2048;
my $MAX_FLEET_SUMMARY_ACCOUNTS = 10_000;
my $MAX_FLEET_STATE_OUTPUT_BYTES = 262144;
my $MAX_METRICS_HISTORY_SAMPLES = 2160;
my $MAX_METRICS_HISTORY_BYTES = 1048576;
my $MAX_BACKUPS_PER_ACCOUNT = 3;
my $MAX_BACKUP_BYTES = 128 * 1024 * 1024;
my $BACKUP_TIMEOUT_SECONDS = 60;
my @METRIC_FIELDS = qw(
    commands_per_second connected_clients keyspace_hits keyspace_misses memory_peak_bytes memory_used_bytes uptime_seconds
);
my %METRIC_INFO_FIELDS = (
    memory_used_bytes => 'used_memory',
    memory_peak_bytes => 'used_memory_peak',
    connected_clients => 'connected_clients',
    uptime_seconds => 'uptime_in_seconds',
    commands_per_second => 'instantaneous_ops_per_sec',
    keyspace_hits => 'keyspace_hits',
    keyspace_misses => 'keyspace_misses',
);
my %PRESET_MEMORY_BYTES = (
    wordpress => 48 * 1024 * 1024,
    laravel => 32 * 1024 * 1024,
    magento => 64 * 1024 * 1024,
    session => 32 * 1024 * 1024,
    generic => 64 * 1024 * 1024,
);
my %MAXMEMORY_POLICIES = map { $_ => 1 } qw(
    allkeys-lru allkeys-lfu allkeys-random volatile-lru volatile-lfu volatile-random volatile-ttl noeviction
);

sub new {
    my ($class, %args) = @_;
    return bless {
        etc_root => $args{etc_root} // '/etc/orm-instances',
        data_root => $args{data_root} // '/var/lib/orm-instances',
        policy => $args{policy} // Orm::Broker::BackendPolicy->new(),
        provider_policy => $args{provider_policy} // Orm::Broker::ProviderPolicy->new(),
        resolver => $args{resolver},
        quota_lock_path => $args{quota_lock_path}
            // File::Spec->catfile($args{etc_root} // '/etc/orm-instances', '.orm-reseller-quota.lock'),
        expected_owner_uid => defined($args{expected_owner_uid}) ? $args{expected_owner_uid} : 0,
        expected_owner_gid => defined($args{expected_owner_gid}) ? $args{expected_owner_gid} : 0 + $<,
        systemctl => $args{systemctl} // '/usr/bin/systemctl',
        systemctl_call => $args{systemctl_call},
        systemctl_states_call => $args{systemctl_states_call},
        binary_paths => $args{binary_paths} // \%SERVER_BINARIES,
        binary_probe => $args{binary_probe},
        client_paths => $args{client_paths} // \%CLIENT_BINARIES,
        rdb_check_paths => $args{rdb_check_paths} // \%RDB_CHECK_BINARIES,
        rdb_check => $args{rdb_check},
        backend_version_probe => $args{backend_version_probe},
        restore_audit => $args{restore_audit},
        restore_state_timeout => defined($args{restore_state_timeout}) ? $args{restore_state_timeout} : 20,
        metrics_probe => $args{metrics_probe},
        redis_cli_call => $args{redis_cli_call},
        config_get => $args{config_get},
        config_set => $args{config_set},
        auth_probe => $args{auth_probe},
        auth_audit => $args{auth_audit},
        account_operation_audit => $args{account_operation_audit},
        backup_create => $args{backup_create},
        atomic_write_call => $args{atomic_write_call},
        atomic_commit => $args{atomic_commit},
    }, $class;
}

sub dispatch {
    my ($self, $operation, $account, $preset, $settings, $backup_id, $metrics_range) = @_;
    return _failure('not_authorized') if ref($account) ne 'HASH';
    return _failure('invalid_request') if !_valid_account($account);

    return $self->status($account) if $operation eq 'instance.status';
    return $self->auth_status($account) if $operation eq 'instance.auth.status';
    return $self->rotate_auth($account) if $operation eq 'instance.auth.rotate';
    return $self->disable_auth($account) if $operation eq 'instance.auth.disable';
    return $self->metrics($account) if $operation eq 'instance.metrics';
    return $self->metrics_history($account, $metrics_range) if $operation eq 'metrics.history';
    return $self->provider_exposure() if $operation eq 'provider.exposure';
    return $self->provider_branding() if $operation eq 'provider.branding';
    return $self->backups($account) if $operation eq 'backup.list';
    return $self->create_backup($account) if $operation eq 'backup.create';
    return $self->restore_backup($account, $backup_id) if $operation eq 'backup.restore';
    return $self->configure($account, $settings) if $operation eq 'instance.configure';
    return $self->provision($account, defined($preset) ? $preset : 'generic') if $operation eq 'instance.provision';
    return $self->start($account) if $operation eq 'instance.start';
    return $self->stop($account) if $operation eq 'instance.stop';
    return _failure('invalid_request');
}

sub provider_exposure {
    my ($self) = @_;
    my $exposure = $self->{provider_policy}->exposure_mode();
    return _failure('provider_policy_unavailable') if !defined($exposure);
    return { exposure => $exposure, success => JSON::PP::true, version => 1 };
}

sub provider_branding {
    my ($self) = @_;
    my $branding = $self->{provider_policy}->branding_settings();
    return _failure('provider_policy_unavailable') if ref($branding) ne 'HASH';
    return { branding => $branding, success => JSON::PP::true, version => 1 };
}

sub reseller_summary {
    my ($self) = @_;
    my $rules = $self->{provider_policy}->reseller_rules();
    my $usage = $self->reseller_usage(undef, 1);
    return _failure('provider_policy_unavailable') if ref($rules) ne 'HASH' || ref($usage) ne 'HASH';
    my %owners = map { $_ => 1 } (keys %{$rules}, keys %{$usage});
    return _failure('operation_failed') if scalar(keys %owners) > 1000;
    my @resellers;
    for my $owner (sort keys %owners) {
        return _failure('operation_failed') if $owner !~ /\A[a-zA-Z0-9_-]{1,16}\z/;
        my $rule = $rules->{$owner} // { max_instances => 0, max_memory_mib => 0 };
        my $row = $usage->{$owner} // { instances => 0, active_instances => 0, memory_mib => 0 };
        push @resellers, {
            owner => $owner,
            account_count => 0 + $row->{instances},
            active_instances => 0 + $row->{active_instances},
            memory_mib => 0 + $row->{memory_mib},
            max_instances => 0 + $rule->{max_instances},
            max_memory_mib => 0 + $rule->{max_memory_mib},
        };
    }
    return { resellers => \@resellers, success => JSON::PP::true, version => 1 };
}

sub reseller_usage {
    my ($self, $owner_filter, $include_active) = @_;
    return undef if defined($owner_filter) && (ref($owner_filter)
        || $owner_filter !~ /\A[a-zA-Z0-9_-]{1,16}\z/);
    my $resolver = $self->{resolver};
    return undef if ref($resolver) ne 'HASH' && !eval { $resolver->can('resolve_name') };
    return undef if !$self->_trusted_directory($self->{etc_root});
    opendir(my $root, $self->{etc_root}) or return undef;
    my @names = readdir($root);
    my $closed = closedir($root);
    return undef if !$closed || @names > 10002;

    my %usage;
    $usage{$owner_filter} = { instances => 0, active_instances => 0, memory_mib => 0 }
        if defined($owner_filter);
    for my $name (@names) {
        next if $name eq '.' || $name eq '..';
        if ($name eq '.orm-reseller-quota.lock' || $name eq 'reseller-quota.lock') {
            next;
        }
        return undef if $name !~ /\A[a-zA-Z0-9_-]{1,16}\z/;
        my $directory = File::Spec->catdir($self->{etc_root}, $name);
        my @directory_stat = lstat($directory);
        return undef if !@directory_stat || !S_ISDIR($directory_stat[2])
            || $directory_stat[4] != $self->{expected_owner_uid}
            || ($directory_stat[2] & 0027) != 0;
        my $account = eval { $resolver->resolve_name($name) };
        return undef if ref($account) ne 'HASH' || ($account->{name} // '') ne $name
            || !defined($account->{owner}) || ref($account->{owner})
            || $account->{owner} !~ /\A[a-zA-Z0-9_-]{1,16}\z/;
        next if defined($owner_filter) && $account->{owner} ne $owner_filter;
        my $manifest = $self->_read_manifest($account);
        return undef if ref($manifest) ne 'HASH' || ref($manifest->{settings}) ne 'HASH'
            || !_is_integer($manifest->{settings}->{memory_mib});
        my $row = $usage{$account->{owner}} //= { instances => 0, active_instances => 0, memory_mib => 0 };
        ++$row->{instances};
        $row->{memory_mib} += 0 + $manifest->{settings}->{memory_mib};
        if ($include_active) {
            my ($ok, $state) = $self->_systemctl('is-active', $self->_unit_name($name));
            return undef if !defined($state) || $state !~ /\A(?:active|inactive|failed|activating|deactivating|reloading)\z/;
            ++$row->{active_instances} if $ok && $state eq 'active';
        }
        return undef if scalar(keys %usage) > 1000;
    }
    return \%usage;
}

sub status {
    my ($self, $account) = @_;
    my $manifest = $self->_read_manifest($account);
    if (!-e $self->_manifest_path($account->{name}) && !-l $self->_manifest_path($account->{name})) {
        return _state('not_configured') if !-e $self->_account_config_dir($account->{name})
            && !-l $self->_account_config_dir($account->{name})
            && !-e $self->_account_data_dir($account->{name})
            && !-l $self->_account_data_dir($account->{name});
        return _failure('instance_unavailable');
    }
    return _failure('instance_unavailable') if !$manifest;
    my ($ok, $state) = $self->_systemctl('is-active', $self->_unit_name($account->{name}));
    return _failure('instance_unavailable') if !$ok
        && $state ne 'inactive' && $state ne 'failed'
        && $state ne 'activating' && $state ne 'reloading' && $state ne 'deactivating';
    return _state('running', $manifest) if $state eq 'active';
    return _state('starting', $manifest) if $state eq 'activating' || $state eq 'reloading';
    return _state('stopping', $manifest) if $state eq 'deactivating';
    return _state('failed', $manifest) if $state eq 'failed';
    return _state('stopped', $manifest) if $state eq 'inactive';
    return _failure('instance_unavailable');
}

sub fleet_summary {
    my ($self, $accounts) = @_;
    return undef if ref($accounts) ne 'ARRAY' || @{$accounts} > $MAX_FLEET_SUMMARY_ACCOUNTS;
    my %seen;
    my @managed;
    my %backendCounts = (redis => 0, valkey => 0);
    my $unconfigured = 0;
    my $unverified = 0;
    for my $account (@{$accounts}) {
        return undef if !_valid_account($account) || $seen{$account->{name}}++;
        my $manifest = $self->_read_manifest($account);
        if (ref($manifest) ne 'HASH') {
            my $manifest_path = $self->_manifest_path($account->{name});
            my $config_dir = $self->_account_config_dir($account->{name});
            my $data_dir = $self->_account_data_dir($account->{name});
            if (!-e $manifest_path && !-l $manifest_path && !-e $config_dir && !-l $config_dir
                && !-e $data_dir && !-l $data_dir) {
                ++$unconfigured;
            } else {
                ++$unverified;
            }
            next;
        }
        push @managed, { account => $account, manifest => $manifest };
        ++$backendCounts{$manifest->{backend}};
    }

    my @names = map { $_->{account}->{name} } @managed;
    my $rawStates = $self->_fleet_systemctl_states(\@names);
    my %states = (running => 0, stopped => 0, starting => 0, stopping => 0, failed => 0, unavailable => 0);
    my %metrics = (
        fresh_accounts => 0, stale_accounts => 0, missing_accounts => 0,
        memory_used_bytes => 0, connected_clients => 0,
        high_memory_accounts => 0, high_client_accounts => 0, low_hit_ratio_accounts => 0,
        alert_accounts => 0, latest_sampled_at => 0,
        rate_accounts => 0, rate_missing_accounts => 0, eviction_activity_accounts => 0,
        max_evictions_per_window => 0, max_operations_per_second => 0,
        rate_window_min_seconds => 0, rate_window_max_seconds => 0,
        rate_window_earliest_start_at => 0, rate_window_latest_end_at => 0,
        auth_rate_accounts => 0, auth_rate_missing_accounts => 0, auth_failure_accounts => 0,
        max_auth_failures_per_window => 0, auth_rate_window_min_seconds => 0,
        auth_rate_window_max_seconds => 0, auth_rate_window_earliest_start_at => 0,
        auth_rate_window_latest_end_at => 0,
    );
    my $stateUnavailable = 0;
    my $now = time;
    for my $item (@managed) {
        my $account = $item->{account};
        my $raw = ref($rawStates) eq 'HASH' ? $rawStates->{$account->{name}} : undef;
        my $state = defined($raw) ? _normalize_fleet_state($raw) : 'unavailable';
        ++$stateUnavailable if $state eq 'unavailable';
        ++$states{$state};

        my $securitySample = $self->_read_security_metrics_snapshot($account);
        if (ref($securitySample) eq 'HASH' && $securitySample->{available} == 1
            && defined($securitySample->{window_seconds})
            && $securitySample->{sampled_at} <= $now
            && $securitySample->{sampled_at} >= $now - $MAX_SECURITY_METRICS_AGE_SECONDS) {
            ++$metrics{rate_accounts};
            ++$metrics{eviction_activity_accounts} if $securitySample->{evicted_keys_delta} > 0;
            $metrics{max_evictions_per_window} = $securitySample->{evicted_keys_delta}
                if $securitySample->{evicted_keys_delta} > $metrics{max_evictions_per_window};
            my $operationsPerSecond = int($securitySample->{total_commands_processed_delta}
                / $securitySample->{window_seconds});
            $metrics{max_operations_per_second} = $operationsPerSecond
                if $operationsPerSecond > $metrics{max_operations_per_second};
            $metrics{rate_window_min_seconds} = $securitySample->{window_seconds}
                if !$metrics{rate_window_min_seconds}
                    || $securitySample->{window_seconds} < $metrics{rate_window_min_seconds};
            $metrics{rate_window_max_seconds} = $securitySample->{window_seconds}
                if $securitySample->{window_seconds} > $metrics{rate_window_max_seconds};
            $metrics{rate_window_earliest_start_at} = $securitySample->{window_start_at}
                if !$metrics{rate_window_earliest_start_at}
                    || $securitySample->{window_start_at} < $metrics{rate_window_earliest_start_at};
            $metrics{rate_window_latest_end_at} = $securitySample->{sampled_at}
                if $securitySample->{sampled_at} > $metrics{rate_window_latest_end_at};
        }
        if (ref($securitySample) eq 'HASH' && $securitySample->{auth_available} == 1
            && defined($securitySample->{auth_window_seconds})
            && $securitySample->{sampled_at} <= $now
            && $securitySample->{sampled_at} >= $now - $MAX_SECURITY_METRICS_AGE_SECONDS) {
            ++$metrics{auth_rate_accounts};
            ++$metrics{auth_failure_accounts} if $securitySample->{auth_failures_delta} > 0;
            $metrics{max_auth_failures_per_window} = $securitySample->{auth_failures_delta}
                if $securitySample->{auth_failures_delta} > $metrics{max_auth_failures_per_window};
            $metrics{auth_rate_window_min_seconds} = $securitySample->{auth_window_seconds}
                if !$metrics{auth_rate_window_min_seconds}
                    || $securitySample->{auth_window_seconds} < $metrics{auth_rate_window_min_seconds};
            $metrics{auth_rate_window_max_seconds} = $securitySample->{auth_window_seconds}
                if $securitySample->{auth_window_seconds} > $metrics{auth_rate_window_max_seconds};
            $metrics{auth_rate_window_earliest_start_at} = $securitySample->{auth_window_start_at}
                if !$metrics{auth_rate_window_earliest_start_at}
                    || $securitySample->{auth_window_start_at} < $metrics{auth_rate_window_earliest_start_at};
            $metrics{auth_rate_window_latest_end_at} = $securitySample->{sampled_at}
                if $securitySample->{sampled_at} > $metrics{auth_rate_window_latest_end_at};
        }

        my $sample = $self->_read_metrics_snapshot($account);
        if (ref($sample) ne 'HASH') {
            ++$metrics{missing_accounts};
            next;
        }
        if ($sample->{sampled_at} > $now || $sample->{sampled_at} < $now - $FLEET_METRICS_FRESH_SECONDS) {
            ++$metrics{stale_accounts};
            next;
        }
        ++$metrics{fresh_accounts};
        $metrics{memory_used_bytes} += $sample->{memory_used_bytes};
        $metrics{connected_clients} += $sample->{connected_clients};
        $metrics{latest_sampled_at} = $sample->{sampled_at}
            if $sample->{sampled_at} > $metrics{latest_sampled_at};
        my $settings = $item->{manifest}->{settings};
        my $highMemory = ref($settings) eq 'HASH' && $settings->{memory_mib} > 0
            && $sample->{memory_used_bytes} >= $settings->{memory_mib} * 1024 * 1024 * 0.85;
        my $highClients = ref($settings) eq 'HASH' && $settings->{maxclients} > 0
            && $sample->{connected_clients} >= $settings->{maxclients} * 0.85;
        my $lookups = $sample->{keyspace_hits} + $sample->{keyspace_misses};
        my $lowHitRatio = $lookups >= 100 && $sample->{keyspace_hits} / $lookups < 0.5;
        ++$metrics{high_memory_accounts} if $highMemory;
        ++$metrics{high_client_accounts} if $highClients;
        ++$metrics{low_hit_ratio_accounts} if $lowHitRatio;
        ++$metrics{alert_accounts} if $highMemory || $highClients || $lowHitRatio;

    }
    $metrics{rate_missing_accounts} = scalar(@managed) - $metrics{rate_accounts};
    $metrics{auth_rate_missing_accounts} = scalar(@managed) - $metrics{auth_rate_accounts};
    my $partial = $unverified > 0 || $stateUnavailable > 0
        || $metrics{stale_accounts} > 0 || $metrics{missing_accounts} > 0
        || $metrics{rate_missing_accounts} > 0 || $metrics{auth_rate_missing_accounts} > 0;
    return {
        account_count => scalar(@{$accounts}),
        managed_count => scalar(@managed),
        backend_counts => \%backendCounts,
        unconfigured_count => $unconfigured,
        unverified_count => $unverified,
        state_counts => \%states,
        metrics => \%metrics,
        partial => $partial ? JSON::PP::true : JSON::PP::false,
        success => JSON::PP::true,
        version => 1,
    };
}

sub fleet_usage {
    my ($self, $account) = @_;
    return _unknown_fleet_usage() if !_valid_account($account);

    # This endpoint reads only the root-owned metrics snapshot. In particular,
    # it must never call metrics(), which would probe Redis/Valkey per row.
    my $manifest = $self->_read_manifest($account);
    return _unknown_fleet_usage() if ref($manifest) ne 'HASH'
        || ref($manifest->{settings}) ne 'HASH'
        || !_is_integer($manifest->{settings}->{memory_mib})
        || $manifest->{settings}->{memory_mib} < 1
        || !_is_integer($manifest->{settings}->{maxclients})
        || $manifest->{settings}->{maxclients} < 1;

    my $usage = {
        connected_clients => undef,
        client_limit => 0 + $manifest->{settings}->{maxclients},
        memory_limit_bytes => 0 + $manifest->{settings}->{memory_mib} * 1024 * 1024,
        memory_used_bytes => undef,
        sampled_at => undef,
        state => 'unknown',
    };
    my $sample = $self->_read_metrics_snapshot($account);
    return $usage if ref($sample) ne 'HASH';

    my $now = time;
    # _read_metrics_snapshot permits a small clock skew for other consumers;
    # fleet rows stay unknown for future-dated samples.
    return $usage if $sample->{sampled_at} > $now;

    $usage->{connected_clients} = 0 + $sample->{connected_clients};
    $usage->{memory_used_bytes} = 0 + $sample->{memory_used_bytes};
    $usage->{sampled_at} = 0 + $sample->{sampled_at};
    $usage->{state} = $sample->{sampled_at} >= $now - $FLEET_METRICS_FRESH_SECONDS
        ? 'fresh' : 'stale';
    return $usage;
}

sub _unknown_fleet_usage {
    return {
        connected_clients => undef,
        client_limit => undef,
        memory_limit_bytes => undef,
        memory_used_bytes => undef,
        sampled_at => undef,
        state => 'unknown',
    };
}

sub _fleet_systemctl_states {
    my ($self, $names) = @_;
    return {} if ref($names) ne 'ARRAY' || @{$names} > $MAX_FLEET_SUMMARY_ACCOUNTS;
    return {} if !@{$names};
    if (ref($self->{systemctl_states_call}) eq 'CODE') {
        my $states = eval { $self->{systemctl_states_call}->([@{$names}]) };
        return undef if ref($states) ne 'HASH';
        my %expected = map { $_ => 1 } @{$names};
        for my $name (keys %{$states}) {
            return undef if !$expected{$name} || !defined($states->{$name}) || ref($states->{$name})
                || $states->{$name} !~ /\A(?:active|inactive|activating|reloading|deactivating|failed)\z/;
        }
        return $states;
    }
    return undef if $self->{systemctl} ne '/usr/bin/systemctl'
        || grep { !defined($_) || ref($_) || $_ !~ /\A[a-zA-Z0-9_-]{1,16}\z/ } @{$names};
    my @units = map { $self->_unit_name($_) } @{$names};
    my ($output, $completed) = ('', 0);
    my $opened = eval {
        local $SIG{ALRM} = sub { die "fleet state timeout\n" };
        alarm(5);
        if (open(my $pipe, '-|', $self->{systemctl}, '--no-pager', 'is-active', @units)) {
            my $valid = 1;
            while (1) {
                my $chunk = '';
                my $read = read($pipe, $chunk, 8192);
                if (!defined($read)) {
                    $valid = 0;
                    last;
                }
                last if $read == 0;
                $output .= $chunk;
                if (length($output) > $MAX_FLEET_STATE_OUTPUT_BYTES) {
                    $valid = 0;
                    last;
                }
            }
            $completed = $valid;
            close($pipe); # is-active returns non-zero when any requested unit is inactive.
        }
        alarm(0);
        1;
    };
    alarm(0);
    return undef if !$opened || !$completed;
    my @states = split(/\r?\n/, $output, -1);
    pop @states if @states && $states[-1] eq '';
    return undef if @states != @{$names};
    return undef if grep { $_ !~ /\A(?:active|inactive|activating|reloading|deactivating|failed)\z/ } @states;
    my %result;
    @result{@{$names}} = @states;
    return \%result;
}

sub _normalize_fleet_state {
    my ($raw) = @_;
    return 'running' if $raw eq 'active';
    return 'stopped' if $raw eq 'inactive';
    return 'starting' if $raw eq 'activating' || $raw eq 'reloading';
    return 'stopping' if $raw eq 'deactivating';
    return 'failed' if $raw eq 'failed';
    return 'unavailable';
}

sub auth_status {
    my ($self, $account) = @_;
    my $manifest = $self->_read_manifest($account);
    return _failure('not_configured') if !$manifest;
    my ($auth_valid, $auth_secret) = $self->_read_auth_secret($account, $manifest);
    return _failure('configuration_unavailable') if !$auth_valid;
    return {
        auth_configured => defined($auth_secret) ? JSON::PP::true : JSON::PP::false,
        success => JSON::PP::true,
        version => 1,
    };
}

sub rotate_auth {
    my ($self, $account, $actor_uid) = @_;
    $actor_uid = $account->{uid} if !defined($actor_uid);
    my $lock = $self->_acquire_instance_lock($account);
    my $response;
    if (!defined($lock)) {
        $response = _failure('operation_in_progress');
    } else {
        $response = $self->_rotate_auth_locked($account);
    }
    $self->_auth_audit($account, $response, 'auth.rotate', $actor_uid);
    close($lock) if defined($lock);
    return $response;
}

sub disable_auth {
    my ($self, $account) = @_;
    my $lock = $self->_acquire_instance_lock($account);
    my $response;
    if (!defined($lock)) {
        $response = _failure('operation_in_progress');
    } else {
        $response = $self->_disable_auth_locked($account);
    }
    $self->_auth_audit($account, $response, 'auth.disable');
    close($lock) if defined($lock);
    return $response;
}

sub _disable_auth_locked {
    my ($self, $account) = @_;
    my $manifest = $self->_read_manifest($account);
    return _failure('not_configured') if !$manifest;
    my ($active, $state) = $self->_systemctl('is-active', $self->_unit_name($account->{name}));
    return _failure('instance_unavailable') if !$active && $state ne 'inactive' && $state ne 'failed';
    return _failure('not_running') if !$active || $state ne 'active';

    my ($auth_valid, $previous_secret) = $self->_read_auth_secret($account, $manifest);
    return _failure('configuration_unavailable') if !$auth_valid;
    return { auth_configured => JSON::PP::false, success => JSON::PP::true, version => 1 }
        if !defined($previous_secret);
    my $old_config = _redis_config($manifest->{data}, $manifest->{socket}, $manifest->{settings}, $previous_secret, _manifest_database_count($manifest));
    my $new_config = _redis_config($manifest->{data}, $manifest->{socket}, $manifest->{settings}, undef, _manifest_database_count($manifest));
    return _failure('configuration_unavailable') if !defined($old_config) || !defined($new_config);

    my $temporary = $self->_stage_atomic_write(
        $manifest->{config}, $new_config, 0640, $self->{expected_owner_uid}, $account->{gid}
    );
    return _failure('configuration_storage_unavailable') if !defined($temporary);
    return _failure('configuration_storage_unavailable')
        if !$self->_commit_atomic_write($temporary, $manifest->{config});

    my $unit = $self->_unit_name($account->{name});
    my ($restarted) = $self->_systemctl('restart', '--no-block', $unit);
    my $new_ready = $restarted
        && $self->_wait_for_unit_state($unit, 'active', $self->{restore_state_timeout})
        && $self->_auth_probe($manifest->{backend}, $manifest->{socket});
    if (!$new_ready) {
        my $config_restored = $self->_atomic_write(
            $manifest->{config}, $old_config, 0640, $self->{expected_owner_uid}, $account->{gid}
        );
        return _failure('auth_recovery_required') if !$config_restored;
        my ($rollback_started) = $self->_systemctl('restart', '--no-block', $unit);
        my $rolled_back = $rollback_started
            && $self->_wait_for_unit_state($unit, 'active', $self->{restore_state_timeout})
            && $self->_auth_probe($manifest->{backend}, $manifest->{socket});
        return _failure($rolled_back ? 'auth_disable_failed' : 'auth_recovery_required');
    }

    return { auth_configured => JSON::PP::false, success => JSON::PP::true, version => 1 };
}

sub _auth_audit {
    my ($self, $account, $response, $action, $actor_uid) = @_;
    $actor_uid = $account->{uid} if !defined($actor_uid) || ref($actor_uid) || $actor_uid !~ /\A[0-9]{1,10}\z/;
    $action = $action eq 'auth.disable' ? 'auth.disable' : 'auth.rotate';
    my $outcome = ref($response) eq 'HASH' && $response->{success}
        ? 'success' : ref($response) eq 'HASH' ? ($response->{error} // 'failed') : 'failed';
    $outcome = 'failed' if $outcome !~ /\A[a-z_]{1,40}\z/;
    my $state = $outcome eq 'success' || $outcome eq 'auth_rotation_failed' || $outcome eq 'auth_disable_failed'
        ? 'running' : 'unavailable';
    if (ref($self->{auth_audit}) eq 'CODE') {
        eval { $self->{auth_audit}->($actor_uid, $account->{name}, $action, $outcome, $state) };
        return;
    }
    eval {
        openlog('orm-broker', 'pid', 'authpriv');
        syslog(LOG_NOTICE, 'account_auth actor_uid=%s account=%s action=%s result=%s state=%s',
            $actor_uid, $account->{name}, $action, $outcome, $state)
            or die "syslog write failed";
        closelog();
    };
    eval { closelog(); };
}

sub audit_account_operation {
    my ($self, $actor_uid, $account, $operation, $response) = @_;
    my %actions = map { $_ => 1 } qw(
        instance.provision instance.configure instance.start instance.stop
    );
    return 0 if ref($account) ne 'HASH' || !_valid_account($account)
        || !defined($actor_uid) || ref($actor_uid) || $actor_uid !~ /\A[0-9]{1,10}\z/
        || $actor_uid != $account->{uid} || !defined($operation) || !$actions{$operation};

    my $result = ref($response) eq 'HASH' && $response->{success} ? 'success' : 'failure';
    my $state = ref($response) eq 'HASH' && defined($response->{state}) && !ref($response->{state})
        && $response->{state} =~ /\A(?:running|stopped|starting|stopping|failed|unavailable|not_configured)\z/
        ? $response->{state} : undef;
    if (!defined($state)) {
        my $status = eval { $self->status($account) };
        $state = ref($status) eq 'HASH' && defined($status->{state}) && !ref($status->{state})
            && $status->{state} =~ /\A(?:running|stopped|starting|stopping|failed|unavailable|not_configured)\z/
            ? $status->{state} : 'unavailable';
    }
    if (ref($self->{account_operation_audit}) eq 'CODE') {
        my $logged = eval {
            $self->{account_operation_audit}->($actor_uid, $account->{name}, $operation, $result, $state)
        };
        return $logged ? 1 : 0;
    }
    my $logged = eval {
        openlog('orm-broker', 'pid', 'authpriv');
        syslog(LOG_NOTICE, 'account_operation actor_uid=%s account=%s action=%s result=%s state=%s',
            $actor_uid, $account->{name}, $operation, $result, $state)
            or die "syslog write failed";
        closelog();
        1;
    };
    eval { closelog(); };
    return $logged ? 1 : 0;
}

sub _rotate_auth_locked {
    my ($self, $account) = @_;
    my $manifest = $self->_read_manifest($account);
    return _failure('not_configured') if !$manifest;
    my ($active, $state) = $self->_systemctl('is-active', $self->_unit_name($account->{name}));
    return _failure('instance_unavailable') if !$active && $state ne 'inactive' && $state ne 'failed';
    return _failure('not_running') if !$active || $state ne 'active';

    my ($auth_valid, $previous_secret) = $self->_read_auth_secret($account, $manifest);
    return _failure('configuration_unavailable') if !$auth_valid;
    my $secret = _generate_auth_secret();
    return _failure('auth_generation_failed') if !defined($secret);
    my $old_config = _redis_config($manifest->{data}, $manifest->{socket}, $manifest->{settings}, $previous_secret, _manifest_database_count($manifest));
    my $new_config = _redis_config($manifest->{data}, $manifest->{socket}, $manifest->{settings}, $secret, _manifest_database_count($manifest));
    return _failure('configuration_unavailable') if !defined($old_config) || !defined($new_config);

    my $temporary = $self->_stage_atomic_write(
        $manifest->{config}, $new_config, 0640, $self->{expected_owner_uid}, $account->{gid}
    );
    return _failure('configuration_storage_unavailable') if !defined($temporary);
    return _failure('configuration_storage_unavailable')
        if !$self->_commit_atomic_write($temporary, $manifest->{config});

    my $unit = $self->_unit_name($account->{name});
    my ($restarted) = $self->_systemctl('restart', '--no-block', $unit);
    my $new_ready = $restarted
        && $self->_wait_for_unit_state($unit, 'active', $self->{restore_state_timeout})
        && $self->_auth_probe($manifest->{backend}, $manifest->{socket});
    if (!$new_ready) {
        my $config_restored = $self->_atomic_write(
            $manifest->{config}, $old_config, 0640, $self->{expected_owner_uid}, $account->{gid}
        );
        return _failure('auth_recovery_required') if !$config_restored;
        my ($rollback_started) = $self->_systemctl('restart', '--no-block', $unit);
        my $rolled_back = $rollback_started
            && $self->_wait_for_unit_state($unit, 'active', $self->{restore_state_timeout})
            && $self->_auth_probe($manifest->{backend}, $manifest->{socket});
        return _failure($rolled_back ? 'auth_rotation_failed' : 'auth_recovery_required');
    }

    return {
        auth_configured => JSON::PP::true,
        secret => $secret,
        success => JSON::PP::true,
        version => 1,
    };
}

sub _auth_probe {
    my ($self, $backend, $socket) = @_;
    if (ref($self->{auth_probe}) eq 'CODE') {
        return eval { $self->{auth_probe}->($backend, $socket) } ? 1 : 0;
    }
    my $pong = $self->_run_redis_cli($backend, $socket, 'PING');
    return defined($pong) && $pong eq "PONG\n" ? 1 : 0;
}

sub backend {
    my ($self, $account) = @_;
    return undef if !_valid_account($account);
    my $manifest = $self->_read_manifest($account);
    return undef if ref($manifest) ne 'HASH' || ($manifest->{backend} // '') !~ /\A(?:redis|valkey)\z/;
    return $manifest->{backend};
}

sub read_diagnostics {
    my ($self, $account) = @_;
    return _failure('invalid_request') if !_valid_account($account);
    my $status = $self->status($account);
    return $status if ref($status) ne 'HASH' || !$status->{success};
    return _failure('not_configured') if $status->{state} eq 'not_configured';
    return _failure('not_running') if $status->{state} ne 'running';

    my $manifest = $self->_read_manifest($account);
    return _failure('diagnostics_unavailable') if ref($manifest) ne 'HASH'
        || ($manifest->{backend} // '') !~ /\A(?:redis|valkey)\z/;

    my $backend = $manifest->{backend};
    my $socket = $manifest->{socket};
    my $version_field = $backend eq 'valkey' ? 'valkey_version' : 'redis_version';
    my $ping = $self->_run_redis_cli($backend, $socket, 'PING');
    return _failure('diagnostics_unavailable') if !defined($ping) || $ping ne "PONG\n";

    my $server = _parse_info_fields(
        $self->_run_redis_cli($backend, $socket, 'INFO', 'server'),
        { $version_field => 'version', uptime_in_seconds => 'integer' },
    );
    my $memory = _parse_info_fields(
        $self->_run_redis_cli($backend, $socket, 'INFO', 'memory'),
        { used_memory => 'integer', used_memory_peak => 'integer', maxmemory => 'integer' },
    );
    my $clients = _parse_info_fields(
        $self->_run_redis_cli($backend, $socket, 'INFO', 'clients'),
        { connected_clients => 'integer', blocked_clients => 'integer', maxclients => 'integer' },
    );
    my $stats = _parse_info_fields(
        $self->_run_redis_cli($backend, $socket, 'INFO', 'stats'),
        {
            instantaneous_ops_per_sec => 'integer', keyspace_hits => 'integer', keyspace_misses => 'integer',
            expired_keys => 'integer', evicted_keys => 'integer',
        },
    );
    my $database_size = $self->_run_redis_cli($backend, $socket, 'DBSIZE');
    return _failure('diagnostics_unavailable') if ref($server) ne 'HASH' || ref($memory) ne 'HASH'
        || ref($clients) ne 'HASH' || ref($stats) ne 'HASH'
        || !defined($database_size) || $database_size !~ /\A(?:0|[1-9][0-9]{0,15})\n\z/
        || substr($database_size, 0, -1) > $MAX_DIAGNOSTIC_INTEGER;
    my $keys = 0 + substr($database_size, 0, -1);
    my $diagnostics = {
        backend => $backend,
        blocked_clients => $clients->{blocked_clients},
        commands_per_second => $stats->{instantaneous_ops_per_sec},
        connected_clients => $clients->{connected_clients},
        database_keys => $keys,
        evicted_keys => $stats->{evicted_keys},
        expired_keys => $stats->{expired_keys},
        keyspace_hits => $stats->{keyspace_hits},
        keyspace_misses => $stats->{keyspace_misses},
        maxclients => $clients->{maxclients},
        maxmemory_bytes => $memory->{maxmemory},
        memory_peak_bytes => $memory->{used_memory_peak},
        memory_used_bytes => $memory->{used_memory},
        server_version => $server->{$version_field},
        uptime_seconds => $server->{uptime_in_seconds},
    };
    return _failure('diagnostics_unavailable')
        if $diagnostics->{memory_peak_bytes} < $diagnostics->{memory_used_bytes}
        || $diagnostics->{connected_clients} > $diagnostics->{maxclients}
        || $diagnostics->{maxclients} < 1 || $diagnostics->{maxclients} > 100000;
    return {
        diagnostics => $diagnostics,
        state => 'running',
        success => JSON::PP::true,
        version => 1,
    };
}

sub read_diagnostic_command {
    my ($self, $account, $command_class) = @_;
    return _failure('invalid_request') if !_valid_account($account)
        || !defined($command_class) || ref($command_class)
        || $command_class !~ /\A(?:ping|info_server|info_memory|info_clients|info_stats|info_commandstats|dbsize)\z/;
    my $status = $self->status($account);
    return $status if ref($status) ne 'HASH' || !$status->{success};
    return _failure('not_configured') if $status->{state} eq 'not_configured';
    return _failure('not_running') if $status->{state} ne 'running';

    my $manifest = $self->_read_manifest($account);
    return _failure('diagnostics_unavailable') if ref($manifest) ne 'HASH'
        || ($manifest->{backend} // '') !~ /\A(?:redis|valkey)\z/;
    my $backend = $manifest->{backend};
    my $socket = $manifest->{socket};
    my $version_field = $backend eq 'valkey' ? 'valkey_version' : 'redis_version';
    my ($result, @command);
    if ($command_class eq 'ping') {
        @command = ('PING');
        my $response = $self->_run_redis_cli($backend, $socket, @command);
        return _failure('diagnostics_unavailable') if !defined($response) || $response ne "PONG\n";
        $result = { response => 'PONG' };
    } elsif ($command_class eq 'dbsize') {
        @command = ('DBSIZE');
        my $response = $self->_run_redis_cli($backend, $socket, @command);
        return _failure('diagnostics_unavailable') if !defined($response)
            || $response !~ /\A(?:0|[1-9][0-9]{0,15})\n\z/
            || substr($response, 0, -1) > $MAX_DIAGNOSTIC_INTEGER;
        $result = { database_keys => 0 + substr($response, 0, -1) };
    } elsif ($command_class eq 'info_commandstats') {
        my $commandstats = _parse_commandstats($self->_run_redis_cli($backend, $socket, 'INFO', 'commandstats'));
        return _failure('diagnostics_unavailable') if ref($commandstats) ne 'HASH';
        $result = $commandstats;
    } else {
        my %sections = (
            info_server => ['server', { $version_field => 'version', uptime_in_seconds => 'integer' }],
            info_memory => ['memory', { used_memory => 'integer', used_memory_peak => 'integer', maxmemory => 'integer' }],
            info_clients => ['clients', { connected_clients => 'integer', blocked_clients => 'integer', maxclients => 'integer' }],
            info_stats => ['stats', {
                instantaneous_ops_per_sec => 'integer', keyspace_hits => 'integer', keyspace_misses => 'integer',
                expired_keys => 'integer', evicted_keys => 'integer',
            }],
        );
        my $section = $sections{$command_class};
        @command = ('INFO', $section->[0]);
        my $fields = _parse_info_fields($self->_run_redis_cli($backend, $socket, @command), $section->[1]);
        return _failure('diagnostics_unavailable') if ref($fields) ne 'HASH';
        if ($command_class eq 'info_server') {
            return _failure('diagnostics_unavailable') if !defined($fields->{$version_field});
            $result = { server_version => $fields->{$version_field}, uptime_seconds => $fields->{uptime_in_seconds} };
        } elsif ($command_class eq 'info_memory') {
            $result = {
                maxmemory_bytes => $fields->{maxmemory},
                memory_peak_bytes => $fields->{used_memory_peak},
                memory_used_bytes => $fields->{used_memory},
            };
        } elsif ($command_class eq 'info_clients') {
            $result = {
                blocked_clients => $fields->{blocked_clients},
                connected_clients => $fields->{connected_clients},
                maxclients => $fields->{maxclients},
            };
        } else {
            $result = {
                commands_per_second => $fields->{instantaneous_ops_per_sec},
                evicted_keys => $fields->{evicted_keys},
                expired_keys => $fields->{expired_keys},
                keyspace_hits => $fields->{keyspace_hits},
                keyspace_misses => $fields->{keyspace_misses},
            };
        }
    }

    return {
        command_class => $command_class,
        result => $result,
        state => 'running',
        success => JSON::PP::true,
        version => 1,
    };
}

sub recovery_health_check {
    my ($self, $account) = @_;
    return _failure('invalid_request') if !_valid_account($account);
    my $manifest = $self->_read_manifest($account);
    return _failure('instance_unavailable') if ref($manifest) ne 'HASH'
        || ($manifest->{backend} // '') !~ /\A(?:redis|valkey)\z/;
    my $response = _run_redis_cli($self, $manifest->{backend}, $manifest->{socket}, 'PING');
    return _failure('health_probe_failed') if !defined($response) || $response ne "PONG\n";
    return { success => JSON::PP::true, version => 1 };
}

sub provision {
    my ($self, $account, $preset) = @_;
    $preset = 'generic' if !defined($preset);
    return _failure('invalid_request') if ref($preset) || !exists($PRESET_MEMORY_BYTES{$preset});
    return _failure('storage_unavailable') if !$self->_trusted_directory($self->{etc_root})
        || !$self->_trusted_directory($self->{data_root});
    my $quota_lock = $self->_acquire_reseller_quota_lock();
    return _failure('provider_policy_unavailable') if !defined($quota_lock);
    my $response = eval { $self->_provision_locked($account, $preset) };
    my $closed = close($quota_lock);
    return _failure('provider_policy_unavailable') if !$closed;
    return ref($response) eq 'HASH' ? $response : _failure('operation_failed');
}

sub auto_provision {
    my ($self, $account) = @_;
    return _failure('invalid_request') if !_valid_account($account);
    my $enabled = eval { $self->{provider_policy}->auto_provision_enabled($account) };
    return _failure('provider_policy_unavailable') if !defined($enabled);
    if (!$enabled) {
        return {
            outcome => 'disabled',
            state => 'not_configured',
            success => JSON::PP::true,
            version => 1,
        };
    }

    my $current = eval { $self->status($account) };
    return _failure('instance_unavailable') if ref($current) ne 'HASH'
        || !$current->{success} || !defined($current->{state});
    if ($current->{state} ne 'not_configured') {
        return _failure('instance_unavailable')
            if $current->{state} !~ /\A(?:stopped|starting|running|stopping|failed)\z/;
        return {
            outcome => 'already_present',
            state => $current->{state},
            success => JSON::PP::true,
            version => 1,
        };
    }

    my $created = eval { $self->provision($account, 'generic') };
    return _failure('operation_failed') if ref($created) ne 'HASH';
    if (!$created->{success}) {
        return {
            error => defined($created->{error}) && !ref($created->{error})
                && $created->{error} =~ /\A(?:provider_policy_denied|provider_policy_unavailable|backend_policy_required|backend_unavailable|storage_unavailable|service_failed)\z/
                ? $created->{error} : 'operation_failed',
            outcome => 'failed',
            success => JSON::PP::false,
            version => 1,
        };
    }
    return {
        outcome => 'provisioned',
        state => defined($created->{state}) && $created->{state} =~ /\A(?:starting|running)\z/
            ? $created->{state} : 'unavailable',
        success => JSON::PP::true,
        version => 1,
    };
}

sub _provision_locked {
    my ($self, $account, $preset) = @_;
    return _failure('instance_exists') if -e $self->_manifest_path($account->{name})
        || -l $self->_manifest_path($account->{name})
        || -e $self->_account_config_dir($account->{name})
        || -l $self->_account_config_dir($account->{name})
        || -e $self->_account_data_dir($account->{name})
        || -l $self->_account_data_dir($account->{name});

    my $backend = $self->{policy}->selected_backend();
    return _failure('backend_policy_required') if !defined($backend);
    my $binary = $self->_available_binary($backend);
    return _failure('backend_unavailable') if !defined($binary);
    my $settings = _preset_settings($preset);
    my $provider_decision = $self->{provider_policy}->provision_decision(
        $account,
        $settings->{memory_mib},
        sub {
            my ($owner) = @_;
            my $usage = $self->reseller_usage($owner, 0);
            return undef if ref($usage) ne 'HASH' || ref($usage->{$owner}) ne 'HASH';
            return {
                instances => $usage->{$owner}->{instances},
                memory_mib => $usage->{$owner}->{memory_mib},
            };
        },
    );
    return _failure('provider_policy_unavailable') if ref($provider_decision) ne 'HASH';
    return _failure('provider_policy_denied') if !$provider_decision->{allowed};
    $settings->{memory_mib} = $provider_decision->{provision_memory_mib};
    $settings->{maxclients} = $provider_decision->{provision_max_clients};
    $settings->{maxmemory_policy} = $provider_decision->{instance_defaults}->{maxmemory_policy};
    my $memory_bytes = $settings->{memory_mib} * 1024 * 1024;
    return _failure('invalid_request') if $memory_bytes > $MAX_MEMORY_BYTES;
    my $provisioned_defaults = {
        backup_retention => 0 + $provider_decision->{backup_retention},
        databases => 0 + $provider_decision->{provision_databases},
        metrics_history_retention_days => 0 + $provider_decision->{instance_defaults}->{metrics_history_retention_days},
    };

    my $config_dir = $self->_account_config_dir($account->{name});
    my $data_dir = $self->_account_data_dir($account->{name});
    my $made_config_dir = mkdir($config_dir, 0750);
    return _failure('storage_unavailable') if !$made_config_dir;
    chmod(0750, $config_dir) or return $self->_rollback_provision($account, $config_dir, $data_dir, 0, 'storage_unavailable');
    chown($self->{expected_owner_uid}, $account->{gid}, $config_dir)
        or return $self->_rollback_provision($account, $config_dir, $data_dir, 0, 'storage_unavailable');

    my $made_data_dir = mkdir($data_dir, 0700);
    return $self->_rollback_provision($account, $config_dir, $data_dir, 0, 'storage_unavailable')
        if !$made_data_dir;
    chmod(0700, $data_dir) or return $self->_rollback_provision($account, $config_dir, $data_dir, 1, 'storage_unavailable');
    chown($account->{uid}, $account->{gid}, $data_dir)
        or return $self->_rollback_provision($account, $config_dir, $data_dir, 1, 'storage_unavailable');

    my $socket = File::Spec->catfile($data_dir, 'redis.sock');
    my $manifest = {
        backend => $backend,
        config => File::Spec->catfile($config_dir, 'redis.conf'),
        data => $data_dir,
        gid => 0 + $account->{gid},
        socket => $socket,
        preset => $preset,
        uid => 0 + $account->{uid},
        provisioned_defaults => $provisioned_defaults,
        version => 3,
    };
    my $manifest_json = JSON::PP->new->canonical(1)->encode($manifest) . "\n";
    my $config = _redis_config($data_dir, $socket, $settings, undef, $provisioned_defaults->{databases});
    if (!$self->_atomic_write(File::Spec->catfile($config_dir, 'redis.conf'), $config, 0640, $self->{expected_owner_uid}, $account->{gid})) {
        return $self->_rollback_provision($account, $config_dir, $data_dir, 1, 'storage_unavailable');
    }
    if (!$self->_atomic_write($self->_manifest_path($account->{name}), $manifest_json, 0640, $self->{expected_owner_uid}, $account->{gid})) {
        return $self->_rollback_provision($account, $config_dir, $data_dir, 1, 'storage_unavailable');
    }

    my $unit = $self->_unit_name($account->{name});
    my ($enabled) = $self->_systemctl('enable', $unit);
    if (!$enabled) {
        return $self->_rollback_provision($account, $config_dir, $data_dir, 1, 'service_failed');
    }
    my ($started) = $self->_systemctl('start', '--no-block', $unit);
    if (!$started) {
        $self->_systemctl('disable', $unit);
        return $self->_rollback_provision($account, $config_dir, $data_dir, 1, 'service_failed');
    }

    my $current = $self->status($account);
    if ($current->{success} && ($current->{state} eq 'running' || $current->{state} eq 'starting')) {
        $current->{policy_warnings} = $provider_decision->{violations}
            if $provider_decision->{mode} eq 'warn' && @{$provider_decision->{violations}};
        return $current;
    }
    $self->_systemctl('stop', '--no-block', $unit);
    $self->_systemctl('disable', $unit);
    return $self->_rollback_provision($account, $config_dir, $data_dir, 1, 'service_failed');
}

sub start {
    my ($self, $account) = @_;
    my $lock = $self->_acquire_instance_lock($account);
    return _failure('operation_in_progress') if !defined($lock);
    my $response = $self->_start_locked($account);
    close($lock);
    return $response;
}

sub recovery_start_if_stopped {
    my ($self, $account) = @_;
    return _failure('invalid_request') if !_valid_account($account);
    my $lock = $self->_acquire_instance_lock($account);
    return _failure('operation_in_progress') if !defined($lock);
    my $before = $self->status($account);
    my $response;
    if (ref($before) ne 'HASH' || !$before->{success}) {
        $response = _failure('instance_unavailable');
    } elsif ($before->{state} eq 'not_configured') {
        $response = _failure('not_configured');
    } elsif ($before->{state} ne 'stopped' && $before->{state} ne 'failed') {
        $response = _failure('repair_not_applicable');
    } else {
        $response = $self->_start_locked($account);
    }
    close($lock);
    return $response;
}

sub recovery_config_scan {
    my ($self, $account) = @_;
    return undef if !_valid_account($account);
    my $manifest = $self->_read_manifest($account, 1, 1);
    return undef if ref($manifest) ne 'HASH';
    my ($active, $state) = $self->_systemctl('is-active', $self->_unit_name($account->{name}));
    my $normalized_state = $active || $state eq 'active' ? 'running'
        : $state eq 'activating' ? 'starting'
        : $state eq 'deactivating' ? 'stopping'
        : $state eq 'failed' ? 'failed'
        : $state eq 'inactive' ? 'stopped' : undef;
    return undef if !defined($normalized_state);
    my $reset_kind = $manifest->{_recovery_config_reset_kind};
    return undef if !$reset_kind && $manifest->{_recovery_config_canonical};
    my $finding = defined($reset_kind) && $reset_kind eq 'missing' ? 'config_missing'
        : defined($reset_kind) && $reset_kind eq 'malformed' ? 'config_malformed' : 'config_drift';
    my $response = {
        finding => $finding,
        state => $normalized_state,
        success => JSON::PP::true,
        version => 1,
    };
    $response->{repair} = $reset_kind ? 'config_reset' : 'config_rebuild'
        if $normalized_state eq 'stopped' || $normalized_state eq 'failed';
    return $response;
}

sub recovery_ownership_scan {
    my ($self, $account) = @_;
    return undef if !_valid_account($account);
    my $tree = $self->_inspect_data_directory_ownership($account);
    return undef if ref($tree) ne 'HASH' || !$tree->{needs_repair};
    my $manifest = $self->_read_manifest($account, 1, 0, 1);
    return undef if ref($manifest) ne 'HASH';
    my (undef, $state) = $self->_systemctl('is-active', $self->_unit_name($account->{name}));
    return undef if !defined($state) || ref($state);
    my $normalized_state = $state eq 'active' ? 'running'
        : $state eq 'activating' ? 'starting'
        : $state eq 'deactivating' ? 'stopping'
        : $state eq 'failed' ? 'failed'
        : $state eq 'inactive' ? 'stopped' : undef;
    return undef if !defined($normalized_state);
    my $response = {
        finding => 'data_directory_ownership',
        state => $normalized_state,
        success => JSON::PP::true,
        version => 1,
    };
    $response->{repair} = 'ownership_fix'
        if $normalized_state eq 'stopped' || $normalized_state eq 'failed';
    return $response;
}

sub recovery_fix_ownership {
    my ($self, $account) = @_;
    return _failure('invalid_request') if !_valid_account($account);
    my $lock = $self->_acquire_instance_lock($account);
    return _failure('operation_in_progress') if !defined($lock);
    my $manifest = $self->_read_manifest($account, 1, 0, 1);
    my $response;
    my $tree = $self->_inspect_data_directory_ownership($account);
    if (ref($manifest) ne 'HASH' || ref($tree) ne 'HASH' || !$tree->{needs_repair}) {
        $response = _failure('repair_not_applicable');
    } else {
        my ($active, $state) = $self->_systemctl('is-active', $self->_unit_name($account->{name}));
        if ($active || !defined($state) || ref($state) || ($state ne 'inactive' && $state ne 'failed')) {
            $response = _failure('repair_not_applicable');
        } else {
            my $directory = $manifest->{data};
            my $verified = $self->_repair_data_directory_ownership($account, $tree)
                && ref($self->_read_manifest($account)) eq 'HASH';
            my (undef, $final_state) = $self->_systemctl('is-active', $self->_unit_name($account->{name}));
            if ($verified && defined($final_state) && !ref($final_state)
                && ($final_state eq 'inactive' || $final_state eq 'failed')) {
                $response = {
                    state => $final_state eq 'failed' ? 'failed' : 'stopped',
                    success => JSON::PP::true,
                    version => 1,
                };
            } else {
                $response = _failure('repair_not_applicable');
            }
        }
    }
    close($lock);
    return $response;
}

sub _inspect_data_directory_ownership {
    my ($self, $account) = @_;
    return undef if !_valid_account($account) || !$self->_trusted_directory($self->{data_root});
    my @root_stat = lstat($self->{data_root});
    my $directory = $self->_account_data_dir($account->{name});
    my @directory_stat = lstat($directory);
    return undef if !@root_stat || !@directory_stat || !S_ISDIR($directory_stat[2])
        || $root_stat[5] != $self->{expected_owner_gid}
        || $directory_stat[0] != $root_stat[0];
    my $root_gid = $root_stat[5];
    my @entries;
    my $needs_repair = 0;
    my $visit;
    $visit = sub {
        my ($path, $is_socket_allowed, $depth) = @_;
        $depth //= 0;
        return 0 if @entries >= 10_000 || $depth > 64;
        my @stat = lstat($path);
        return 0 if !@stat || $stat[0] != $root_stat[0]
            || ($stat[4] != $account->{uid} && $stat[4] != $self->{expected_owner_uid})
            || ($stat[5] != $account->{gid} && $stat[5] != $root_gid);
        my $type = S_ISDIR($stat[2]) ? 'directory'
            : S_ISREG($stat[2]) ? 'file'
            : S_ISSOCK($stat[2]) && $is_socket_allowed ? 'socket' : undef;
        return 0 if !defined($type) || ($type eq 'file' && $stat[3] != 1);
        my $expected_mode = $type eq 'directory' ? 0700 : 0600;
        $needs_repair = 1 if $stat[4] != $account->{uid} || $stat[5] != $account->{gid}
            || ($stat[2] & 07777) != $expected_mode;
        push @entries, { path => $path, device => $stat[0], inode => $stat[1], type => $type };
        if ($type eq 'directory') {
            opendir(my $handle, $path) or return 0;
            my @children;
            while (defined(my $child = readdir($handle))) {
                next if $child eq '.' || $child eq '..';
                if (@entries + @children >= 10_000) {
                    closedir($handle);
                    return 0;
                }
                push @children, $child;
            }
            @children = sort @children;
            my $read_ok = closedir($handle);
            return 0 if !$read_ok;
            for my $child (@children) {
                return 0 if $child eq '' || $child eq '..' || $child =~ m{/};
                my $child_path = File::Spec->catfile($path, $child);
                my $is_socket = $path eq $directory && $child eq 'redis.sock';
                return 0 if !$visit->($child_path, $is_socket, $depth + 1);
            }
        }
        return 1;
    };
    return undef if !$visit->($directory, 0, 0);
    return { entries => \@entries, needs_repair => $needs_repair ? 1 : 0, root_gid => $root_gid };
}

sub _repair_data_directory_ownership {
    my ($self, $account, $tree) = @_;
    return 0 if ref($tree) ne 'HASH' || ref($tree->{entries}) ne 'ARRAY' || !@{$tree->{entries}};
    my $directory = $self->_account_data_dir($account->{name});
    my $root = $tree->{entries}[0];
    return 0 if $root->{path} ne $directory || $root->{type} ne 'directory';
    my @current = lstat($directory);
    return 0 if !@current || $current[0] != $root->{device} || $current[1] != $root->{inode}
        || !chmod(0700, $directory)
        || !chown($self->{expected_owner_uid}, $tree->{root_gid}, $directory)
        || !chmod(0700, $directory);
    for my $entry (@{$tree->{entries}}[1 .. $#{$tree->{entries}}]) {
        my @before = lstat($entry->{path});
        return 0 if !@before || $before[0] != $entry->{device} || $before[1] != $entry->{inode}
            || ($entry->{type} eq 'directory' && !S_ISDIR($before[2]))
            || ($entry->{type} eq 'file' && (!S_ISREG($before[2]) || $before[3] != 1))
            || ($entry->{type} eq 'socket' && !S_ISSOCK($before[2]))
            || !chown($account->{uid}, $account->{gid}, $entry->{path})
            || !chmod($entry->{type} eq 'directory' ? 0700 : 0600, $entry->{path});
        my @after = lstat($entry->{path});
        return 0 if !@after || $after[0] != $entry->{device} || $after[1] != $entry->{inode}
            || $after[4] != $account->{uid} || $after[5] != $account->{gid}
            || ($after[2] & 07777) != ($entry->{type} eq 'directory' ? 0700 : 0600);
    }
    my @root_after = lstat($directory);
    return 0 if !@root_after || $root_after[0] != $root->{device} || $root_after[1] != $root->{inode}
        || !chown($account->{uid}, $account->{gid}, $directory)
        || !chmod(0700, $directory);
    my @verified = lstat($directory);
    return 0 if !@verified || $verified[0] != $root->{device} || $verified[1] != $root->{inode}
        || $verified[4] != $account->{uid} || $verified[5] != $account->{gid}
        || ($verified[2] & 07777) != 0700;
    my $final_tree = $self->_inspect_data_directory_ownership($account);
    return 0 if ref($final_tree) ne 'HASH' || $final_tree->{needs_repair}
        || @{$final_tree->{entries}} != @{$tree->{entries}};
    for my $index (0 .. $#{$tree->{entries}}) {
        my $before = $tree->{entries}[$index];
        my $after = $final_tree->{entries}[$index];
        return 0 if $before->{path} ne $after->{path} || $before->{device} != $after->{device}
            || $before->{inode} != $after->{inode} || $before->{type} ne $after->{type};
    }
    return 1;
}

sub recovery_reset_config {
    my ($self, $account) = @_;
    return _failure('invalid_request') if !_valid_account($account);
    my $lock = $self->_acquire_instance_lock($account);
    return _failure('operation_in_progress') if !defined($lock);
    my $manifest = $self->_read_manifest($account, 1, 1);
    my $response;
    if (ref($manifest) ne 'HASH' || !$manifest->{_recovery_config_reset_kind}) {
        $response = _failure('repair_not_applicable');
    } else {
        my ($active, $state) = $self->_systemctl('is-active', $self->_unit_name($account->{name}));
        if ($active || $state eq 'active' || $state eq 'activating' || $state eq 'deactivating') {
            $response = _failure('repair_not_applicable');
        } elsif ($state ne 'inactive' && $state ne 'failed') {
            $response = _failure('instance_unavailable');
        } else {
            my $secret = _generate_auth_secret();
            my $settings = {
                memory_mib => 8,
                maxmemory_policy => 'allkeys-lru',
                maxclients => 10,
                timeout => 0,
            };
            my $config = defined($secret)
                ? _redis_config($manifest->{data}, $manifest->{socket}, $settings,
                    $secret, _manifest_database_count($manifest))
                : undef;
            my $saved = defined($config) && $self->_atomic_write(
                $manifest->{config}, $config, 0640, $self->{expected_owner_uid}, $account->{gid}
            );
            my $verified = $saved ? $self->_read_manifest($account) : undef;
            my ($auth_valid, $verified_secret) = $verified
                ? $self->_read_auth_secret($account, $verified) : (0, undef);
            if ($verified && $verified->{settings}->{maxclients} == 10
                && $verified->{settings}->{memory_mib} == 8 && defined($secret)
                && $auth_valid && defined($verified_secret) && $verified_secret eq $secret) {
                my ($running, $final_state) = $self->_systemctl('is-active', $self->_unit_name($account->{name}));
                if (!$running && ($final_state eq 'inactive' || $final_state eq 'failed')) {
                    $response = {
                        auth_configured => JSON::PP::true,
                        secret => $secret,
                        state => $final_state eq 'failed' ? 'failed' : 'stopped',
                        success => JSON::PP::true,
                        version => 1,
                    };
                } else {
                    $response = _failure('instance_unavailable');
                }
            } else {
                $response = _failure(defined($secret) ? 'configuration_storage_unavailable' : 'auth_generation_failed');
            }
        }
    }
    close($lock);
    return $response;
}

sub recovery_rebuild_config {
    my ($self, $account) = @_;
    return _failure('invalid_request') if !_valid_account($account);
    my $lock = $self->_acquire_instance_lock($account);
    return _failure('operation_in_progress') if !defined($lock);
    my $manifest = $self->_read_manifest($account, 1);
    my $response;
    if (ref($manifest) ne 'HASH' || $manifest->{_recovery_config_canonical}) {
        $response = _failure('repair_not_applicable');
    } else {
        my ($active, $state) = $self->_systemctl('is-active', $self->_unit_name($account->{name}));
        if ($active || $state eq 'active' || $state eq 'activating' || $state eq 'deactivating') {
            $response = _failure('repair_not_applicable');
        } elsif ($state ne 'inactive' && $state ne 'failed') {
            $response = _failure('instance_unavailable');
        } else {
            my $secret = $manifest->{_recovery_auth_secret};
            my $config = _redis_config($manifest->{data}, $manifest->{socket}, $manifest->{settings},
                $secret, _manifest_database_count($manifest));
            my $saved = defined($config) && $self->_atomic_write(
                $manifest->{config}, $config, 0640, $self->{expected_owner_uid}, $account->{gid}
            );
            my $verified = $saved ? $self->_read_manifest($account) : undef;
            $response = ref($verified) eq 'HASH'
                ? { state => $state eq 'failed' ? 'failed' : 'stopped', success => JSON::PP::true, version => 1 }
                : _failure('configuration_storage_unavailable');
        }
    }
    close($lock);
    return $response;
}

sub _start_locked {
    my ($self, $account) = @_;
    my $manifest = $self->_read_manifest($account);
    return _failure('not_configured') if !$manifest;
    my ($ok) = $self->_systemctl('start', '--no-block', $self->_unit_name($account->{name}));
    return _failure('service_failed') if !$ok;
    my $current = $self->status($account);
    return $current if $current->{success} && ($current->{state} eq 'running' || $current->{state} eq 'starting');
    return _failure('service_failed');
}

sub stop {
    my ($self, $account) = @_;
    my $lock = $self->_acquire_instance_lock($account);
    return _failure('operation_in_progress') if !defined($lock);
    my $response = $self->_stop_locked($account);
    close($lock);
    return $response;
}

sub _stop_locked {
    my ($self, $account) = @_;
    my $manifest = $self->_read_manifest($account);
    return _failure('not_configured') if !$manifest;
    my ($ok) = $self->_systemctl('stop', '--no-block', $self->_unit_name($account->{name}));
    return _failure('service_failed') if !$ok;
    my $current = $self->status($account);
    return $current if $current->{success} && ($current->{state} eq 'stopped' || $current->{state} eq 'stopping');
    return _failure('service_failed');
}

sub restart {
    my ($self, $account) = @_;
    my $lock = $self->_acquire_instance_lock($account);
    return _failure('operation_in_progress') if !defined($lock);
    my $response = $self->_restart_locked($account);
    close($lock);
    return $response;
}

sub _restart_locked {
    my ($self, $account) = @_;
    my $manifest = $self->_read_manifest($account);
    return _failure('not_configured') if !$manifest;
    my $before = $self->status($account);
    return _failure('instance_unavailable') if !$before->{success}
        || ($before->{state} ne 'running' && $before->{state} ne 'starting');
    my ($ok) = $self->_systemctl('restart', '--no-block', $self->_unit_name($account->{name}));
    return _failure('service_failed') if !$ok;
    my $current = $self->status($account);
    return $current if $current->{success} && $current->{state} =~ /\A(?:running|starting|stopping)\z/;
    return _failure('service_failed');
}

sub migrate_to_valkey {
    my ($self, $account) = @_;
    my $lock = $self->_acquire_instance_lock($account);
    return _failure('operation_in_progress') if !defined($lock);
    my $transaction = {
        backup_lock => undef,
        backup_id => undef,
        backup_directory => undef,
        complete => 0,
        manifest => undef,
        manifest_changed => 0,
        pause_attempted => 0,
        paused => 0,
        service_stopped => 0,
        temporary_paths => [],
    };
    my $response;
    my $completed = eval {
        $response = $self->_migrate_to_valkey_locked($account, $transaction);
        1;
    };
    if (!$completed) {
        my $recovered = eval { $self->_recover_migration_transaction($account, $transaction) } ? 1 : 0;
        $response = _failure($recovered ? 'migration_failed' : 'migration_recovery_required');
        $response->{safety_backup_id} = $transaction->{backup_id}
            if defined($transaction->{backup_id})
            && $transaction->{backup_id} =~ /\Asnapshot-[0-9]{10}-[a-f0-9]{8}[.]rdb\z/;
    } elsif (ref($response) eq 'HASH' && !$response->{success}
        && ($transaction->{paused} || $transaction->{pause_attempted})) {
        my $recovered = eval { $self->_recover_migration_transaction($account, $transaction) } ? 1 : 0;
        if (!$recovered) {
            $response = _failure('migration_recovery_required');
            $response->{safety_backup_id} = $transaction->{backup_id}
                if defined($transaction->{backup_id})
                && $transaction->{backup_id} =~ /\Asnapshot-[0-9]{10}-[a-f0-9]{8}[.]rdb\z/;
        } elsif (($response->{error} // '') eq 'migration_recovery_required'
            || ($response->{error} // '') eq 'migration_rollback_failed') {
            $response = _failure('migration_failed');
            $response->{safety_backup_id} = $transaction->{backup_id}
                if defined($transaction->{backup_id})
                && $transaction->{backup_id} =~ /\Asnapshot-[0-9]{10}-[a-f0-9]{8}[.]rdb\z/;
        }
    }
    for my $path (@{$transaction->{temporary_paths}}) {
        unlink($path) if defined($path) && (-e $path || -l $path);
    }
    if (defined($transaction->{backup_lock})) {
        close($transaction->{backup_lock});
        $transaction->{backup_lock} = undef;
    }
    close($lock);
    return ref($response) eq 'HASH' ? $response : _failure('migration_failed');
}

sub _migrate_to_valkey_locked {
    my ($self, $account, $transaction) = @_;
    my $manifest = $self->_read_manifest($account);
    return _failure('not_configured') if !$manifest;
    $transaction->{manifest} = $manifest;
    return _failure('migration_unsupported') if $manifest->{backend} ne 'redis';
    return _failure('backend_unavailable') if !defined($self->_available_binary('valkey'));

    my ($active, $state) = $self->_systemctl('is-active', $self->_unit_name($account->{name}));
    return _failure('not_running') if !$active || $state ne 'active';

    my $source_info = $self->_run_redis_cli('redis', $manifest->{socket}, 'INFO', 'server');
    my ($source_version) = defined($source_info)
        ? $source_info =~ /^redis_version:([0-9]+\.[0-9]+\.[0-9]+)\r?$/m : ();
    my $target_version = $self->_backend_server_version('valkey');
    return _failure('migration_unsupported') if !defined($source_version)
        || !_version_in_range($source_version, '6.2.0', '7.2.999')
        || !defined($target_version) || !_version_at_least($target_version, '7.2.0');

    my $keyspace = $self->_migration_keyspace('redis', $manifest->{socket});
    return _failure('migration_state_unavailable') if ref($keyspace) ne 'HASH';
    $transaction->{expected_keyspace} = $keyspace;
    my ($backup_directory, $backup_state) = $self->_backup_directory($account, 1);
    return _failure('backup_storage_unavailable') if !$backup_directory || $backup_state ne 'ready';
    my ($backup_lock, $lock_error) = $self->_acquire_backup_lock($backup_directory);
    return _failure($lock_error) if !defined($backup_lock);
    $transaction->{backup_lock} = $backup_lock;
    $transaction->{backup_directory} = $backup_directory;

    my @temporary_paths;
    $transaction->{temporary_paths} = \@temporary_paths;
    my $finish = sub {
        my ($response) = @_;
        unlink($_) for grep { defined($_) && (-e $_ || -l $_) } @temporary_paths;
        @temporary_paths = ();
        if (defined($transaction->{backup_lock})) {
            close($transaction->{backup_lock});
            $transaction->{backup_lock} = undef;
        }
        return $response;
    };
    my $unpause = sub {
        return 1 if !$transaction->{paused} && !$transaction->{pause_attempted};
        my $ok = $self->_redis_cli_command('redis', $manifest->{socket}, 'CLIENT', 'UNPAUSE');
        if ($ok) {
            $transaction->{paused} = 0;
            $transaction->{pause_attempted} = 0;
        }
        return $ok;
    };
    my $rollback = sub {
        my $recovered = $self->_rollback_migration(
            $account, $manifest, $backup_directory, $transaction->{backup_id}, $keyspace
        );
        if ($recovered) {
            $transaction->{paused} = 0;
            $transaction->{pause_attempted} = 0;
            $transaction->{service_stopped} = 0;
            $transaction->{manifest_changed} = 0;
        }
        return _migration_failure($recovered, $transaction->{backup_id});
    };

    my $unit = $self->_unit_name($account->{name});
    $transaction->{pause_attempted} = 1;
    my $paused = $self->_redis_cli_command('redis', $manifest->{socket}, 'CLIENT', 'PAUSE', '180000', 'WRITE');
    if (!$paused) {
        my $unpaused = $unpause->();
        return $finish->(_failure($unpaused ? 'migration_pause_failed' : 'migration_recovery_required'));
    }
    $transaction->{paused} = 1;
    my $pause_started = clock_gettime(CLOCK_MONOTONIC);

    my $snapshot = $self->_create_backup_locked($account, $manifest, $backup_directory, undef);
    if (ref($snapshot) ne 'HASH' || !$snapshot->{success} || ref($snapshot->{backup}) ne 'HASH') {
        my $unpaused = $unpause->();
        return $finish->(_failure($unpaused ? 'migration_snapshot_failed' : 'migration_recovery_required'));
    }
    my $backup_id = $snapshot->{backup}->{id};
    $transaction->{backup_id} = $backup_id;

    my $paused_keyspace = $self->_migration_keyspace('redis', $manifest->{socket});
    if (ref($paused_keyspace) ne 'HASH' || !_same_keyspace($keyspace, $paused_keyspace)) {
        my $unpaused = $unpause->();
        my $error = $unpaused ? 'migration_state_unavailable' : 'migration_recovery_required';
        return $finish->(_failure($error));
    }

    my $stage = $self->_new_backup_stage_path($backup_directory, 'restore');
    if (!defined($stage)) {
        my $unpaused = $unpause->();
        return $finish->(_failure($unpaused ? 'backup_storage_unavailable' : 'migration_recovery_required'));
    }
    push @temporary_paths, $stage;
    my $copied = $self->_stage_backup_copy($backup_directory, $backup_id, $stage, $account);
    my $target_check = $copied ? $self->_run_rdb_check('valkey', $stage, $account) : 0;
    if (!$copied || !defined($target_check) || !$target_check) {
        my $unpaused = $unpause->();
        my $error = !$unpaused ? 'migration_recovery_required'
            : !$copied ? 'backup_storage_unavailable'
            : !defined($target_check) ? 'migration_validation_unavailable' : 'migration_validation_failed';
        return $finish->(_failure($error));
    }

    my $pause_age = clock_gettime(CLOCK_MONOTONIC) - $pause_started;
    if ($pause_age >= 150) {
        my $unpaused = $unpause->();
        return $finish->(_failure($unpaused ? 'migration_timeout' : 'migration_recovery_required'));
    }

    my ($stopped) = $self->_systemctl('stop', '--no-block', $unit);
    if (!$stopped || !$self->_wait_for_unit_state($unit, 'inactive', $self->{restore_state_timeout})) {
        my $recovered = $self->_ensure_unit_running($unit);
        my $unpaused = $recovered && $unpause->();
        my $error = !$recovered || !$unpaused ? 'migration_recovery_required' : 'migration_failed';
        return $finish->(_failure($error));
    }
    $transaction->{service_stopped} = 1;

    my $dump_path = File::Spec->catfile($manifest->{data}, 'dump.rdb');
    if (!$self->_restore_target_safe($dump_path, $account, 1)) {
        return $finish->($rollback->());
    }
    my $installed = $self->_install_restore_stage($stage, $dump_path, $account, 1);
    if ($installed != 1) {
        return $finish->($rollback->());
    }

    my %target_manifest = %{$manifest};
    delete $target_manifest{settings};
    $target_manifest{backend} = 'valkey';
    $target_manifest{version} = $manifest->{version} >= 3 ? 3 : 2;
    my %original_manifest = %{$manifest};
    delete $original_manifest{settings};
    delete $original_manifest{preset} if $original_manifest{version} == 1;
    my $original_manifest_json = JSON::PP->new->canonical(1)->encode(\%original_manifest) . "\n";
    my $target_manifest_json = JSON::PP->new->canonical(1)->encode(\%target_manifest) . "\n";
    my $manifest_path = $self->_manifest_path($account->{name});
    if (!$self->_atomic_write($manifest_path, $target_manifest_json, 0640,
        $self->{expected_owner_uid}, $account->{gid})) {
        return $finish->($rollback->());
    }
    $transaction->{manifest_changed} = 1;

    my ($started) = $self->_systemctl('start', '--no-block', $unit);
    my $target_started = $started && $self->_wait_for_unit_state($unit, 'active', $self->{restore_state_timeout});
    my $target_ping = $target_started && $self->_redis_cli_command('valkey', $manifest->{socket}, 'PING');
    my $target_keyspace = $target_ping ? $self->_migration_keyspace('valkey', $manifest->{socket}) : undef;
    if (!$target_started || !$target_ping || ref($target_keyspace) ne 'HASH'
        || !_same_keyspace($keyspace, $target_keyspace)) {
        return $finish->($rollback->());
    }

    $transaction->{complete} = 1;
    $transaction->{paused} = 0;
    $transaction->{pause_attempted} = 0;
    $transaction->{service_stopped} = 0;
    $transaction->{manifest_changed} = 0;
    return $finish->({
        backup_id => $backup_id,
        source_backend => 'redis',
        state => 'running',
        success => JSON::PP::true,
        target_backend => 'valkey',
        version => 1,
    });
}

sub _recover_migration_transaction {
    my ($self, $account, $transaction) = @_;
    for my $path (@{$transaction->{temporary_paths} // []}) {
        unlink($path) if defined($path) && (-e $path || -l $path);
    }
    $transaction->{temporary_paths} = [];

    my $manifest = ref($transaction->{manifest}) eq 'HASH' ? $transaction->{manifest} : undef;
    if ($transaction->{complete}) {
        return 1;
    }
    my $current_manifest = $self->_read_manifest($account);
    my $backend = ref($current_manifest) eq 'HASH' ? $current_manifest->{backend} : undef;
    my $unit = $self->_unit_name($account->{name});
    my ($state_ok, $state) = $self->_systemctl('is-active', $unit);
    return 0 if !defined($state) || (!$state_ok && $state ne 'inactive' && $state ne 'failed');

    my $needs_rollback = $transaction->{service_stopped} || $transaction->{manifest_changed}
        || ($backend // '') eq 'valkey' || $state eq 'inactive' || $state eq 'failed';
    if ($needs_rollback) {
        return 0 if !$manifest || !defined($transaction->{backup_id})
            || !defined($transaction->{backup_directory});
        my $recovered = $self->_rollback_migration(
            $account, $manifest, $transaction->{backup_directory}, $transaction->{backup_id},
            $transaction->{expected_keyspace}
        );
        if ($recovered) {
            $transaction->{paused} = 0;
            $transaction->{pause_attempted} = 0;
            $transaction->{service_stopped} = 0;
            $transaction->{manifest_changed} = 0;
            return 1;
        }
        return 0;
    }

    return 1 if !$transaction->{paused} && !$transaction->{pause_attempted};
    return 0 if ($backend // '') ne 'redis' || $state ne 'active' || !$manifest;
    my $unpaused = $self->_redis_cli_command('redis', $manifest->{socket}, 'CLIENT', 'UNPAUSE');
    if ($unpaused) {
        $transaction->{paused} = 0;
        $transaction->{pause_attempted} = 0;
    }
    return $unpaused ? 1 : 0;
}

sub _rollback_migration {
    my ($self, $account, $manifest, $backup_directory, $backup_id, $expected_keyspace) = @_;
    my $unit = $self->_unit_name($account->{name});
    my ($state_ok, $state) = $self->_systemctl('is-active', $unit);
    if ($state_ok && $state eq 'active') {
        my ($stopped) = $self->_systemctl('stop', '--no-block', $unit);
        return 0 if !$stopped || !$self->_wait_for_unit_state($unit, 'inactive', $self->{restore_state_timeout});
    } elsif (!defined($state) || ($state ne 'inactive' && $state ne 'failed')) {
        return 0;
    }

    my $stage = $self->_new_backup_stage_path($backup_directory, 'rollback');
    return 0 if !defined($stage);
    my $staged = $self->_stage_backup_copy($backup_directory, $backup_id, $stage, $account);
    my $valid = $staged ? $self->_run_rdb_check('redis', $stage, $account) : 0;
    if (!$staged || !defined($valid) || !$valid) {
        unlink($stage) if -e $stage || -l $stage;
        return 0;
    }
    my $dump_path = File::Spec->catfile($manifest->{data}, 'dump.rdb');
    if (!$self->_restore_target_safe($dump_path, $account, 1)
        || $self->_install_restore_stage($stage, $dump_path, $account, 1) != 1) {
        unlink($stage) if -e $stage || -l $stage;
        return 0;
    }
    my %original_manifest = %{$manifest};
    delete $original_manifest{settings};
    delete $original_manifest{preset} if $original_manifest{version} == 1;
    my $manifest_json = JSON::PP->new->canonical(1)->encode(\%original_manifest) . "\n";
    return 0 if !$self->_atomic_write($self->_manifest_path($account->{name}), $manifest_json,
        0640, $self->{expected_owner_uid}, $account->{gid});
    my ($started) = $self->_systemctl('start', '--no-block', $unit);
    return 0 if !$started || !$self->_wait_for_unit_state($unit, 'active', $self->{restore_state_timeout});
    return 0 if !$self->_redis_cli_command('redis', $manifest->{socket}, 'PING');
    my $restored_keyspace = $self->_migration_keyspace('redis', $manifest->{socket});
    return ref($restored_keyspace) eq 'HASH' && _same_keyspace($expected_keyspace, $restored_keyspace) ? 1 : 0;
}

sub _migration_keyspace {
    my ($self, $backend, $socket) = @_;
    my $info = $self->_run_redis_cli($backend, $socket, 'INFO', 'keyspace');
    return undef if !defined($info) || length($info) > 1024;
    my %keyspace;
    for my $line (split(/\r?\n/, $info)) {
        next if $line eq '' || $line =~ /^#/;
        return undef if $line !~ /\Adb([0-9]+):keys=([0-9]+),expires=([0-9]+),avg_ttl=[0-9]+\z/;
        my ($database, $keys, $expires) = (0 + $1, 0 + $2, 0 + $3);
        return undef if $database > 15 || $keys > 9_000_000_000_000_000 || $expires > $keys
            || exists($keyspace{$database});
        $keyspace{$database} = { expires => $expires, keys => $keys };
    }
    return \%keyspace;
}

sub _same_keyspace {
    my ($left, $right) = @_;
    return 0 if ref($left) ne 'HASH' || ref($right) ne 'HASH'
        || join(',', sort { $a <=> $b } keys %{$left}) ne join(',', sort { $a <=> $b } keys %{$right});
    for my $database (keys %{$left}) {
        return 0 if ref($left->{$database}) ne 'HASH' || ref($right->{$database}) ne 'HASH'
            || $left->{$database}->{keys} != $right->{$database}->{keys}
            || $left->{$database}->{expires} != $right->{$database}->{expires};
    }
    return 1;
}

sub _backend_server_version {
    my ($self, $backend) = @_;
    my $path = $self->_available_binary($backend);
    return undef if !defined($path);
    my $output;
    if (ref($self->{backend_version_probe}) eq 'CODE') {
        $output = eval { $self->{backend_version_probe}->($backend, $path) };
    } else {
        my $completed = eval {
            local $SIG{ALRM} = sub { die "Backend version timeout\n" };
            local %ENV = (PATH => '/usr/bin:/bin', HOME => '/', LANG => 'C', LC_ALL => 'C');
            alarm(3);
            if (open(my $pipe, '-|', $path, '--version')) {
                $output = '';
                my $read = read($pipe, $output, 513);
                $output = undef if !defined($read) || $read > 512 || !close($pipe);
            }
            alarm(0);
            1;
        };
        alarm(0);
        return undef if !$completed;
    }
    return undef if !defined($output) || ref($output) || length($output) > 512;
    my ($version) = $output =~ /\bv=([0-9]+\.[0-9]+\.[0-9]+)\b/;
    return $version;
}

sub _version_at_least {
    my ($version, $minimum) = @_;
    return 0 if !defined($version) || !defined($minimum);
    my @version = split(/[.]/, $version);
    my @minimum = split(/[.]/, $minimum);
    return 0 if @version != 3 || @minimum != 3 || grep { !/\A[0-9]+\z/ } (@version, @minimum);
    for my $index (0 .. 2) {
        return 1 if $version[$index] > $minimum[$index];
        return 0 if $version[$index] < $minimum[$index];
    }
    return 1;
}

sub _version_in_range {
    my ($version, $minimum, $maximum) = @_;
    return _version_at_least($version, $minimum) && !_version_at_least($version, _next_version($maximum));
}

sub _next_version {
    my ($version) = @_;
    my @parts = split(/[.]/, $version);
    return $version if @parts != 3;
    return join('.', $parts[0], $parts[1], $parts[2] + 1);
}

sub _migration_failure {
    my ($recovered, $backup_id) = @_;
    my $response = _failure($recovered ? 'migration_failed' : 'migration_rollback_failed');
    $response->{safety_backup_id} = $backup_id if defined($backup_id)
        && $backup_id =~ /\Asnapshot-[0-9]{10}-[a-f0-9]{8}[.]rdb\z/;
    return $response;
}

sub _redis_cli_command {
    my ($self, $backend, $socket, @arguments) = @_;
    return 0 if !defined($backend) || $backend !~ /\A(?:redis|valkey)\z/;
    my $output = $self->_run_redis_cli($backend, $socket, @arguments);
    return defined($output) && $output eq "OK\n" if @arguments && $arguments[0] eq 'CLIENT';
    return defined($output) && $output eq "PONG\n" if @arguments && $arguments[0] eq 'PING';
    return 0;
}

sub configure {
    my ($self, $account, $settings) = @_;
    my $lock = $self->_acquire_instance_lock($account);
    return _failure('operation_in_progress') if !defined($lock);
    my $response = $self->_configure_locked($account, $settings);
    close($lock);
    return $response;
}

sub _configure_locked {
    my ($self, $account, $settings) = @_;
    return _failure('invalid_request') if !_valid_settings($settings);
    my $manifest = $self->_read_manifest($account);
    return _failure('not_configured') if !$manifest;
    my ($active, $state) = $self->_systemctl('is-active', $self->_unit_name($account->{name}));
    return _failure('instance_unavailable') if !$active && $state ne 'inactive' && $state ne 'failed';
    return _failure('instance_unavailable') if $state eq 'activating' || $state eq 'reloading' || $state eq 'deactivating';

    my $runtime_previous;
    if ($state eq 'active') {
        $runtime_previous = $self->_redis_config_get($manifest->{backend}, $manifest->{socket});
        return _failure('configuration_unavailable') if !_valid_settings($runtime_previous);
    }
    my $existing_max_clients = $state eq 'active'
        ? $runtime_previous->{maxclients}
        : $manifest->{settings}->{maxclients};
    my $provider_decision = $self->{provider_policy}->memory_decision(
        $account, $settings->{memory_mib}, $settings->{maxclients}, $existing_max_clients
    );
    return _failure('provider_policy_unavailable') if ref($provider_decision) ne 'HASH';
    return _failure('provider_policy_denied') if !$provider_decision->{allowed};

    my ($auth_valid, $auth_secret) = $self->_read_auth_secret($account, $manifest);
    return _failure('configuration_unavailable') if !$auth_valid;
    my $config = _redis_config($manifest->{data}, $manifest->{socket}, $settings, $auth_secret, _manifest_database_count($manifest));
    my $temporary = $self->_stage_atomic_write(
        $manifest->{config}, $config, 0640, $self->{expected_owner_uid}, $account->{gid}
    );
    return _failure('configuration_storage_unavailable') if !defined($temporary);

    if ($state eq 'active') {
        my @applied;
        for my $setting (qw(maxmemory_policy maxclients timeout memory_mib)) {
            my ($parameter, $value) = _redis_parameter($setting, $settings->{$setting});
            push(@applied, $setting);
            if (!$self->_redis_config_set($manifest->{backend}, $manifest->{socket}, $parameter, $value)) {
                my $rollback_ok = $self->_rollback_live_settings($manifest, $runtime_previous, \@applied);
                unlink($temporary);
                return _failure($rollback_ok ? 'configuration_failed' : 'configuration_uncertain');
            }
        }
    }

    if (!$self->_commit_atomic_write($temporary, $manifest->{config})) {
        my $rollback_ok = $state ne 'active'
            || $self->_rollback_live_settings($manifest, $runtime_previous, [qw(maxmemory_policy maxclients timeout memory_mib)]);
        unlink($temporary);
        return _failure($rollback_ok ? 'configuration_storage_unavailable' : 'configuration_uncertain');
    }

    $manifest->{settings} = { %{$settings} };
    my $result_state = $state eq 'active' ? 'running' : $state eq 'failed' ? 'failed' : 'stopped';
    my $result = _state($result_state, $manifest);
    $result->{policy_warnings} = $provider_decision->{violations}
        if $provider_decision->{mode} eq 'warn' && @{$provider_decision->{violations}};
    return $result;
}

sub _rollback_live_settings {
    my ($self, $manifest, $settings, $applied) = @_;
    my $ok = 1;
    for my $setting (reverse @{$applied}) {
        my ($parameter, $value) = _redis_parameter($setting, $settings->{$setting});
        $ok = 0 if !$self->_redis_config_set($manifest->{backend}, $manifest->{socket}, $parameter, $value);
    }
    return $ok;
}

sub _redis_config_get {
    my ($self, $backend, $socket) = @_;
    return undef if !defined($backend) || $backend !~ /\A(?:redis|valkey)\z/;
    if (ref($self->{config_get}) eq 'CODE') {
        return undef if !defined($socket) || ref($socket) || $socket =~ /[\r\n\0]/;
        my $settings = eval { $self->{config_get}->($backend, $socket) };
        return undef if !_valid_settings($settings);
        return { %{$settings} };
    }
    return undef if !defined($socket) || $socket !~ m{\A/var/lib/orm-instances/[a-zA-Z0-9_-]{1,16}/redis\.sock\z};
    my %values;
    for my $parameter (qw(maxmemory maxmemory-policy maxclients timeout)) {
        # One pattern works on Redis and Valkey versions before multi-pattern CONFIG GET (7.0).
        my $output = _run_redis_cli($self, $backend, $socket, 'CONFIG', 'GET', $parameter);
        return undef if !defined($output);
        my @lines = split(/\r?\n/, $output, -1);
        pop @lines if @lines && $lines[-1] eq '';
        return undef if @lines != 2 || $lines[0] ne $parameter;
        $values{$parameter} = $lines[1];
    }
    return undef if join(',', sort keys %values) ne 'maxclients,maxmemory,maxmemory-policy,timeout';
    return undef if $values{maxmemory} !~ /\A[0-9]+\z/ || $values{maxmemory} % (1024 * 1024) != 0;
    return undef if $values{maxclients} !~ /\A[0-9]+\z/ || $values{timeout} !~ /\A[0-9]+\z/;
    my $settings = {
        memory_mib => int($values{maxmemory} / (1024 * 1024)),
        maxmemory_policy => $values{'maxmemory-policy'},
        maxclients => 0 + $values{maxclients},
        timeout => 0 + $values{timeout},
    };
    return _valid_settings($settings) ? $settings : undef;
}

sub _redis_config_set {
    my ($self, $backend, $socket, $parameter, $value) = @_;
    return 0 if !defined($backend) || $backend !~ /\A(?:redis|valkey)\z/;
    return 0 if !defined($socket) || ref($socket) || $socket =~ /[\r\n\0]/;
    return 0 if !defined($parameter) || !defined($value) || ref($parameter) || ref($value);
    return 0 if $parameter !~ /\A(?:maxmemory|maxmemory-policy|maxclients|timeout)\z/;
    return 0 if $value =~ /[\r\n\0]/;
    return 0 if $parameter eq 'maxmemory' && ($value !~ /\A[0-9]+\z/ || $value < 8 * 1024 * 1024 || $value > $MAX_MEMORY_BYTES);
    return 0 if $parameter eq 'maxmemory-policy' && !exists($MAXMEMORY_POLICIES{$value});
    return 0 if $parameter eq 'maxclients' && ($value !~ /\A[0-9]+\z/ || $value < 10 || $value > 100);
    return 0 if $parameter eq 'timeout' && ($value !~ /\A[0-9]+\z/ || $value > 300);
    if (ref($self->{config_set}) eq 'CODE') {
        my $ok = eval { $self->{config_set}->($backend, $socket, $parameter, $value) };
        return $ok ? 1 : 0;
    }
    return 0 if $socket !~ m{\A/var/lib/orm-instances/[a-zA-Z0-9_-]{1,16}/redis\.sock\z};
    my $output = _run_redis_cli($self, $backend, $socket, 'CONFIG', 'SET', $parameter, $value);
    return defined($output) && $output eq "OK\n" ? 1 : 0;
}

sub _run_redis_cli {
    my ($self, $backend, $socket, @arguments) = @_;
    my $output_limit = @arguments && $arguments[0] eq 'INFO' ? $MAX_INFO_BYTES : 1024;
    if (ref($self->{redis_cli_call}) eq 'CODE') {
        my $output = eval { $self->{redis_cli_call}->($backend, $socket, @arguments) };
        return undef if !$output || ref($output) || length($output) > $output_limit;
        return $output;
    }
    my ($auth_valid, $auth_secret) = $self->_auth_secret_for_socket($socket);
    return undef if !$auth_valid;
    my $client_name = $backend eq 'valkey' ? 'valkey' : 'redis';
    my $path;
    for my $candidate (@{$self->{client_paths}->{$client_name} // []}) {
        next if !defined($candidate) || $candidate !~ m{\A/usr/(?:local/)?(?:s?bin)/(?:redis|valkey)-cli\z};
        my @stat = lstat($candidate);
        next if !@stat || !S_ISREG($stat[2]) || $stat[4] != 0 || ($stat[2] & 0022) != 0 || !-x $candidate;
        $path = $candidate;
        last;
    }
    return undef if !defined($path);

    my ($output, $opened) = ('', 0);
    my $completed = eval {
        local $SIG{ALRM} = sub { die "Redis client timeout\n" };
        local %ENV = (PATH => '/usr/bin:/bin', HOME => '/', LANG => 'C', LC_ALL => 'C');
        $ENV{REDISCLI_AUTH} = $auth_secret if defined($auth_secret);
        alarm(3);
        if (open(my $pipe, '-|', $path, '-s', $socket, '--raw', @arguments)) {
            $opened = 1;
            my $read = read($pipe, $output, $output_limit + 1);
            $output = '' if !defined($read) || $read == 0 || $read > $output_limit;
            my $closed = close($pipe);
            $opened = 0;
            die "Redis client command failed\n" if !$closed;
        } else {
            die "Redis client unavailable\n";
        }
        alarm(0);
        1;
    };
    alarm(0);
    return undef if !$completed || $opened || $output eq '' || length($output) > $output_limit;
    return $output;
}

sub _auth_secret_for_socket {
    my ($self, $socket, $expected_gid) = @_;
    return (0, undef) if !defined($socket) || ref($socket);
    my ($account_name) = $socket =~ m{\A\Q$self->{data_root}\E/([a-zA-Z0-9_-]{1,16})/redis\.sock\z};
    return (0, undef) if !defined($account_name);
    my $directory = $self->_account_config_dir($account_name);
    my @directory_stat = lstat($directory);
    return (0, undef) if !@directory_stat || !S_ISDIR($directory_stat[2])
        || $directory_stat[4] != $self->{expected_owner_uid}
        || (defined($expected_gid) && $directory_stat[5] != $expected_gid)
        || ($directory_stat[2] & 0027) != 0;
    my $path = File::Spec->catfile($directory, 'redis.conf');
    return (0, undef) if !sysopen(my $handle, $path, O_RDONLY | O_NOFOLLOW);
    my @stat = stat($handle);
    if (!@stat || !S_ISREG($stat[2]) || $stat[4] != $self->{expected_owner_uid}
        || $stat[5] != $directory_stat[5] || $stat[3] != 1 || ($stat[2] & 0037) != 0
        || $stat[7] > 16384) {
        close($handle);
        return (0, undef);
    }
    my $content = '';
    my $read = read($handle, $content, 16385);
    my $closed = close($handle);
    return (0, undef) if !defined($read) || !$closed || length($content) > 16384;
    my @secrets = $content =~ /^requirepass ([A-Za-z0-9_-]{43})$/mg;
    my $directives = scalar(() = $content =~ /^requirepass(?:[ \t].*)?$/mg);
    return (0, undef) if $directives > 1 || $directives != @secrets;
    return (1, @secrets ? $secrets[0] : undef);
}

sub _read_auth_secret {
    my ($self, $account, $manifest) = @_;
    return (0, undef) if ref($account) ne 'HASH' || ref($manifest) ne 'HASH'
        || ($manifest->{config} // '') ne File::Spec->catfile($self->_account_config_dir($account->{name}), 'redis.conf');
    return $self->_auth_secret_for_socket($manifest->{socket}, $account->{gid});
}

sub _parse_info_fields {
    my ($output, $requested) = @_;
    return undef if !defined($output) || ref($output) || length($output) > $MAX_INFO_BYTES
        || ref($requested) ne 'HASH';
    my %values;
    my @lines = split(/\r?\n/, $output);
    return undef if @lines > 128;
    for my $line (@lines) {
        next if $line eq '' || $line =~ /\A#/;
        next if $line !~ /\A([A-Za-z0-9_]+):([^\r\n]*)\z/;
        my ($key, $value) = ($1, $2);
        next if !exists($requested->{$key});
        return undef if exists($values{$key});
        if ($requested->{$key} eq 'integer') {
            return undef if $value !~ /\A(?:0|[1-9][0-9]{0,15})\z/ || $value > $MAX_DIAGNOSTIC_INTEGER;
            $values{$key} = 0 + $value;
        } elsif ($requested->{$key} eq 'version') {
            return undef if length($value) > 48
                || $value !~ /\A[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}(?:[-+][A-Za-z0-9.-]{1,24})?\z/;
            $values{$key} = $value;
        } else {
            return undef;
        }
    }
    return undef if grep { !exists($values{$_}) } keys %{$requested};
    return \%values;
}

sub _parse_commandstats {
    my ($output) = @_;
    return undef if !defined($output) || ref($output) || length($output) > $MAX_INFO_BYTES;
    my @lines = split(/\r?\n/, $output);
    return undef if @lines > 512;
    my (@commands, %seen);
    for my $line (@lines) {
        next if $line eq '' || $line =~ /\A#/;
        return undef if $line !~ /\Acmdstat_([A-Za-z0-9_.|]{1,64}):([A-Za-z0-9_=.,-]{1,512})\z/;
        my ($command, $payload) = ($1, $2);
        return undef if $seen{$command}++;
        my (%fields, %seen_fields);
        for my $field (split(/,/, $payload, 9)) {
            return undef if $field !~ /\A([a-z_]+)=([0-9]+(?:\.[0-9]{1,6})?)\z/;
            my ($name, $value) = ($1, $2);
            return undef if $seen_fields{$name}++;
            next if $name eq 'usec_per_call';
            next if $name !~ /\A(?:calls|usec|rejected_calls|failed_calls|slowlog_count|slowlog_time_ms_sum|slowlog_time_ms_max)\z/;
            return undef if $value !~ /\A(?:0|[1-9][0-9]{0,15})\z/ || $value > $MAX_DIAGNOSTIC_INTEGER;
            $fields{$name} = 0 + $value;
        }
        return undef if !exists($fields{calls}) || !exists($fields{usec});
        push @commands, { command => $command, calls => $fields{calls}, usec => $fields{usec} };
        return undef if @commands > 256;
    }
    @commands = sort { $b->{calls} <=> $a->{calls} || $a->{command} cmp $b->{command} } @commands;
    my $truncated = @commands > $MAX_COMMANDSTAT_ROWS ? 1 : 0;
    splice(@commands, $MAX_COMMANDSTAT_ROWS) if $truncated;
    return { commands => \@commands, truncated => $truncated };
}

sub metrics {
    my ($self, $account) = @_;
    my $manifest = $self->_read_manifest($account);
    return _failure('not_configured') if !$manifest;
    my ($active, $state) = $self->_systemctl('is-active', $self->_unit_name($account->{name}));
    if (!$active || $state ne 'active') {
        my $stale = $self->_stale_metrics($account);
        return $stale if $stale;
        return _failure(!$active && ($state eq 'inactive' || $state eq 'failed') ? 'not_running' : 'instance_unavailable');
    }
    $self->_ensure_metrics_timer($account);

    my $info;
    if (ref($self->{metrics_probe}) eq 'CODE') {
        $info = eval { $self->{metrics_probe}->($manifest->{backend}, $manifest->{socket}) };
    } else {
        $info = $self->_redis_info($manifest->{backend}, $manifest->{socket});
    }
    return $self->_stale_metrics($account) // _failure('metrics_unavailable')
        if !defined($info) || ref($info) || length($info) == 0 || length($info) > $MAX_INFO_BYTES;

    my %metrics;
    for my $name (@METRIC_FIELDS) {
        my $field = $METRIC_INFO_FIELDS{$name};
        my ($value) = $info =~ /^\Q$field\E:([0-9]+)\r?$/m;
        return $self->_stale_metrics($account) // _failure('metrics_unavailable')
            if !defined($value) || length($value) > 15;
        $metrics{$name} = 0 + $value;
    }
    my $sample = { %metrics, sampled_at => time };
    my $retained = $self->_write_metrics_snapshot($account, $sample);
    $self->_write_metrics_history($account, $sample);
    my %securityCounters = (sampled_at => $sample->{sampled_at}, uptime_seconds => $sample->{uptime_seconds});
    for my $field (qw(evicted_keys total_commands_processed acl_access_denied_auth)) {
        my ($value) = $info =~ /^\Q$field\E:([0-9]+)\r?$/m;
        $securityCounters{$field} = 0 + $value if defined($value) && length($value) <= 15;
    }
    $self->_write_security_metrics_snapshot($account, \%securityCounters);
    return {
        %{$sample}, retained => $retained ? JSON::PP::true : JSON::PP::false,
        stale => JSON::PP::false, success => JSON::PP::true, version => 1,
    };
}

sub metrics_history {
    my ($self, $account, $range) = @_;
    return _failure('invalid_request') if !defined($range) || ref($range) || $range !~ /\A(?:24h|7d)\z/;
    return _failure('not_configured') if !$self->_read_manifest($account);
    my $lock = $self->_metrics_history_lock($account);
    return _failure('metrics_history_unavailable') if !defined($lock);
    my $history = $self->_read_metrics_history_locked($account);
    close($lock);
    return _failure('metrics_history_unavailable') if ref($history) ne 'ARRAY';

    my $range_seconds = $range eq '24h' ? 24 * 60 * 60 : 7 * 24 * 60 * 60;
    my $cutoff = time - $range_seconds;
    my @samples = grep { $_->{sampled_at} >= $cutoff } @{$history};
    my $maximum = $range eq '24h' ? 24 : 168;
    @samples = @samples[@samples - $maximum .. $#samples] if @samples > $maximum;
    my @series = map {
        my $sample = $_;
        +{ map { $_ => 0 + $sample->{$_} } qw(sampled_at memory_used_bytes connected_clients keyspace_hits keyspace_misses) }
    } @samples;
    my ($timer_active, $timer_state) = $self->_systemctl('is-active', $self->_metrics_timer_unit($account->{name}));
    return {
        history => \@series,
        range => $range,
        scheduled => $timer_active && $timer_state eq 'active' ? JSON::PP::true : JSON::PP::false,
        success => JSON::PP::true,
        version => 1,
    };
}

sub backups {
    my ($self, $account) = @_;
    return _failure('not_configured') if !$self->_read_manifest($account);
    my ($directory, $directory_state) = $self->_backup_directory($account, 0);
    return _failure('backup_storage_unavailable') if $directory_state eq 'unsafe';
    my $entries = $directory_state eq 'absent' ? [] : $self->_read_backup_entries($directory, $account);
    return _failure('backup_storage_unavailable') if ref($entries) ne 'ARRAY' || @{$entries} > $MAX_BACKUPS_PER_ACCOUNT;
    return { backups => $entries, success => JSON::PP::true, version => 1 };
}

sub create_backup {
    my ($self, $account) = @_;
    my $lock = $self->_acquire_instance_lock($account);
    return _failure('operation_in_progress') if !defined($lock);
    my $response = $self->_create_backup_public_locked($account);
    close($lock);
    return $response;
}

sub _create_backup_public_locked {
    my ($self, $account) = @_;
    my $manifest = $self->_read_manifest($account);
    return _failure('not_configured') if !$manifest;
    my ($active, $state) = $self->_systemctl('is-active', $self->_unit_name($account->{name}));
    return _failure('not_running') if !$active || $state ne 'active';

    my ($directory, $directory_state) = $self->_backup_directory($account, 1);
    return _failure('backup_storage_unavailable') if !$directory || $directory_state ne 'ready';
    my ($lock, $lock_error) = $self->_acquire_backup_lock($directory);
    return _failure($lock_error) if !defined($lock);
    my $response = eval { $self->_create_backup_locked($account, $manifest, $directory, undef) };
    close($lock);
    return ref($response) eq 'HASH' ? $response : _failure('backup_storage_unavailable');
}

sub _acquire_backup_lock {
    my ($self, $directory) = @_;
    my $lock_path = File::Spec->catfile($directory, 'backup.lock');
    my $lock;
    return (undef, 'backup_storage_unavailable') if !sysopen($lock, $lock_path, O_WRONLY | O_CREAT | O_NOFOLLOW, 0600);
    my @lock_stat = stat($lock);
    if (!@lock_stat || !S_ISREG($lock_stat[2]) || $lock_stat[4] != $self->{expected_owner_uid}
        || $lock_stat[5] != $self->{expected_owner_uid} || $lock_stat[3] != 1 || ($lock_stat[2] & 0777) != 0600) {
        close($lock);
        return (undef, 'backup_storage_unavailable');
    }
    if (!flock($lock, LOCK_EX | LOCK_NB)) {
        close($lock);
        return (undef, 'backup_in_progress');
    }
    return ($lock, undef);
}

sub _create_backup_locked {
    my ($self, $account, $manifest, $directory, $preserve_id) = @_;
    my $existing = $self->_read_backup_entries($directory, $account);
    return _failure('backup_storage_unavailable') if ref($existing) ne 'ARRAY';
    my $effective_policy = $self->{provider_policy}->effective_for($account);
    return _failure('provider_policy_unavailable') if ref($effective_policy) ne 'HASH';
    my $retention = $manifest->{version} >= 3
        ? $manifest->{provisioned_defaults}->{backup_retention} : $effective_policy->{backup_retention};
    my $retention_limit = $effective_policy->{mode} eq 'enforce'
        ? $retention : $MAX_BACKUPS_PER_ACCOUNT;
    my $created_at = time;
    my $backup_id;
    my $temporary;
    for (1 .. 3) {
        $backup_id = sprintf('snapshot-%010d-%08x.rdb', $created_at, int(rand(4294967296)));
        $temporary = File::Spec->catfile($directory, '.snapshot-' . $$ . '-' . sprintf('%08x', int(rand(4294967296))) . '.tmp');
        last if !-e $temporary && !-l $temporary && !-e File::Spec->catfile($directory, $backup_id)
            && !-l File::Spec->catfile($directory, $backup_id);
        undef $temporary;
    }
    my $stage;
    return _failure('backup_storage_unavailable') if !defined($temporary)
        || !sysopen($stage, $temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    my $stage_ok = chown($self->{expected_owner_uid}, $self->{expected_owner_uid}, $temporary)
        && chmod(0600, $temporary) && close($stage);
    if (!$stage_ok) {
        unlink($temporary) if -e $temporary || -l $temporary;
        return _failure('backup_storage_unavailable');
    }

    my $created = $self->_run_backup_cli($manifest->{backend}, $manifest->{socket}, $temporary);
    my @stage_stat = lstat($temporary);
    my $valid_stage = $created && @stage_stat && S_ISREG($stage_stat[2])
        && $stage_stat[4] == $self->{expected_owner_uid} && $stage_stat[5] == $self->{expected_owner_uid}
        && $stage_stat[3] == 1 && ($stage_stat[2] & 0777) == 0600
        && $stage_stat[7] > 0 && $stage_stat[7] <= $MAX_BACKUP_BYTES;
    if (!$valid_stage) {
        unlink($temporary) if -e $temporary || -l $temporary;
        return _failure($created ? 'backup_invalid' : 'backup_failed');
    }

    my $destination = File::Spec->catfile($directory, $backup_id);
    if (!chown($self->{expected_owner_uid}, $account->{gid}, $temporary)
        || !chmod(0640, $temporary) || !rename($temporary, $destination)) {
        unlink($temporary) if -e $temporary || -l $temporary;
        return _failure('backup_storage_unavailable');
    }
    my $all_entries = $self->_read_backup_entries($directory, $account);
    return _failure('backup_storage_unavailable') if ref($all_entries) ne 'ARRAY';
    my %preserve = ($backup_id => 1);
    $preserve{$preserve_id} = 1 if defined($preserve_id);
    for my $old_entry (reverse @{$all_entries}) {
        last if @{$all_entries} <= $retention_limit;
        next if $preserve{$old_entry->{id}};
        my $old_path = File::Spec->catfile($directory, $old_entry->{id});
        return _failure('backup_retention_failed') if !unlink($old_path);
        @{$all_entries} = grep { $_->{id} ne $old_entry->{id} } @{$all_entries};
    }
    my $retained_entries = $self->_read_backup_entries($directory, $account);
    return _failure('backup_storage_unavailable') if ref($retained_entries) ne 'ARRAY';
    return _failure('backup_retention_failed') if @{$retained_entries} > $retention_limit;
    my ($created_entry) = grep { $_->{id} eq $backup_id } @{$retained_entries};
    return _failure('backup_storage_unavailable') if ref($created_entry) ne 'HASH';
    return { backup => $created_entry, success => JSON::PP::true, version => 1 };
}

sub restore_backup {
    my ($self, $account, $backup_id) = @_;
    my $lock = $self->_acquire_instance_lock($account);
    return _failure('operation_in_progress') if !defined($lock);
    my $response = $self->_restore_backup_locked($account, $backup_id);
    close($lock);
    return $response;
}

sub _restore_backup_locked {
    my ($self, $account, $backup_id) = @_;
    my $manifest = $self->_read_manifest($account);
    return _failure('not_configured') if !$manifest;
    return _failure('invalid_request') if !defined($backup_id) || ref($backup_id)
        || $backup_id !~ /\Asnapshot-[0-9]{10}-[a-f0-9]{8}[.]rdb\z/;

    my $unit = $self->_unit_name($account->{name});
    my ($active, $state) = $self->_systemctl('is-active', $unit);
    return $self->_restore_audit_response($account, $backup_id, undef, 'not_running', $state)
        if !$active || $state ne 'active';

    my ($directory, $directory_state) = $self->_backup_directory($account, 0);
    return $self->_restore_audit_response($account, $backup_id, undef, 'backup_storage_unavailable', 'running')
        if !$directory || $directory_state ne 'ready';
    my ($lock, $lock_error) = $self->_acquire_backup_lock($directory);
    return $self->_restore_audit_response($account, $backup_id, undef, $lock_error, 'running')
        if !defined($lock);

    my @temporary_paths;
    my $safety_id;
    my $finish = sub {
        my ($response, $outcome, $final_state) = @_;
        for my $path (@temporary_paths) {
            unlink($path) if -e $path || -l $path;
        }
        close($lock);
        return $self->_restore_audit_response($account, $backup_id, $safety_id, $outcome, $final_state, $response);
    };

    my $entries = $self->_read_backup_entries($directory, $account);
    return $finish->(_failure('backup_storage_unavailable'), 'backup_storage_unavailable', 'running')
        if ref($entries) ne 'ARRAY';
    return $finish->(_failure('backup_not_found'), 'backup_not_found', 'running')
        if !(grep { $_->{id} eq $backup_id } @{$entries});

    my $restore_stage = $self->_new_backup_stage_path($directory, 'restore');
    return $finish->(_failure('backup_storage_unavailable'), 'backup_storage_unavailable', 'running')
        if !defined($restore_stage);
    push @temporary_paths, $restore_stage;
    my $staged = $self->_stage_backup_copy($directory, $backup_id, $restore_stage, $account);
    return $finish->(_failure($staged ? 'backup_invalid' : 'backup_storage_unavailable'),
        $staged ? 'backup_invalid' : 'backup_storage_unavailable', 'running') if !$staged;

    my $valid_rdb = $self->_run_rdb_check($manifest->{backend}, $restore_stage, $account);
    return $finish->(_failure(defined($valid_rdb) ? 'backup_invalid' : 'restore_validation_unavailable'),
        defined($valid_rdb) ? 'backup_invalid' : 'restore_validation_unavailable', 'running') if !$valid_rdb;

    my $target = File::Spec->catfile($manifest->{data}, 'dump.rdb');
    return $finish->(_failure('backup_storage_unavailable'), 'backup_storage_unavailable', 'running')
        if !$self->_restore_target_safe($target, $account);

    my $safety = $self->_create_backup_locked($account, $manifest, $directory, $backup_id);
    if (ref($safety) ne 'HASH' || !$safety->{success} || ref($safety->{backup}) ne 'HASH') {
        my $error = ref($safety) eq 'HASH' && defined($safety->{error}) ? $safety->{error} : 'backup_failed';
        return $finish->(_failure($error), $error, 'running');
    }
    $safety_id = $safety->{backup}->{id};

    my $rollback_stage = $self->_new_backup_stage_path($directory, 'rollback');
    return $finish->(_failure('backup_storage_unavailable'), 'backup_storage_unavailable', 'running')
        if !defined($rollback_stage);
    push @temporary_paths, $rollback_stage;
    my $safety_staged = $self->_stage_backup_copy($directory, $safety_id, $rollback_stage, $account);
    return $finish->(_failure($safety_staged ? 'backup_invalid' : 'backup_storage_unavailable'),
        $safety_staged ? 'backup_invalid' : 'backup_storage_unavailable', 'running') if !$safety_staged;
    my $safety_valid = $self->_run_rdb_check($manifest->{backend}, $rollback_stage, $account);
    return $finish->(_failure(defined($safety_valid) ? 'backup_invalid' : 'restore_validation_unavailable'),
        defined($safety_valid) ? 'backup_invalid' : 'restore_validation_unavailable', 'running') if !$safety_valid;

    my ($stopped) = $self->_systemctl('stop', '--no-block', $unit);
    if (!$stopped || !$self->_wait_for_unit_state($unit, 'inactive', $self->{restore_state_timeout})) {
        my $recovered = $self->_ensure_unit_running($unit);
        return $finish->(_failure('restore_failed'), 'restore_failed', $recovered ? 'running' : 'unavailable');
    }
    if (!$self->_restore_target_safe($target, $account)) {
        my ($start_ok) = $self->_systemctl('start', '--no-block', $unit);
        my $recovered = $start_ok && $self->_wait_for_unit_state($unit, 'active', $self->{restore_state_timeout});
        return $finish->(_failure('restore_failed'), 'restore_failed', $recovered ? 'running' : 'unavailable');
    }

    my $installed = $self->_install_restore_stage($restore_stage, $target, $account);
    if (!$installed) {
        my $recovered = $installed < 0
            ? $self->_rollback_restore($unit, $rollback_stage, $target, $account)
            : $self->_ensure_unit_running($unit);
        my $error = $recovered ? 'restore_failed' : 'restore_rollback_failed';
        return $finish->(_failure($error), $error, $recovered ? 'running' : 'unavailable');
    }

    my ($start_ok) = $self->_systemctl('start', '--no-block', $unit);
    if ($start_ok && $self->_wait_for_unit_state($unit, 'active', $self->{restore_state_timeout})) {
        my $response = {
            backup_id => $backup_id,
            safety_backup_id => $safety_id,
            state => 'running',
            success => JSON::PP::true,
            version => 1,
        };
        return $finish->($response, 'success', 'running');
    }

    if ($self->_rollback_restore($unit, $rollback_stage, $target, $account)) {
        return $finish->(_failure('restore_failed'), 'restore_failed', 'running');
    }
    return $finish->(_failure('restore_rollback_failed'), 'restore_rollback_failed', 'unavailable');
}

sub _restore_audit_response {
    my ($self, $account, $backup_id, $safety_id, $outcome, $state, $response) = @_;
    $state = 'unavailable' if !defined($state) || $state !~ /\A(?:running|inactive|failed|unavailable)\z/;
    if (ref($self->{restore_audit}) eq 'CODE') {
        eval { $self->{restore_audit}->($account->{uid}, $account->{name}, $backup_id, $safety_id, $outcome, $state) };
    } else {
        my $safe_backup = defined($backup_id) && $backup_id =~ /\Asnapshot-[0-9]{10}-[a-f0-9]{8}[.]rdb\z/
            ? $backup_id : 'invalid';
        my $safe_safety = defined($safety_id) && $safety_id =~ /\Asnapshot-[0-9]{10}-[a-f0-9]{8}[.]rdb\z/
            ? $safety_id : 'none';
        eval {
            openlog('orm-broker', 'pid', 'authpriv');
            syslog(LOG_NOTICE, 'backup_restore actor_uid=%s account=%s backup=%s safety=%s result=%s state=%s',
                $account->{uid}, $account->{name}, $safe_backup, $safe_safety, $outcome, $state)
                or die "syslog write failed";
            closelog();
        };
        eval { closelog(); };
    }
    if (ref($response) ne 'HASH') {
        $response = { error => 'restore_failed', success => JSON::PP::false, version => 1 };
    }
    $response->{safety_backup_id} = $safety_id if defined($safety_id)
        && $safety_id =~ /\Asnapshot-[0-9]{10}-[a-f0-9]{8}[.]rdb\z/;
    return $response;
}

sub _new_backup_stage_path {
    my ($self, $directory, $purpose) = @_;
    return undef if !defined($purpose) || $purpose !~ /\A(?:restore|rollback)\z/;
    for (1 .. 5) {
        my $path = File::Spec->catfile($directory, '.' . $purpose . '-' . $$ . '-' . sprintf('%08x', int(rand(4294967296))) . '.tmp');
        return $path if !-e $path && !-l $path;
    }
    return undef;
}

sub _stage_backup_copy {
    my ($self, $directory, $backup_id, $destination, $account) = @_;
    return 0 if !defined($backup_id) || $backup_id !~ /\Asnapshot-[0-9]{10}-[a-f0-9]{8}[.]rdb\z/
        || !defined($destination);
    my $source = File::Spec->catfile($directory, $backup_id);
    my @source_path_stat = lstat($source);
    return 0 if !@source_path_stat || !S_ISREG($source_path_stat[2])
        || $source_path_stat[4] != $self->{expected_owner_uid} || $source_path_stat[5] != $account->{gid}
        || $source_path_stat[3] != 1 || ($source_path_stat[2] & 0777) != 0640
        || $source_path_stat[7] < 1 || $source_path_stat[7] > $MAX_BACKUP_BYTES;
    my $input;
    return 0 if !sysopen($input, $source, O_RDONLY | O_NOFOLLOW);
    my @source_stat = stat($input);
    if (!@source_stat || $source_stat[0] != $source_path_stat[0] || $source_stat[1] != $source_path_stat[1]
        || $source_stat[4] != $self->{expected_owner_uid} || $source_stat[5] != $account->{gid}
        || $source_stat[3] != 1 || ($source_stat[2] & 0777) != 0640 || $source_stat[7] != $source_path_stat[7]) {
        close($input);
        return 0;
    }
    my $output;
    if (!sysopen($output, $destination, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600)) {
        close($input);
        return 0;
    }
    binmode($input);
    binmode($output);
    my $copied = 0;
    my $ok = 1;
    while (1) {
        my $buffer = '';
        my $read = read($input, $buffer, 65536);
        if (!defined($read)) { $ok = 0; last; }
        last if $read == 0;
        $copied += $read;
        if ($copied > $MAX_BACKUP_BYTES || !print {$output} $buffer) { $ok = 0; last; }
    }
    $ok = 0 if $copied != $source_stat[7];
    $ok = 0 if !close($input);
    $ok = 0 if !close($output);
    if ($ok) {
        $ok = chown($self->{expected_owner_uid}, $account->{gid}, $destination)
            && chmod(0640, $destination);
    }
    if (!$ok) {
        unlink($destination) if -e $destination || -l $destination;
        return 0;
    }
    my @destination_stat = lstat($destination);
    return 0 if !@destination_stat || !S_ISREG($destination_stat[2])
        || $destination_stat[4] != $self->{expected_owner_uid} || $destination_stat[5] != $account->{gid}
        || $destination_stat[3] != 1 || ($destination_stat[2] & 0777) != 0640
        || $destination_stat[7] != $source_stat[7];
    return 1;
}

sub _run_rdb_check {
    my ($self, $backend, $path, $account) = @_;
    if (ref($self->{rdb_check}) eq 'CODE') {
        my $valid = eval { $self->{rdb_check}->($backend, $path, $account) };
        return $@ ? 0 : ($valid ? 1 : 0);
    }
    return undef if !defined($backend) || !exists($self->{rdb_check_paths}->{$backend});
    my $checker;
    for my $candidate (@{$self->{rdb_check_paths}->{$backend}}) {
        next if !defined($candidate)
            || $candidate !~ m{\A/usr/(?:local/)?(?:s?bin)/(?:redis|valkey)-check-rdb\z};
        my @stat = lstat($candidate);
        next if !@stat || !S_ISREG($stat[2]) || $stat[4] != 0 || ($stat[2] & 0022) != 0 || !-x $candidate;
        $checker = $candidate;
        last;
    }
    return undef if !defined($checker);
    my $pid = fork();
    return 0 if !defined($pid);
    if ($pid == 0) {
        local %ENV = (PATH => '/usr/bin:/bin', HOME => '/', LANG => 'C', LC_ALL => 'C');
        open(STDOUT, '>', '/dev/null') or _exit(127);
        open(STDERR, '>', '/dev/null') or _exit(127);
        $! = 0;
        $) = "$account->{gid} $account->{gid}";
        _exit(127) if $! != 0;
        setgid($account->{gid}) == 0 or _exit(127);
        setuid($account->{uid}) == 0 or _exit(127);
        exec {$checker} $checker, $path;
        _exit(127);
    }
    my $deadline = time + 30;
    while (1) {
        my $waited = waitpid($pid, WNOHANG);
        return $? == 0 ? 1 : 0 if $waited == $pid;
        return 0 if $waited == -1;
        if (time >= $deadline) {
            kill('TERM', $pid);
            my $grace = time + 1;
            while (time < $grace && waitpid($pid, WNOHANG) == 0) {
                select(undef, undef, undef, 0.05);
            }
            kill('KILL', $pid) if waitpid($pid, WNOHANG) == 0;
            waitpid($pid, 0);
            return 0;
        }
        select(undef, undef, undef, 0.05);
    }
}

sub _restore_target_safe {
    my ($self, $path, $account, $allow_broker_owned) = @_;
    my @path_stat = lstat($path);
    return 1 if !@path_stat && !-e $path && !-l $path;
    my $account_owned = @path_stat && $path_stat[4] == $account->{uid}
        && $path_stat[5] == $account->{gid} && ($path_stat[2] & 0777) == 0600;
    my $broker_owned = $allow_broker_owned && @path_stat && $path_stat[4] == $self->{expected_owner_uid}
        && $path_stat[5] == $account->{gid} && ($path_stat[2] & 0777) == 0640;
    return 0 if !@path_stat || !S_ISREG($path_stat[2]) || (!$account_owned && !$broker_owned)
        || $path_stat[3] != 1 || $path_stat[7] > $MAX_BACKUP_BYTES;
    my $file;
    return 0 if !sysopen($file, $path, O_RDONLY | O_NOFOLLOW);
    my @opened = stat($file);
    close($file) or return 0;
    my $opened_account_owned = @opened && $opened[4] == $account->{uid}
        && $opened[5] == $account->{gid} && ($opened[2] & 0777) == 0600;
    my $opened_broker_owned = $allow_broker_owned && @opened && $opened[4] == $self->{expected_owner_uid}
        && $opened[5] == $account->{gid} && ($opened[2] & 0777) == 0640;
    return @opened && $opened[0] == $path_stat[0] && $opened[1] == $path_stat[1]
        && ($opened_account_owned || $opened_broker_owned) && $opened[3] == 1 && $opened[7] == $path_stat[7];
}

sub _install_restore_stage {
    my ($self, $stage, $target, $account, $allow_broker_owned) = @_;
    return 0 if !$self->_restore_target_safe($target, $account, $allow_broker_owned) || !rename($stage, $target);
    return chown($account->{uid}, $account->{gid}, $target) && chmod(0600, $target) ? 1 : -1;
}

sub _ensure_unit_running {
    my ($self, $unit) = @_;
    my (undef, $state) = $self->_systemctl('is-active', $unit);
    return 1 if defined($state) && $state eq 'active';
    my ($started) = $self->_systemctl('start', '--no-block', $unit);
    return $started && $self->_wait_for_unit_state($unit, 'active', $self->{restore_state_timeout}) ? 1 : 0;
}

sub _rollback_restore {
    my ($self, $unit, $rollback_stage, $target, $account) = @_;
    my ($stopped) = $self->_systemctl('stop', '--no-block', $unit);
    return 0 if !$stopped || !$self->_wait_for_unit_state($unit, 'inactive', $self->{restore_state_timeout});
    my $installed = $self->_install_restore_stage($rollback_stage, $target, $account, 1);
    return 0 if $installed != 1;
    my ($started) = $self->_systemctl('start', '--no-block', $unit);
    return $started && $self->_wait_for_unit_state($unit, 'active', $self->{restore_state_timeout}) ? 1 : 0;
}

sub _wait_for_unit_state {
    my ($self, $unit, $expected, $timeout) = @_;
    my $deadline = time + $timeout;
    while (1) {
        my (undef, $state) = $self->_systemctl('is-active', $unit);
        return 1 if defined($state) && $state eq $expected;
        return 0 if time >= $deadline;
        select(undef, undef, undef, 0.1);
    }
}

sub _backup_directory {
    my ($self, $account, $create) = @_;
    return (undef, 'unsafe') if !_valid_account($account) || !$self->_trusted_directory($self->{data_root});
    my $root = File::Spec->catdir($self->{data_root}, '.orm-backups');
    my @root_stat = lstat($root);
    if (!@root_stat) {
        return (undef, 'absent') if !$create;
        return (undef, 'unsafe') if !mkdir($root, 0711)
            || !chown($self->{expected_owner_uid}, $self->{expected_owner_uid}, $root)
            || !chmod(0711, $root);
        @root_stat = lstat($root);
    }
    return (undef, 'unsafe') if !@root_stat || !S_ISDIR($root_stat[2])
        || $root_stat[4] != $self->{expected_owner_uid} || $root_stat[5] != $self->{expected_owner_uid}
        || ($root_stat[2] & 0777) != 0711;

    my $directory = File::Spec->catdir($root, $account->{name});
    my @directory_stat = lstat($directory);
    if (!@directory_stat) {
        return (undef, 'absent') if !$create;
        return (undef, 'unsafe') if !mkdir($directory, 0750)
            || !chown($self->{expected_owner_uid}, $account->{gid}, $directory)
            || !chmod(0750, $directory);
        @directory_stat = lstat($directory);
    }
    return (undef, 'unsafe') if !@directory_stat || !S_ISDIR($directory_stat[2])
        || $directory_stat[4] != $self->{expected_owner_uid} || $directory_stat[5] != $account->{gid}
        || ($directory_stat[2] & 0777) != 0750;
    return ($directory, 'ready');
}

sub _read_backup_entries {
    my ($self, $directory, $account) = @_;
    return undef if !opendir(my $handle, $directory);
    my @names = readdir($handle);
    closedir($handle) or return undef;
    my @entries;
    for my $name (@names) {
        next if $name !~ /\Asnapshot-([0-9]{10})-([a-f0-9]{8})[.]rdb\z/;
        my $created_at = 0 + $1;
        my $path = File::Spec->catfile($directory, $name);
        my @path_stat = lstat($path);
        return undef if !@path_stat || !S_ISREG($path_stat[2])
            || $path_stat[4] != $self->{expected_owner_uid} || $path_stat[5] != $account->{gid}
            || $path_stat[3] != 1 || ($path_stat[2] & 0777) != 0640
            || $path_stat[7] == 0 || $path_stat[7] > $MAX_BACKUP_BYTES || $created_at > time + 300;
        return undef if !sysopen(my $file, $path, O_RDONLY | O_NOFOLLOW);
        my @file_stat = stat($file);
        close($file) or return undef;
        return undef if !@file_stat || $file_stat[0] != $path_stat[0] || $file_stat[1] != $path_stat[1]
            || $file_stat[4] != $self->{expected_owner_uid} || $file_stat[5] != $account->{gid}
            || $file_stat[3] != 1 || ($file_stat[2] & 0777) != 0640
            || $file_stat[7] != $path_stat[7] || $file_stat[7] > $MAX_BACKUP_BYTES;
        push @entries, { created_at => $created_at, id => $name, size_bytes => 0 + $file_stat[7] };
    }
    @entries = sort { $b->{created_at} <=> $a->{created_at} || $b->{id} cmp $a->{id} } @entries;
    return \@entries;
}

sub _run_backup_cli {
    my ($self, $backend, $socket, $destination) = @_;
    return 0 if !defined($backend) || $backend !~ /\A(?:redis|valkey)\z/;
    return 0 if !defined($socket) || ref($socket);
    my ($account_name) = $socket =~ m{\A\Q$self->{data_root}\E/([a-zA-Z0-9_-]{1,16})/redis\.sock\z};
    return 0 if !defined($account_name) || !defined($destination) || ref($destination);
    my ($auth_valid, $auth_secret) = $self->_auth_secret_for_socket($socket);
    return 0 if !$auth_valid;
    my $backup_directory = File::Spec->catdir($self->{data_root}, '.orm-backups', $account_name);
    return 0 if $destination !~ m{\A\Q$backup_directory\E/[.]snapshot-[0-9]+-[a-f0-9]{8}[.]tmp\z};
    if (ref($self->{backup_create}) eq 'CODE') {
        return eval { $self->{backup_create}->($backend, $socket, $destination) } ? 1 : 0;
    }
    my $client_name = $backend eq 'valkey' ? 'valkey' : 'redis';
    my $path;
    for my $candidate (@{$self->{client_paths}->{$client_name} // []}) {
        next if !defined($candidate) || $candidate !~ m{\A/usr/(?:local/)?(?:s?bin)/(?:redis|valkey)-cli\z};
        my @stat = lstat($candidate);
        next if !@stat || !S_ISREG($stat[2]) || $stat[4] != $self->{expected_owner_uid}
            || ($stat[2] & 0022) != 0 || !-x $candidate;
        $path = $candidate;
        last;
    }
    return 0 if !defined($path);

    my $pid = fork();
    return 0 if !defined($pid);
    if ($pid == 0) {
        local %ENV = (PATH => '/usr/bin:/bin', HOME => '/', LANG => 'C', LC_ALL => 'C');
        $ENV{REDISCLI_AUTH} = $auth_secret if defined($auth_secret);
        umask(0077);
        open(STDOUT, '>', '/dev/null') or _exit(127);
        open(STDERR, '>', '/dev/null') or _exit(127);
        exec {$path} $path, '-s', $socket, '--rdb', $destination;
        _exit(127);
    }
    my $deadline = time + $BACKUP_TIMEOUT_SECONDS;
    while (1) {
        my $waited = waitpid($pid, WNOHANG);
        return $? == 0 ? 1 : 0 if $waited == $pid;
        return 0 if $waited == -1;
        my @snapshot_stat = lstat($destination);
        if ((@snapshot_stat && $snapshot_stat[7] > $MAX_BACKUP_BYTES) || time >= $deadline) {
            kill('TERM', $pid);
            my $grace_deadline = time + 1;
            while (time < $grace_deadline && waitpid($pid, WNOHANG) == 0) {
                select(undef, undef, undef, 0.05);
            }
            kill('KILL', $pid) if waitpid($pid, WNOHANG) == 0;
            waitpid($pid, 0);
            return 0;
        }
        select(undef, undef, undef, 0.05);
    }
}

sub _stale_metrics {
    my ($self, $account) = @_;
    my $sample = $self->_read_metrics_snapshot($account);
    return undef if !$sample;
    return {
        %{$sample}, retained => JSON::PP::true,
        stale => JSON::PP::true, success => JSON::PP::true, version => 1,
    };
}

sub _write_metrics_snapshot {
    my ($self, $account, $sample) = @_;
    return 0 if ref($sample) ne 'HASH';
    return 0 if !_valid_metrics({ map { $_ => $sample->{$_} } @METRIC_FIELDS });
    return 0 if !defined($sample->{sampled_at}) || ref($sample->{sampled_at})
        || $sample->{sampled_at} !~ /\A[0-9]{1,10}\z/;
    my $path = File::Spec->catfile($self->_account_config_dir($account->{name}), 'metrics.json');
    my $snapshot = JSON::PP->new->canonical(1)->encode($sample) . "\n";
    return $self->_atomic_write($path, $snapshot, 0600, $self->{expected_owner_uid}, $self->{expected_owner_uid});
}

sub _write_security_metrics_snapshot {
    my ($self, $account, $raw) = @_;
    return 0 if ref($raw) ne 'HASH' || !_is_integer($raw->{sampled_at})
        || $raw->{sampled_at} > 9_999_999_999 || !_is_integer($raw->{uptime_seconds})
        || $raw->{uptime_seconds} > 9_999_999_999;
    my $lock = $self->_metrics_history_lock($account);
    return 0 if !defined($lock);
    my $previous = $self->_read_security_metrics_snapshot($account);
    my $sampledAt = 0 + $raw->{sampled_at};
    if (ref($previous) eq 'HASH' && $sampledAt <= $previous->{sampled_at}) {
        close($lock);
        return 0;
    }

    my $available = _is_integer($raw->{evicted_keys}) && length($raw->{evicted_keys}) <= 15
        && _is_integer($raw->{total_commands_processed}) && length($raw->{total_commands_processed}) <= 15;
    my $authAvailable = _is_integer($raw->{acl_access_denied_auth})
        && length($raw->{acl_access_denied_auth}) <= 15;
    my $snapshot = {
        available => $available ? 1 : 0,
        acl_access_denied_auth => $authAvailable ? 0 + $raw->{acl_access_denied_auth} : undef,
        auth_available => $authAvailable ? 1 : 0,
        auth_failures_delta => undef,
        auth_window_seconds => undef,
        auth_window_start_at => undef,
        evicted_keys => $available ? 0 + $raw->{evicted_keys} : undef,
        evicted_keys_delta => undef,
        sampled_at => $sampledAt,
        total_commands_processed => $available ? 0 + $raw->{total_commands_processed} : undef,
        total_commands_processed_delta => undef,
        uptime_seconds => 0 + $raw->{uptime_seconds},
        version => 2,
        window_seconds => undef,
        window_start_at => undef,
    };
    if ($available && ref($previous) eq 'HASH' && $previous->{available} == 1) {
        my $window = $sampledAt - $previous->{sampled_at};
        my $uptimeDelta = $snapshot->{uptime_seconds} - $previous->{uptime_seconds};
        my $tolerance = int($window / 10);
        $tolerance = 300 if $tolerance < 300;
        if ($window >= 1 && $window <= $MAX_SECURITY_METRICS_AGE_SECONDS
            && $uptimeDelta > 0 && abs($uptimeDelta - $window) <= $tolerance
            && $snapshot->{evicted_keys} >= $previous->{evicted_keys}
            && $snapshot->{total_commands_processed} >= $previous->{total_commands_processed}) {
            $snapshot->{evicted_keys_delta} = $snapshot->{evicted_keys} - $previous->{evicted_keys};
            $snapshot->{total_commands_processed_delta} = $snapshot->{total_commands_processed}
                - $previous->{total_commands_processed};
            $snapshot->{window_seconds} = $window;
            $snapshot->{window_start_at} = $previous->{sampled_at};
        }
    }
    if ($authAvailable && ref($previous) eq 'HASH' && $previous->{auth_available} == 1) {
        my $window = $sampledAt - $previous->{sampled_at};
        my $uptimeDelta = $snapshot->{uptime_seconds} - $previous->{uptime_seconds};
        my $tolerance = int($window / 10);
        $tolerance = 300 if $tolerance < 300;
        if ($window >= 1 && $window <= $MAX_SECURITY_METRICS_AGE_SECONDS
            && $uptimeDelta > 0 && abs($uptimeDelta - $window) <= $tolerance
            && $snapshot->{acl_access_denied_auth} >= $previous->{acl_access_denied_auth}) {
            $snapshot->{auth_failures_delta} = $snapshot->{acl_access_denied_auth}
                - $previous->{acl_access_denied_auth};
            $snapshot->{auth_window_seconds} = $window;
            $snapshot->{auth_window_start_at} = $previous->{sampled_at};
        }
    }

    my $path = File::Spec->catfile($self->_account_config_dir($account->{name}), 'security-metrics.json');
    my $encoded = JSON::PP->new->canonical(1)->encode($snapshot) . "\n";
    my $saved = length($encoded) <= $MAX_SECURITY_METRICS_BYTES
        && $self->_atomic_write($path, $encoded, 0600, $self->{expected_owner_uid}, $self->{expected_owner_uid});
    close($lock);
    return $saved ? 1 : 0;
}

sub _read_security_metrics_snapshot {
    my ($self, $account) = @_;
    return undef if !_valid_account($account);
    my $directory = $self->_account_config_dir($account->{name});
    my @directoryStat = lstat($directory);
    return undef if !@directoryStat || !S_ISDIR($directoryStat[2])
        || $directoryStat[4] != $self->{expected_owner_uid}
        || $directoryStat[5] != $account->{gid} || ($directoryStat[2] & 0027) != 0;
    my $path = File::Spec->catfile($directory, 'security-metrics.json');
    my @pathStat = lstat($path);
    return undef if !@pathStat || !S_ISREG($pathStat[2])
        || $pathStat[4] != $self->{expected_owner_uid} || $pathStat[5] != $self->{expected_owner_uid}
        || $pathStat[3] != 1 || ($pathStat[2] & 0777) != 0600 || $pathStat[7] > $MAX_SECURITY_METRICS_BYTES;
    my $handle;
    return undef if !sysopen($handle, $path, O_RDONLY | O_NOFOLLOW);
    my @opened = stat($handle);
    if (!@opened || $opened[0] != $pathStat[0] || $opened[1] != $pathStat[1]
        || !S_ISREG($opened[2]) || $opened[4] != $self->{expected_owner_uid}
        || $opened[5] != $self->{expected_owner_uid} || $opened[3] != 1
        || ($opened[2] & 0777) != 0600 || $opened[7] > $MAX_SECURITY_METRICS_BYTES) {
        close($handle);
        return undef;
    }
    my $json = '';
    my $read = read($handle, $json, $MAX_SECURITY_METRICS_BYTES + 1);
    my $closed = close($handle);
    return undef if !defined($read) || !$closed || length($json) > $MAX_SECURITY_METRICS_BYTES || $json !~ /\n\z/;
    my $snapshot = eval { JSON::PP->new->decode(substr($json, 0, -1)) };
    return undef if ref($snapshot) ne 'HASH'
        || join(',', sort keys %{$snapshot}) ne join(',', qw(
            acl_access_denied_auth auth_available auth_failures_delta auth_window_seconds auth_window_start_at
            available evicted_keys evicted_keys_delta sampled_at total_commands_processed
            total_commands_processed_delta uptime_seconds version window_seconds window_start_at
        ))
        || !_is_integer($snapshot->{available}) || $snapshot->{available} > 1
        || !_is_integer($snapshot->{auth_available}) || $snapshot->{auth_available} > 1
        || !_is_integer($snapshot->{version}) || $snapshot->{version} != 2
        || !_is_integer($snapshot->{sampled_at}) || $snapshot->{sampled_at} > 9_999_999_999
        || $snapshot->{sampled_at} > time + 300;
    return undef if !_is_integer($snapshot->{uptime_seconds}) || length($snapshot->{uptime_seconds}) > 15;
    if ($snapshot->{available} == 0) {
        return undef if grep { defined($snapshot->{$_}) } qw(
            evicted_keys evicted_keys_delta total_commands_processed total_commands_processed_delta
            window_seconds window_start_at
        );
    } else {
        for my $field (qw(evicted_keys total_commands_processed)) {
            return undef if !_is_integer($snapshot->{$field}) || length($snapshot->{$field}) > 15;
        }
    }
    my @rateFields = qw(evicted_keys_delta total_commands_processed_delta window_seconds window_start_at);
    my $rateFieldCount = scalar grep { defined($snapshot->{$_}) } @rateFields;
    return undef if $rateFieldCount != 0 && $rateFieldCount != @rateFields;
    if ($rateFieldCount) {
        for my $field (@rateFields) {
            return undef if !_is_integer($snapshot->{$field}) || length($snapshot->{$field}) > 15;
        }
        return undef if $snapshot->{window_seconds} < 1
            || $snapshot->{window_seconds} > $MAX_SECURITY_METRICS_AGE_SECONDS
            || $snapshot->{window_start_at} > $snapshot->{sampled_at}
            || $snapshot->{sampled_at} - $snapshot->{window_start_at} != $snapshot->{window_seconds}
            || $snapshot->{evicted_keys_delta} > $snapshot->{evicted_keys}
            || $snapshot->{total_commands_processed_delta} > $snapshot->{total_commands_processed};
    }
    if ($snapshot->{auth_available} == 0) {
        return undef if grep { defined($snapshot->{$_}) } qw(
            acl_access_denied_auth auth_failures_delta auth_window_seconds auth_window_start_at
        );
    } else {
        return undef if !_is_integer($snapshot->{acl_access_denied_auth})
            || length($snapshot->{acl_access_denied_auth}) > 15;
        my @authRateFields = qw(auth_failures_delta auth_window_seconds auth_window_start_at);
        my $authRateFieldCount = scalar grep { defined($snapshot->{$_}) } @authRateFields;
        return undef if $authRateFieldCount != 0 && $authRateFieldCount != @authRateFields;
        if ($authRateFieldCount) {
            for my $field (@authRateFields) {
                return undef if !_is_integer($snapshot->{$field}) || length($snapshot->{$field}) > 15;
            }
            return undef if $snapshot->{auth_window_seconds} < 1
                || $snapshot->{auth_window_seconds} > $MAX_SECURITY_METRICS_AGE_SECONDS
                || $snapshot->{auth_window_start_at} > $snapshot->{sampled_at}
                || $snapshot->{sampled_at} - $snapshot->{auth_window_start_at} != $snapshot->{auth_window_seconds}
                || $snapshot->{auth_failures_delta} > $snapshot->{acl_access_denied_auth};
        }
    }
    return $snapshot;
}

sub _metrics_timer_unit {
    my ($self, $account_name) = @_;
    return 'orm-metrics-collect@' . $account_name . '.timer';
}

sub _ensure_metrics_timer {
    my ($self, $account) = @_;
    return 0 if !_valid_account($account);
    my $unit = $self->_metrics_timer_unit($account->{name});
    my ($active, $state) = $self->_systemctl('is-active', $unit);
    return 1 if $active && $state eq 'active';
    my ($started) = $self->_systemctl('start', $unit);
    ($active, $state) = $self->_systemctl('is-active', $unit) if $started;
    return $started && $active && $state eq 'active' ? 1 : 0;
}

sub _metrics_history_lock {
    my ($self, $account) = @_;
    return undef if !_valid_account($account);
    my $directory = $self->_account_config_dir($account->{name});
    my @directory_stat = lstat($directory);
    return undef if !@directory_stat || !S_ISDIR($directory_stat[2])
        || $directory_stat[4] != $self->{expected_owner_uid}
        || $directory_stat[5] != $account->{gid} || ($directory_stat[2] & 0027) != 0;
    my $path = File::Spec->catfile($directory, 'metrics-history.lock');
    my $lock;
    return undef if !sysopen($lock, $path, O_RDWR | O_CREAT | O_NOFOLLOW, 0600);
    my @path_stat = lstat($path);
    my @file_stat = stat($lock);
    if (!@path_stat || !@file_stat || !S_ISREG($file_stat[2])
        || $file_stat[0] != $path_stat[0] || $file_stat[1] != $path_stat[1]
        || $file_stat[4] != $self->{expected_owner_uid} || $file_stat[5] != $self->{expected_owner_uid}
        || $file_stat[3] != 1 || ($file_stat[2] & 0777) != 0600
        || !flock($lock, LOCK_EX | LOCK_NB)) {
        close($lock);
        return undef;
    }
    return $lock;
}

sub _write_metrics_history {
    my ($self, $account, $sample) = @_;
    return 0 if ref($sample) ne 'HASH'
        || !_valid_metrics({ map { $_ => $sample->{$_} } @METRIC_FIELDS })
        || !defined($sample->{sampled_at}) || ref($sample->{sampled_at})
        || $sample->{sampled_at} !~ /\A[0-9]{1,10}\z/;
    my $lock = $self->_metrics_history_lock($account);
    return 0 if !defined($lock);
    my $history = $self->_read_metrics_history_locked($account);
    if (ref($history) ne 'ARRAY') {
        close($lock);
        return 0;
    }
    my $manifest = $self->_read_manifest($account);
    if (!$manifest) {
        close($lock);
        return 0;
    }
    my $retention_days = $manifest->{version} >= 3
        ? $manifest->{provisioned_defaults}->{metrics_history_retention_days} : 30;
    my $retention_seconds = $retention_days * 24 * 60 * 60;
    my $cutoff = time - $retention_seconds;
    @{$history} = grep { $_->{sampled_at} >= $cutoff } @{$history};
    my %stored = map { $_ => 0 + $sample->{$_} } (@METRIC_FIELDS, 'sampled_at');
    my $bucket = int($stored{sampled_at} / 3600);
    if (@{$history}) {
        my $last_bucket = int($history->[-1]->{sampled_at} / 3600);
        if ($bucket < $last_bucket) {
            # Keep the pruned history even when an out-of-order sample cannot be appended.
        } elsif ($bucket == $last_bucket) {
            $history->[-1] = \%stored;
        } else {
            push @{$history}, \%stored;
        }
    } else {
        push @{$history}, \%stored;
    }
    shift @{$history} while @{$history} > $MAX_METRICS_HISTORY_SAMPLES;
    my $encoded = JSON::PP->new->canonical(1)->encode($history) . "\n";
    my $path = File::Spec->catfile($self->_account_config_dir($account->{name}), 'metrics-history.json');
    my $saved = length($encoded) <= $MAX_METRICS_HISTORY_BYTES
        && $self->_atomic_write($path, $encoded, 0600, $self->{expected_owner_uid}, $self->{expected_owner_uid});
    close($lock);
    return $saved ? 1 : 0;
}

sub _read_metrics_history_locked {
    my ($self, $account) = @_;
    my $path = File::Spec->catfile($self->_account_config_dir($account->{name}), 'metrics-history.json');
    my @path_stat = lstat($path);
    if (!@path_stat) {
        return [] if $! == ENOENT;
        return undef;
    }
    return undef if !S_ISREG($path_stat[2])
        || $path_stat[4] != $self->{expected_owner_uid} || $path_stat[5] != $self->{expected_owner_uid}
        || $path_stat[3] != 1 || ($path_stat[2] & 0777) != 0600
        || $path_stat[7] > $MAX_METRICS_HISTORY_BYTES;
    my $handle;
    return undef if !sysopen($handle, $path, O_RDONLY | O_NOFOLLOW);
    my @opened = stat($handle);
    if (!@opened || $opened[0] != $path_stat[0] || $opened[1] != $path_stat[1]
        || !S_ISREG($opened[2]) || $opened[4] != $self->{expected_owner_uid}
        || $opened[5] != $self->{expected_owner_uid} || $opened[3] != 1
        || ($opened[2] & 0777) != 0600 || $opened[7] > $MAX_METRICS_HISTORY_BYTES) {
        close($handle);
        return undef;
    }
    my $json = '';
    my $read = read($handle, $json, $MAX_METRICS_HISTORY_BYTES + 1);
    my $closed = close($handle);
    return undef if !defined($read) || !$closed || length($json) > $MAX_METRICS_HISTORY_BYTES || $json !~ /\n\z/;
    my $history = eval { JSON::PP->new->decode(substr($json, 0, -1)) };
    return undef if ref($history) ne 'ARRAY' || @{$history} > $MAX_METRICS_HISTORY_SAMPLES;
    my $previous_bucket = -1;
    for my $sample (@{$history}) {
        return undef if ref($sample) ne 'HASH'
            || join(',', sort keys %{$sample}) ne join(',', sort(@METRIC_FIELDS, 'sampled_at'))
            || !_valid_metrics({ map { $_ => $sample->{$_} } @METRIC_FIELDS })
            || !defined($sample->{sampled_at}) || ref($sample->{sampled_at})
            || $sample->{sampled_at} !~ /\A[0-9]{1,10}\z/ || $sample->{sampled_at} > time + 300;
        my $bucket = int($sample->{sampled_at} / 3600);
        return undef if $bucket <= $previous_bucket;
        $previous_bucket = $bucket;
    }
    return $history;
}

sub _read_metrics_snapshot {
    my ($self, $account) = @_;
    my $directory = $self->_account_config_dir($account->{name});
    my @directory_stat = lstat($directory);
    return undef if !@directory_stat || !S_ISDIR($directory_stat[2])
        || $directory_stat[4] != $self->{expected_owner_uid}
        || $directory_stat[5] != $account->{gid} || ($directory_stat[2] & 0027) != 0;
    my $path = File::Spec->catfile($directory, 'metrics.json');
    return undef if !sysopen(my $handle, $path, O_RDONLY | O_NOFOLLOW);
    my @stat = stat($handle);
    if (!@stat || !S_ISREG($stat[2]) || $stat[4] != $self->{expected_owner_uid}
        || $stat[5] != $self->{expected_owner_uid} || $stat[3] != 1
        || ($stat[2] & 0777) != 0600 || $stat[7] > 2048) {
        close($handle);
        return undef;
    }
    my $json = '';
    my $read = read($handle, $json, 2049);
    my $closed = close($handle);
    return undef if !defined($read) || !$closed || length($json) > 2048 || $json !~ /\n\z/;
    my $snapshot = eval { JSON::PP->new->decode(substr($json, 0, -1)) };
    return undef if ref($snapshot) ne 'HASH';
    return undef if join(',', sort keys %{$snapshot}) ne join(',', sort(@METRIC_FIELDS, 'sampled_at'));
    return undef if !_valid_metrics({ map { $_ => $snapshot->{$_} } @METRIC_FIELDS });
    return undef if !defined($snapshot->{sampled_at}) || ref($snapshot->{sampled_at})
        || $snapshot->{sampled_at} !~ /\A[0-9]{1,10}\z/ || $snapshot->{sampled_at} > time + 300;
    if ($snapshot->{sampled_at} < time - $MAX_METRICS_AGE_SECONDS) {
        # This exact root-owned file is expired and no longer useful.
        unlink($path);
        return undef;
    }
    my %result = map { $_ => 0 + $snapshot->{$_} } @METRIC_FIELDS;
    $result{sampled_at} = 0 + $snapshot->{sampled_at};
    return \%result;
}

sub _redis_info {
    my ($self, $backend, $socket) = @_;
    return undef if !defined($backend) || $backend !~ /\A(?:redis|valkey)\z/;
    return undef if !defined($socket) || $socket !~ m{\A/var/lib/orm-instances/[a-zA-Z0-9_-]{1,16}/redis\.sock\z};
    my ($auth_valid, $auth_secret) = $self->_auth_secret_for_socket($socket);
    return undef if !$auth_valid;
    my $client_name = $backend eq 'valkey' ? 'valkey' : 'redis';
    my $path;
    for my $candidate (@{$self->{client_paths}->{$client_name} // []}) {
        next if !defined($candidate) || $candidate !~ m{\A/usr/(?:local/)?(?:s?bin)/(?:redis|valkey)-cli\z};
        my @stat = lstat($candidate);
        next if !@stat || !S_ISREG($stat[2]) || $stat[4] != 0 || ($stat[2] & 0022) != 0 || !-x $candidate;
        $path = $candidate;
        last;
    }
    return undef if !defined($path);

    my ($output, $opened) = ('', 0);
    my $completed = eval {
        local $SIG{ALRM} = sub { die "metrics timeout\n" };
        local %ENV = (PATH => '/usr/bin:/bin', HOME => '/', LANG => 'C', LC_ALL => 'C');
        $ENV{REDISCLI_AUTH} = $auth_secret if defined($auth_secret);
        alarm(3);
        if (open(my $pipe, '-|', $path, '-s', $socket, '--raw', 'INFO')) {
            $opened = 1;
            my $read = read($pipe, $output, $MAX_INFO_BYTES + 1);
            $output = '' if !defined($read) || $read == 0 || $read > $MAX_INFO_BYTES;
            my $closed = close($pipe);
            $opened = 0;
            die "metrics failed\n" if !$closed || $output eq '';
        } else {
            die "metrics unavailable\n";
        }
        alarm(0);
        1;
    };
    alarm(0);
    return undef if !$completed || $opened || $output eq '' || length($output) > $MAX_INFO_BYTES;
    return $output;
}

sub validate_instance_manifest {
    my ($manifest, $username, $uid, $gid, $etc_root, $data_root) = @_;
    return 0 if ref($manifest) ne 'HASH'
        || !defined($username) || $username !~ /\A[a-zA-Z0-9_-]{1,16}\z/
        || !_is_integer($uid) || !_is_integer($gid);

    $etc_root //= '/etc/orm-instances';
    $data_root //= '/var/lib/orm-instances';
    my $config_dir = File::Spec->catdir($etc_root, $username);
    my $data_dir = File::Spec->catdir($data_root, $username);
    my $version = $manifest->{version};
    return 0 if !_is_integer($version);

    my @keys = sort keys %{$manifest};
    if ($version == 1) {
        return 0 if join(',', @keys) ne 'backend,config,data,gid,socket,uid,version';
    } elsif ($version == 2) {
        return 0 if join(',', @keys) ne 'backend,config,data,gid,preset,socket,uid,version'
            || !defined($manifest->{preset}) || ref($manifest->{preset})
            || !exists($PRESET_MEMORY_BYTES{$manifest->{preset}});
    } elsif ($version == 3) {
        return 0 if join(',', @keys) ne 'backend,config,data,gid,preset,provisioned_defaults,socket,uid,version'
            || !defined($manifest->{preset}) || ref($manifest->{preset})
            || !exists($PRESET_MEMORY_BYTES{$manifest->{preset}})
            || !_valid_provisioned_defaults($manifest->{provisioned_defaults});
    } else {
        return 0;
    }

    return 0 if !_is_integer($manifest->{uid}) || $manifest->{uid} != $uid
        || !_is_integer($manifest->{gid}) || $manifest->{gid} != $gid
        || !defined($manifest->{backend}) || ref($manifest->{backend})
        || $manifest->{backend} !~ /\A(?:redis|valkey)\z/
        || !defined($manifest->{config}) || ref($manifest->{config})
        || $manifest->{config} ne File::Spec->catfile($config_dir, 'redis.conf')
        || !defined($manifest->{data}) || ref($manifest->{data}) || $manifest->{data} ne $data_dir
        || !defined($manifest->{socket}) || ref($manifest->{socket})
        || $manifest->{socket} ne File::Spec->catfile($data_dir, 'redis.sock');

    return 1;
}

sub _read_manifest {
    my ($self, $account, $allow_config_drift, $allow_config_recovery, $allow_data_directory_ownership_recovery) = @_;
    return undef if !$self->_trusted_directory($self->{etc_root});
    my $directory = $self->_account_config_dir($account->{name});
    my @dir_stat = lstat($directory);
    return undef if !@dir_stat || !S_ISDIR($dir_stat[2])
        || $dir_stat[4] != $self->{expected_owner_uid}
        || $dir_stat[5] != $account->{gid} || ($dir_stat[2] & 0027) != 0;

    my $path = $self->_manifest_path($account->{name});
    return undef if !sysopen(my $handle, $path, O_RDONLY | O_NOFOLLOW);
    my @stat = stat($handle);
    if (!@stat || !S_ISREG($stat[2]) || $stat[4] != $self->{expected_owner_uid}
        || $stat[5] != $account->{gid} || $stat[3] != 1
        || ($stat[2] & 0037) != 0 || $stat[7] > 4096) {
        close($handle);
        return undef;
    }
    my $json = '';
    my $read = read($handle, $json, 4097);
    my $closed = close($handle);
    return undef if !defined($read) || !$closed || length($json) > 4096;
    my $manifest = eval { JSON::PP->new->decode($json) };
    return undef if !validate_instance_manifest(
        $manifest, $account->{name}, $account->{uid}, $account->{gid}, $self->{etc_root}, $self->{data_root}
    );
    if ($manifest->{version} == 1) {
        $manifest->{preset} = 'generic';
    }
    return undef if !defined($self->_available_binary($manifest->{backend}));
    my ($settings, $auth_secret, $canonical) = $self->_valid_config(
        $account, $manifest, $allow_config_drift, $allow_data_directory_ownership_recovery
    );
    if (!$settings) {
        return undef if !$allow_config_recovery;
        my $reset_kind = $self->_recovery_config_kind($account, $manifest);
        return undef if !defined($reset_kind);
        $manifest->{_recovery_config_reset_kind} = $reset_kind;
        $manifest->{settings} = {
            memory_mib => 8, maxmemory_policy => 'allkeys-lru', maxclients => 10, timeout => 0,
        };
    } else {
        $manifest->{settings} = $settings;
        if ($allow_config_drift) {
            $manifest->{_recovery_config_canonical} = $canonical ? 1 : 0;
            $manifest->{_recovery_auth_secret} = $auth_secret;
        }
    }
    return $manifest;
}

sub _recovery_config_kind {
    my ($self, $account, $manifest) = @_;
    my @data_stat = lstat($manifest->{data});
    return undef if !@data_stat || !S_ISDIR($data_stat[2])
        || $data_stat[4] != $account->{uid} || $data_stat[5] != $account->{gid}
        || ($data_stat[2] & 0077) != 0;
    my @config_stat = lstat($manifest->{config});
    return 'missing' if !@config_stat && $! == ENOENT;
    return undef if !@config_stat || !S_ISREG($config_stat[2])
        || $config_stat[4] != $self->{expected_owner_uid} || $config_stat[5] != $account->{gid}
        || $config_stat[3] != 1 || ($config_stat[2] & 0037) != 0 || $config_stat[7] > 16384;
    return 'malformed';
}

sub _valid_config {
    my ($self, $account, $manifest, $allow_config_drift, $allow_data_directory_ownership_recovery) = @_;
    my $path = $manifest->{config};
    return undef if !sysopen(my $handle, $path, O_RDONLY | O_NOFOLLOW);
    my @stat = stat($handle);
    if (!@stat || !S_ISREG($stat[2]) || $stat[4] != $self->{expected_owner_uid}
        || $stat[5] != $account->{gid} || $stat[3] != 1 || ($stat[2] & 0037) != 0
        || $stat[7] > 16384) {
        close($handle);
        return undef;
    }
    my $content = '';
    my $read = read($handle, $content, 16385);
    close($handle) or return undef;
    return undef if !defined($read) || $read > 16384;
    my @data_stat = lstat($manifest->{data});
    return undef if !@data_stat || !S_ISDIR($data_stat[2]);
    if ($allow_data_directory_ownership_recovery) {
        my @root_stat = lstat($self->{data_root});
        return undef if !@root_stat;
        return undef if ($data_stat[4] != $account->{uid} && $data_stat[4] != $self->{expected_owner_uid})
            || ($data_stat[5] != $account->{gid} && $data_stat[5] != $root_stat[5]);
    } else {
        return undef if $data_stat[4] != $account->{uid} || $data_stat[5] != $account->{gid}
            || ($data_stat[2] & 0077) != 0;
    }
    my ($memory_bytes) = $content =~ /^maxmemory ([0-9]+)$/m;
    my $memory_count = scalar(() = $content =~ /^maxmemory [0-9]+$/mg);
    my ($memory_policy) = $content =~ /^maxmemory-policy ([a-z-]+)$/m;
    my $policy_count = scalar(() = $content =~ /^maxmemory-policy [a-z-]+$/mg);
    my ($database_count) = $content =~ /^databases ([0-9]+)$/m;
    my $database_directive_count = scalar(() = $content =~ /^databases [0-9]+$/mg);
    my ($maxclients) = $content =~ /^maxclients ([0-9]+)$/m;
    my $clients_count = scalar(() = $content =~ /^maxclients [0-9]+$/mg);
    my ($timeout) = $content =~ /^timeout ([0-9]+)$/m;
    my $timeout_count = scalar(() = $content =~ /^timeout [0-9]+$/mg);
    my @auth_secrets = $content =~ /^requirepass ([A-Za-z0-9_-]{43})$/mg;
    my $auth_directive_count = scalar(() = $content =~ /^requirepass(?:[ \t].*)?$/mg);
    return undef if $auth_directive_count > 1 || $auth_directive_count != @auth_secrets;
    return undef if !defined($memory_bytes) || ($memory_count // 0) != 1
        || !defined($memory_policy) || ($policy_count // 0) != 1
        || !defined($database_count) || ($database_directive_count // 0) != 1
        || !defined($maxclients) || ($clients_count // 0) != 1
        || !defined($timeout) || ($timeout_count // 0) != 1;
    return undef if $memory_bytes % (1024 * 1024) != 0;
    my $settings = {
        memory_mib => int($memory_bytes / (1024 * 1024)),
        maxmemory_policy => $memory_policy,
        maxclients => 0 + $maxclients,
        timeout => 0 + $timeout,
    };
    return undef if !_valid_settings($settings);
    return undef if $database_count < 1 || $database_count > 16
        || $database_count != _manifest_database_count($manifest);
    my $auth_secret = @auth_secrets ? $auth_secrets[0] : undef;
    my $canonical = $content eq _redis_config($manifest->{data}, $manifest->{socket}, $settings, $auth_secret, 0 + $database_count);
    return undef if !$canonical && !$allow_config_drift;
    return wantarray ? ($settings, $auth_secret, $canonical) : $settings;
}

sub _available_binary {
    my ($self, $backend) = @_;
    return undef if !defined($backend) || !exists($self->{binary_paths}->{$backend});
    for my $path (@{$self->{binary_paths}->{$backend}}) {
        next if !defined($path) || $path !~ m{\A/usr/(?:local/)?(?:s?bin)/(?:redis|valkey)-server\z};
        my $available;
        if (ref($self->{binary_probe}) eq 'CODE') {
            $available = eval { $self->{binary_probe}->($backend, $path) };
        } else {
            my @stat = lstat($path);
            $available = @stat && S_ISREG($stat[2]) && $stat[4] == 0
                && ($stat[2] & 0022) == 0 && -x $path;
        }
        return $path if $available;
    }
    return undef;
}

sub _systemctl {
    my ($self, @args) = @_;
    return $self->{systemctl_call}->(@args) if ref($self->{systemctl_call}) eq 'CODE';
    return (0, 'unavailable') if $self->{systemctl} ne '/usr/bin/systemctl';
    return (0, 'unavailable') if grep { !defined($_) || ref($_) || $_ =~ /[\r\n\0]/ } @args;
    my ($output, $ok) = ('', 0);
    my $opened = eval {
        local $SIG{ALRM} = sub { die "command timeout\n" };
        alarm(5);
        if (open(my $pipe, '-|', $self->{systemctl}, '--no-pager', @args)) {
            my $read = read($pipe, $output, 129);
            $output = '' if !defined($read) || $read > 128;
            $ok = close($pipe) ? 1 : 0;
        }
        alarm(0);
        1;
    };
    alarm(0);
    return (0, 'unavailable') if !$opened;
    $output =~ s/[\r\n]+\z//;
    return ($ok, $output);
}

sub _atomic_write {
    my ($self, $path, $content, $mode, $uid, $gid) = @_;
    my $temporary = $self->_stage_atomic_write($path, $content, $mode, $uid, $gid);
    return 0 if !defined($temporary);
    return $self->_commit_atomic_write($temporary, $path);
}

sub _stage_atomic_write {
    my ($self, $path, $content, $mode, $uid, $gid) = @_;
    my $temporary = $path . '.tmp-' . $$ . '-' . int(rand(1_000_000));
    return undef if !sysopen(my $handle, $temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    my $ok = ref($self->{atomic_write_call}) eq 'CODE'
        ? eval { $self->{atomic_write_call}->($handle, $content, $path) }
        : print {$handle} $content;
    $ok = 0 if !$ok || !close($handle);
    if ($ok) {
        $ok = chmod($mode, $temporary) && chown($uid, $gid, $temporary);
    }
    if (!$ok) {
        unlink($temporary) if -e $temporary || -l $temporary;
        return undef;
    }
    return $temporary;
}

sub _commit_atomic_write {
    my ($self, $temporary, $path) = @_;
    my $ok = ref($self->{atomic_commit}) eq 'CODE'
        ? eval { $self->{atomic_commit}->($temporary, $path) }
        : rename($temporary, $path);
    return 1 if $ok;
    unlink($temporary) if -e $temporary || -l $temporary;
    return 0;
}

sub _rollback_provision {
    my ($self, $account, $config_dir, $data_dir, $remove_data, $error) = @_;
    unlink($self->_manifest_path($account->{name}));
    unlink(File::Spec->catfile($config_dir, 'redis.conf'));
    rmdir($config_dir);
    if ($remove_data) {
        my @entries = _read_dir($data_dir);
        rmdir($data_dir) if @entries == 0;
    }
    return _failure($error);
}

sub _read_dir {
    my ($path) = @_;
    opendir(my $dir, $path) or return ('.', '..');
    my @entries = grep { $_ ne '.' && $_ ne '..' } readdir($dir);
    closedir($dir);
    return @entries;
}

sub _trusted_directory {
    my ($self, $path) = @_;
    my @stat = lstat($path);
    return 0 if !@stat || !S_ISDIR($stat[2]) || $stat[4] != $self->{expected_owner_uid}
        || ($stat[2] & 0022) != 0;
    return 1;
}

sub _acquire_reseller_quota_lock {
    my ($self) = @_;
    my $path = $self->{quota_lock_path};
    return undef if !defined($path) || ref($path) || $path !~ m{\A/}
        || $path !~ m{\A(/.*)/[^/]+\z};
    my $directory = $1;
    return undef if !$self->_trusted_directory($directory);
    my $handle;
    return undef if !sysopen($handle, $path, O_RDWR | O_CREAT | O_NOFOLLOW, 0600);
    my @file_stat = stat($handle);
    my @path_stat = lstat($path);
    if (!@file_stat || !@path_stat || !S_ISREG($file_stat[2])
        || $file_stat[0] != $path_stat[0] || $file_stat[1] != $path_stat[1]
        || $file_stat[4] != $self->{expected_owner_uid} || $file_stat[3] != 1
        || ($file_stat[2] & 0777) != 0600 || ($path_stat[2] & 0777) != 0600
        || !flock($handle, LOCK_EX)) {
        close($handle);
        return undef;
    }
    return $handle;
}

sub _acquire_instance_lock {
    my ($self, $account) = @_;
    return undef if !_valid_account($account);
    my $directory = $self->_account_config_dir($account->{name});
    my @directory_stat = lstat($directory);
    return undef if !@directory_stat || !S_ISDIR($directory_stat[2])
        || $directory_stat[4] != $self->{expected_owner_uid}
        || $directory_stat[5] != $account->{gid} || ($directory_stat[2] & 0027) != 0;
    my $path = File::Spec->catfile($directory, '.operation.lock');
    my $handle;
    return undef if !sysopen($handle, $path, O_RDWR | O_CREAT | O_NOFOLLOW, 0600);
    my @file_stat = stat($handle);
    my @path_stat = lstat($path);
    if (!@file_stat || !@path_stat || !S_ISREG($file_stat[2])
        || $file_stat[0] != $path_stat[0] || $file_stat[1] != $path_stat[1]
        || $file_stat[4] != $self->{expected_owner_uid} || $file_stat[5] != $self->{expected_owner_uid}
        || $file_stat[3] != 1 || ($file_stat[2] & 0777) != 0600
        || !flock($handle, LOCK_EX | LOCK_NB)) {
        close($handle);
        return undef;
    }
    return $handle;
}

sub _unit_name { return 'orm-instance@' . $_[1] . '.service'; }
sub _manifest_path { return File::Spec->catfile($_[0]->{etc_root}, $_[1], 'manifest.json'); }
sub _account_config_dir { return File::Spec->catdir($_[0]->{etc_root}, $_[1]); }
sub _account_data_dir { return File::Spec->catdir($_[0]->{data_root}, $_[1]); }

sub _preset_settings {
    my ($preset) = @_;
    return {
        memory_mib => int($PRESET_MEMORY_BYTES{$preset} / (1024 * 1024)),
        maxmemory_policy => 'allkeys-lru',
        maxclients => 100,
        timeout => 0,
    };
}

sub _valid_settings {
    my ($settings) = @_;
    return 0 if ref($settings) ne 'HASH';
    return 0 if join(',', sort keys %{$settings}) ne 'maxclients,maxmemory_policy,memory_mib,timeout';
    return 0 if !defined($settings->{memory_mib}) || ref($settings->{memory_mib})
        || $settings->{memory_mib} !~ /\A[0-9]+\z/ || $settings->{memory_mib} < 8 || $settings->{memory_mib} > 64;
    return 0 if !defined($settings->{maxclients}) || ref($settings->{maxclients})
        || $settings->{maxclients} !~ /\A[0-9]+\z/ || $settings->{maxclients} < 10 || $settings->{maxclients} > 100;
    return 0 if !defined($settings->{timeout}) || ref($settings->{timeout})
        || $settings->{timeout} !~ /\A[0-9]+\z/ || $settings->{timeout} > 300;
    return 0 if !defined($settings->{maxmemory_policy}) || ref($settings->{maxmemory_policy})
        || !exists($MAXMEMORY_POLICIES{$settings->{maxmemory_policy}});
    return 1;
}

sub _is_integer {
    my ($value) = @_;
    return defined($value) && !ref($value) && $value =~ /\A(?:0|[1-9][0-9]*)\z/;
}

sub _valid_metrics {
    my ($metrics) = @_;
    return 0 if ref($metrics) ne 'HASH';
    return 0 if join(',', sort keys %{$metrics}) ne join(',', sort @METRIC_FIELDS);
    for my $name (@METRIC_FIELDS) {
        my $value = $metrics->{$name};
        return 0 if !defined($value) || ref($value) || $value !~ /\A[0-9]+\z/ || length($value) > 15;
    }
    return 1;
}

sub _redis_parameter {
    my ($setting, $value) = @_;
    return ('maxmemory', $value * 1024 * 1024) if $setting eq 'memory_mib';
    return ('maxmemory-policy', $value) if $setting eq 'maxmemory_policy';
    return ('maxclients', $value) if $setting eq 'maxclients';
    return ('timeout', $value) if $setting eq 'timeout';
    return;
}

sub _redis_config {
    my ($data, $socket, $settings, $auth_secret, $database_count) = @_;
    $database_count = 16 if !defined($database_count);
    return undef if !_valid_settings($settings);
    return undef if ref($database_count) || $database_count !~ /\A[0-9]+\z/ || $database_count < 1 || $database_count > 16;
    return undef if defined($auth_secret) && !_valid_auth_secret($auth_secret);
    my $memory_bytes = $settings->{memory_mib} * 1024 * 1024;
    return join("\n",
        'daemonize no',
        'supervised no',
        'port 0',
        'protected-mode yes',
        'unixsocket ' . $socket,
        'unixsocketperm 700',
        'pidfile ' . File::Spec->catfile($data, 'redis.pid'),
        'dir ' . $data,
        'dbfilename dump.rdb',
        'save ""',
        'appendonly no',
        'maxmemory ' . $memory_bytes,
        'maxmemory-policy ' . $settings->{maxmemory_policy},
        'databases ' . $database_count,
        'timeout ' . $settings->{timeout},
        'maxclients ' . $settings->{maxclients},
        (defined($auth_secret) ? 'requirepass ' . $auth_secret : ()),
        'logfile ""',
        ''
    );
}

sub _manifest_database_count {
    my ($manifest) = @_;
    return $manifest->{version} >= 3 ? $manifest->{provisioned_defaults}->{databases} : 16;
}

sub _valid_provisioned_defaults {
    my ($defaults) = @_;
    return 0 if ref($defaults) ne 'HASH'
        || join(',', sort keys %{$defaults}) ne 'backup_retention,databases,metrics_history_retention_days'
        || !_is_integer($defaults->{backup_retention}) || $defaults->{backup_retention} < 2 || $defaults->{backup_retention} > 3
        || !_is_integer($defaults->{databases}) || $defaults->{databases} < 1 || $defaults->{databases} > 16
        || !_is_integer($defaults->{metrics_history_retention_days})
        || $defaults->{metrics_history_retention_days} < 7 || $defaults->{metrics_history_retention_days} > 90;
    return 1;
}

sub _valid_auth_secret {
    my ($secret) = @_;
    return defined($secret) && !ref($secret) && $secret =~ /\A[A-Za-z0-9_-]{43}\z/ ? 1 : 0;
}

sub _generate_auth_secret {
    my $source;
    return undef if !sysopen($source, '/dev/urandom', O_RDONLY);
    my $bytes = '';
    my $read = read($source, $bytes, 32);
    my $closed = close($source);
    return undef if !defined($read) || $read != 32 || !$closed;
    my $secret = encode_base64($bytes, '');
    $secret =~ tr{+/}{-_};
    $secret =~ s/=+\z//;
    return _valid_auth_secret($secret) ? $secret : undef;
}

sub _valid_account {
    my ($account) = @_;
    return 0 if !defined($account->{name}) || $account->{name} !~ /\A[a-zA-Z0-9_-]{1,16}\z/;
    return 0 if !defined($account->{uid}) || $account->{uid} !~ /\A[0-9]+\z/ || $account->{uid} == 0;
    return 0 if !defined($account->{gid}) || $account->{gid} !~ /\A[0-9]+\z/;
    return 1;
}

sub _state {
    my ($state, $manifest) = @_;
    return { success => JSON::PP::true, state => $state, version => 1,
        (ref($manifest) eq 'HASH' ? (
            preset => $manifest->{preset},
            config => $manifest->{settings},
        ) : ()) };
}
sub _failure { return { error => $_[0], success => JSON::PP::false, version => 1 }; }

1;
