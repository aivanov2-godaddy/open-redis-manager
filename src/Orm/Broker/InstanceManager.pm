package Orm::Broker::InstanceManager;
use strict;
use warnings;
use Errno qw(ENOENT);
use Fcntl qw(O_RDONLY O_WRONLY O_RDWR O_CREAT O_EXCL O_NOFOLLOW :mode :flock);
use File::Spec;
use JSON::PP ();
use POSIX qw(WNOHANG _exit setgid setuid);
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
my $MAX_METRICS_AGE_SECONDS = 30 * 24 * 60 * 60;
my $MAX_METRICS_HISTORY_SAMPLES = 720;
my $MAX_METRICS_HISTORY_BYTES = 262144;
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
        systemctl => $args{systemctl} // '/usr/bin/systemctl',
        systemctl_call => $args{systemctl_call},
        binary_paths => $args{binary_paths} // \%SERVER_BINARIES,
        binary_probe => $args{binary_probe},
        client_paths => $args{client_paths} // \%CLIENT_BINARIES,
        rdb_check_paths => $args{rdb_check_paths} // \%RDB_CHECK_BINARIES,
        rdb_check => $args{rdb_check},
        restore_audit => $args{restore_audit},
        restore_state_timeout => defined($args{restore_state_timeout}) ? $args{restore_state_timeout} : 20,
        metrics_probe => $args{metrics_probe},
        redis_cli_call => $args{redis_cli_call},
        config_get => $args{config_get},
        config_set => $args{config_set},
        backup_create => $args{backup_create},
        atomic_commit => $args{atomic_commit},
    }, $class;
}

sub dispatch {
    my ($self, $operation, $account, $preset, $settings, $backup_id, $metrics_range) = @_;
    return _failure('not_authorized') if ref($account) ne 'HASH';
    return _failure('invalid_request') if !_valid_account($account);

    return $self->status($account) if $operation eq 'instance.status';
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
    return _failure('instance_unavailable') if !$ok && $state ne 'inactive' && $state ne 'failed';
    return _state('running', $manifest) if $state eq 'active';
    return _state('starting', $manifest) if $state eq 'activating' || $state eq 'reloading';
    return _state('stopping', $manifest) if $state eq 'deactivating';
    return _state('failed', $manifest) if $state eq 'failed';
    return _state('stopped', $manifest) if $state eq 'inactive';
    return _failure('instance_unavailable');
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
    my $memory_bytes = $settings->{memory_mib} * 1024 * 1024;
    return _failure('invalid_request') if $memory_bytes > $MAX_MEMORY_BYTES;
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
        version => 2,
    };
    my $manifest_json = JSON::PP->new->canonical(1)->encode($manifest) . "\n";
    my $config = _redis_config($data_dir, $socket, $settings);
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

sub configure {
    my ($self, $account, $settings) = @_;
    return _failure('invalid_request') if !_valid_settings($settings);
    my $provider_decision = $self->{provider_policy}->memory_decision($account, $settings->{memory_mib});
    return _failure('provider_policy_unavailable') if ref($provider_decision) ne 'HASH';
    return _failure('provider_policy_denied') if !$provider_decision->{allowed};
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

    my $config = _redis_config($manifest->{data}, $manifest->{socket}, $settings);
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
    if (ref($self->{redis_cli_call}) eq 'CODE') {
        my $output = eval { $self->{redis_cli_call}->($backend, $socket, @arguments) };
        return undef if !$output || ref($output) || length($output) > 1024;
        return $output;
    }
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
        alarm(3);
        if (open(my $pipe, '-|', $path, '-s', $socket, '--raw', @arguments)) {
            $opened = 1;
            my $read = read($pipe, $output, 1025);
            $output = '' if !defined($read) || $read == 0 || $read > 1024;
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
    return undef if !$completed || $opened || $output eq '' || length($output) > 1024;
    return $output;
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
    my $retention_limit = $effective_policy->{mode} eq 'enforce'
        ? $effective_policy->{backup_retention} : $MAX_BACKUPS_PER_ACCOUNT;
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
    my $cutoff = time - $MAX_METRICS_AGE_SECONDS;
    @{$history} = grep { $_->{sampled_at} >= $cutoff } @{$history};
    my %stored = map { $_ => 0 + $sample->{$_} } (@METRIC_FIELDS, 'sampled_at');
    my $bucket = int($stored{sampled_at} / 3600);
    if (@{$history}) {
        my $last_bucket = int($history->[-1]->{sampled_at} / 3600);
        if ($bucket < $last_bucket) {
            close($lock);
            return 1;
        }
        if ($bucket == $last_bucket) {
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

sub _read_manifest {
    my ($self, $account) = @_;
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
    return undef if ref($manifest) ne 'HASH';
    my @keys = sort keys %{$manifest};
    my $manifest_version = $manifest->{version} // 0;
    if ($manifest_version == 1) {
        return undef if join(',', @keys) ne 'backend,config,data,gid,socket,uid,version';
        $manifest->{preset} = 'generic';
    } elsif ($manifest_version == 2) {
        return undef if join(',', @keys) ne 'backend,config,data,gid,preset,socket,uid,version';
        return undef if !defined($manifest->{preset}) || ref($manifest->{preset})
            || !exists($PRESET_MEMORY_BYTES{$manifest->{preset}});
    } else {
        return undef;
    }
    return undef if ($manifest->{uid} // -1) != $account->{uid}
        || ($manifest->{gid} // -1) != $account->{gid};
    return undef if !defined($manifest->{backend}) || $manifest->{backend} !~ /\A(?:redis|valkey)\z/;
    my $expected_data = $self->_account_data_dir($account->{name});
    my $expected_config = File::Spec->catfile($self->_account_config_dir($account->{name}), 'redis.conf');
    my $expected_socket = File::Spec->catfile($expected_data, 'redis.sock');
    return undef if $manifest->{data} ne $expected_data
        || $manifest->{config} ne $expected_config || $manifest->{socket} ne $expected_socket;
    return undef if !defined($self->_available_binary($manifest->{backend}));
    my $settings = $self->_valid_config($account, $manifest);
    return undef if !$settings;
    $manifest->{settings} = $settings;
    return $manifest;
}

sub _valid_config {
    my ($self, $account, $manifest) = @_;
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
    return undef if !@data_stat || !S_ISDIR($data_stat[2])
        || $data_stat[4] != $account->{uid} || $data_stat[5] != $account->{gid}
        || ($data_stat[2] & 0077) != 0;
    my ($memory_bytes) = $content =~ /^maxmemory ([0-9]+)$/m;
    my $memory_count = scalar(() = $content =~ /^maxmemory [0-9]+$/mg);
    my ($memory_policy) = $content =~ /^maxmemory-policy ([a-z-]+)$/m;
    my $policy_count = scalar(() = $content =~ /^maxmemory-policy [a-z-]+$/mg);
    my ($maxclients) = $content =~ /^maxclients ([0-9]+)$/m;
    my $clients_count = scalar(() = $content =~ /^maxclients [0-9]+$/mg);
    my ($timeout) = $content =~ /^timeout ([0-9]+)$/m;
    my $timeout_count = scalar(() = $content =~ /^timeout [0-9]+$/mg);
    return undef if !defined($memory_bytes) || ($memory_count // 0) != 1
        || !defined($memory_policy) || ($policy_count // 0) != 1
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
    return undef if $content ne _redis_config($manifest->{data}, $manifest->{socket}, $settings);
    return $settings;
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
    my $ok = print {$handle} $content;
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
    my ($data, $socket, $settings) = @_;
    return undef if !_valid_settings($settings);
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
        'databases 16',
        'timeout ' . $settings->{timeout},
        'maxclients ' . $settings->{maxclients},
        'logfile ""',
        ''
    );
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
