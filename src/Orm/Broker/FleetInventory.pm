package Orm::Broker::FleetInventory;
use strict;
use warnings;
use Fcntl qw(:mode);
use JSON::PP ();
use Sys::Syslog qw(:standard :macros);

# Status checks use systemctl with a five-second timeout; four checks stay below the 35-second WHM client timeout.
my $PAGE_SIZE = 4;
my $MAX_METADATA_ENTRIES = 10_000;
my $MAX_BACKUPS_PER_ACCOUNT = 3;
my $MAX_BACKUP_BYTES = 134_217_728;

sub new {
    my ($class, %args) = @_;
    return bless {
        instance_root => $args{instance_root} // '/etc/orm-instances',
        expected_owner_uid => defined($args{expected_owner_uid}) ? $args{expected_owner_uid} : 0,
        resolver => $args{resolver},
        instance_manager => $args{instance_manager},
        lookup_name => $args{lookup_name} // sub {
            my @entry = getpwnam($_[0]);
            return undef if !@entry || !defined($entry[2]);
            return { uid => 0 + $entry[2] };
        },
        read_names => $args{read_names},
        audit => $args{audit},
    }, $class;
}

sub control {
    my ($self, $username, $action) = @_;
    return _failure('invalid_request') if !defined($username) || ref($username)
        || $username !~ /\A[a-zA-Z0-9_-]{1,16}\z/ || !defined($action) || ref($action)
        || $action !~ /\A(?:start|stop|restart)\z/;

    my $account = eval { $self->{resolver}->resolve_name($username) };
    if (ref($account) ne 'HASH' || $account->{name} ne $username) {
        my $audited = _audit_control($self, $username, $action, 'account_unavailable');
        return _failure('account_unavailable', $audited);
    }
    my $status = eval { $self->{instance_manager}->status($account) };
    if (ref($status) ne 'HASH' || !$status->{success}) {
        my $audited = _audit_control($self, $username, $action, 'instance_unavailable', 'unavailable');
        return _failure('instance_unavailable', $audited);
    }
    if ($status->{state} eq 'not_configured') {
        my $audited = _audit_control($self, $username, $action, 'not_configured', $status->{state});
        return _failure('not_configured', $audited);
    }
    if ($action eq 'restart' && $status->{state} ne 'running' && $status->{state} ne 'starting') {
        my $audited = _audit_control($self, $username, $action, 'instance_unavailable', $status->{state});
        return _failure('instance_unavailable', $audited);
    }

    my $result = eval { $self->{instance_manager}->$action($account) };
    if (ref($result) ne 'HASH' || !$result->{success}
        || !defined($result->{state}) || $result->{state} !~ /\A(?:stopped|starting|running|stopping|failed)\z/) {
        my $error = ref($result) eq 'HASH' && defined($result->{error})
            && $result->{error} =~ /\A(?:service_failed|instance_unavailable|not_configured)\z/
            ? $result->{error} : 'service_failed';
        my $audited = _audit_control($self, $username, $action, $error, 'unavailable');
        return _failure($error, $audited);
    }
    my $audited = _audit_control($self, $username, $action, 'success', $result->{state});
    return {
        action => $action,
        audit_logged => $audited ? JSON::PP::true : JSON::PP::false,
        state => $result->{state},
        success => JSON::PP::true,
        username => $username,
        version => 1,
    };
}

sub backup {
    my ($self, $username, $action, $backup_id) = @_;
    return _failure('invalid_request') if !defined($username) || ref($username)
        || $username !~ /\A[a-zA-Z0-9_-]{1,16}\z/ || !defined($action) || ref($action)
        || $action !~ /\A(?:backup\.create|backup\.restore)\z/
        || ($action eq 'backup.create' && defined($backup_id))
        || ($action eq 'backup.restore' && (!defined($backup_id) || ref($backup_id)
            || $backup_id !~ /\Asnapshot-[0-9]{10}-[a-f0-9]{8}[.]rdb\z/));

    my $account = eval { $self->{resolver}->resolve_name($username) };
    if (ref($account) ne 'HASH' || $account->{name} ne $username) {
        my $audited = _audit_event($self, 0, $username, $action, 'account_unavailable', 'unavailable');
        return _fleet_failure('account_unavailable', $username, $action, $audited);
    }

    my $manager = $self->{instance_manager};
    my $method = $action eq 'backup.create' ? 'create_backup' : 'restore_backup';
    my $result = eval { $manager->$method($account, $backup_id) }
        if defined($manager) && eval { $manager->can($method) };
    if (ref($result) ne 'HASH') {
        my $audited = _audit_event($self, 0, $username, $action, 'operation_failed', 'unavailable');
        return _fleet_failure('operation_failed', $username, $action, $audited);
    }

    if ($result->{success}) {
        my %response = (
            action => $action,
            username => $username,
            success => JSON::PP::true,
            version => 1,
        );
        if ($action eq 'backup.create') {
            my $backup = $result->{backup};
            if (!_valid_backup_entry($backup)) {
                my $audited = _audit_event($self, 0, $username, $action, 'operation_failed', 'unavailable');
                return _fleet_failure('operation_failed', $username, $action, $audited);
            }
            $response{backup} = {
                id => $backup->{id},
                created_at => 0 + $backup->{created_at},
                size_bytes => 0 + $backup->{size_bytes},
            };
        } else {
            if (!defined($result->{backup_id}) || $result->{backup_id} ne $backup_id
                || !_valid_backup_id($result->{safety_backup_id}) || ($result->{state} // '') ne 'running') {
                my $audited = _audit_event($self, 0, $username, $action, 'operation_failed', 'unavailable');
                return _fleet_failure('operation_failed', $username, $action, $audited);
            }
            $response{backup_id} = $backup_id;
            $response{safety_backup_id} = $result->{safety_backup_id};
            $response{state} = 'running';
        }
        my $audited = _audit_event($self, 0, $username, $action, 'success', 'running');
        $response{audit_logged} = $audited ? JSON::PP::true : JSON::PP::false;
        return \%response;
    }

    my $error = defined($result->{error}) && !ref($result->{error})
        && $result->{error} =~ /\A(?:invalid_request|operation_failed|not_configured|not_running|backup_not_found|backup_failed|backup_invalid|backup_in_progress|backup_retention_failed|backup_storage_unavailable|restore_validation_unavailable|restore_failed|restore_rollback_failed|rate_limited)\z/
        ? $result->{error} : 'operation_failed';
    my $safety_id = _valid_backup_id($result->{safety_backup_id}) ? $result->{safety_backup_id} : undef;
    my $audited = _audit_event($self, 0, $username, $action, $error, 'unavailable');
    return _fleet_failure($error, $username, $action, $audited, $safety_id);
}

sub diagnostics {
    my ($self, $username) = @_;
    my $action = 'diagnostics.read';
    return _fleet_failure('invalid_request', $username, $action, 0)
        if !defined($username) || ref($username) || $username !~ /\A[a-zA-Z0-9_-]{1,16}\z/;

    my $account = eval { $self->{resolver}->resolve_name($username) };
    if (ref($account) ne 'HASH' || $account->{name} ne $username) {
        my $audited = _audit_event($self, 0, $username, $action, 'account_unavailable', 'unavailable');
        return _fleet_failure('account_unavailable', $username, $action, $audited);
    }

    my $result = eval { $self->{instance_manager}->read_diagnostics($account) }
        if defined($self->{instance_manager}) && eval { $self->{instance_manager}->can('read_diagnostics') };
    if (ref($result) ne 'HASH') {
        my $audited = _audit_event($self, 0, $username, $action, 'diagnostics_unavailable', 'unavailable');
        return _fleet_failure('diagnostics_unavailable', $username, $action, $audited);
    }
    if ($result->{success}) {
        if (($result->{state} // '') ne 'running' || !_valid_diagnostics($result->{diagnostics})) {
            my $audited = _audit_event($self, 0, $username, $action, 'operation_failed', 'unavailable');
            return _fleet_failure('operation_failed', $username, $action, $audited);
        }
        my $audited = _audit_event($self, 0, $username, $action, 'success', 'running');
        return {
            action => $action,
            audit_logged => $audited ? JSON::PP::true : JSON::PP::false,
            diagnostics => $result->{diagnostics},
            state => 'running',
            success => JSON::PP::true,
            username => $username,
            version => 1,
        };
    }

    my $error = defined($result->{error}) && !ref($result->{error})
        && $result->{error} =~ /\A(?:not_configured|not_running|diagnostics_unavailable|rate_limited)\z/
        ? $result->{error} : 'operation_failed';
    my $audited = _audit_event($self, 0, $username, $action, $error, 'unavailable');
    return _fleet_failure($error, $username, $action, $audited);
}

sub migrate {
    my ($self, $username, $target_backend, $writes_quiesced) = @_;
    my $action = 'migration.to-valkey';
    return _fleet_failure('invalid_request', $username, $action, 0)
        if !defined($username) || ref($username) || $username !~ /\A[a-zA-Z0-9_-]{1,16}\z/
        || !defined($target_backend) || ref($target_backend) || $target_backend ne 'valkey'
        || !defined($writes_quiesced) || ref($writes_quiesced) || !$writes_quiesced;

    my $account = eval { $self->{resolver}->resolve_name($username) };
    if (ref($account) ne 'HASH' || $account->{name} ne $username) {
        my $audited = _audit_event($self, 0, $username, $action, 'account_unavailable', 'unavailable');
        return _fleet_failure('account_unavailable', $username, $action, $audited);
    }

    my $manager = $self->{instance_manager};
    my $result = eval { $manager->migrate_to_valkey($account) }
        if defined($manager) && eval { $manager->can('migrate_to_valkey') };
    if (ref($result) ne 'HASH') {
        my $audited = _audit_event($self, 0, $username, $action, 'operation_failed', 'unavailable');
        return _fleet_failure('operation_failed', $username, $action, $audited);
    }

    if ($result->{success}) {
        my $backup_id = _valid_backup_id($result->{backup_id}) ? $result->{backup_id} : undef;
        if (!defined($backup_id) || ($result->{source_backend} // '') ne 'redis'
            || ($result->{target_backend} // '') ne 'valkey' || ($result->{state} // '') ne 'running') {
            my $audited = _audit_event($self, 0, $username, $action, 'operation_failed', 'unavailable');
            return _fleet_failure('operation_failed', $username, $action, $audited);
        }
        my $audited = _audit_event($self, 0, $username, $action, 'success', 'running');
        return {
            action => $action,
            audit_logged => $audited ? JSON::PP::true : JSON::PP::false,
            safety_backup_id => $backup_id,
            source_backend => 'redis',
            state => 'running',
            success => JSON::PP::true,
            target_backend => 'valkey',
            username => $username,
            version => 1,
        };
    }

    my %allowed_errors = map { $_ => 1 } qw(
        account_unavailable backend_unavailable backup_storage_unavailable invalid_request
        migration_failed migration_pause_failed migration_recovery_required migration_rollback_failed
        migration_state_unavailable migration_timeout migration_unsupported migration_validation_failed
        migration_validation_unavailable migration_snapshot_failed not_configured not_running
        operation_in_progress rate_limited
    );
    my $error = defined($result->{error}) && !ref($result->{error}) && $allowed_errors{$result->{error}}
        ? $result->{error} : 'operation_failed';
    my $safety_id = _valid_backup_id($result->{safety_backup_id}) ? $result->{safety_backup_id} : undef;
    my $audited = _audit_event($self, 0, $username, $action, $error, 'unavailable');
    return _fleet_failure($error, $username, $action, $audited, $safety_id);
}

sub page {
    my ($self, $offset) = @_;
    return _failure('invalid_request') if !defined($offset) || ref($offset)
        || $offset !~ /\A(?:0|[1-9][0-9]{0,5})\z/;
    return _failure('operation_failed') if !eval { $self->{resolver}->can('resolve_account') }
        || !eval { $self->{instance_manager}->can('status') }
        || !eval { $self->{instance_manager}->can('backups') };

    my @root_stat = lstat($self->{instance_root});
    return _failure('operation_failed') if !@root_stat || !S_ISDIR($root_stat[2])
        || $root_stat[4] != $self->{expected_owner_uid} || ($root_stat[2] & 0022) != 0;

    my @names;
    if (ref($self->{read_names}) eq 'CODE') {
        @names = eval { $self->{read_names}->($self->{instance_root}) };
        return _failure('operation_failed') if $@;
    } else {
        opendir(my $directory, $self->{instance_root}) or return _failure('operation_failed');
        while (my $name = readdir($directory)) {
            next if $name eq '.' || $name eq '..';
            push @names, $name;
            if (@names > $MAX_METADATA_ENTRIES) {
                closedir($directory);
                return _failure('operation_failed');
            }
        }
        closedir($directory) or return _failure('operation_failed');
    }
    return _failure('operation_failed') if @names > $MAX_METADATA_ENTRIES;

    my @accounts;
    for my $name (@names) {
        next if !defined($name) || ref($name) || $name !~ /\A[a-zA-Z0-9_-]{1,16}\z/;
        my @directory_stat = lstat("$self->{instance_root}/$name");
        next if !@directory_stat || !S_ISDIR($directory_stat[2])
            || $directory_stat[4] != $self->{expected_owner_uid} || ($directory_stat[2] & 0027) != 0;

        my $identity = eval { $self->{lookup_name}->($name) };
        next if ref($identity) ne 'HASH' || !defined($identity->{uid})
            || ref($identity->{uid}) || $identity->{uid} !~ /\A[1-9][0-9]*\z/;
        my $account = eval { $self->{resolver}->resolve_account($identity->{uid}) };
        next if ref($account) ne 'HASH' || $account->{name} ne $name || $account->{uid} != $identity->{uid};

        push @accounts, { account => $account, username => $name };
    }

    @accounts = sort { $a->{username} cmp $b->{username} } @accounts;
    my $total = scalar @accounts;
    return _failure('invalid_request') if $offset > $total;
    my $end = $offset + $PAGE_SIZE;
    $end = $total if $end > $total;
    my @page;
    if ($offset < $end) {
        for my $candidate (@accounts[$offset .. $end - 1]) {
            my $status = eval { $self->{instance_manager}->status($candidate->{account}) };
            my $state = ref($status) eq 'HASH' && $status->{success}
                ? $status->{state} : 'unhealthy';
            $state = 'unhealthy' if !defined($state)
                || $state !~ /\A(?:stopped|starting|running|stopping|failed)\z/;
            my $backend = eval { $self->{instance_manager}->backend($candidate->{account}) };
            $backend = 'unknown' if !defined($backend) || ref($backend) || $backend !~ /\A(?:redis|valkey)\z/;
            my $backup_response = eval { $self->{instance_manager}->backups($candidate->{account}) };
            my @backups;
            my $backups_available = 0;
            if (ref($backup_response) eq 'HASH' && $backup_response->{success}
                && ref($backup_response->{backups}) eq 'ARRAY'
                && @{$backup_response->{backups}} <= $MAX_BACKUPS_PER_ACCOUNT) {
                $backups_available = 1;
                for my $backup (@{$backup_response->{backups}}) {
                    if (!_valid_backup_entry($backup)) {
                        $backups_available = 0;
                        @backups = ();
                        last;
                    }
                    push @backups, {
                        id => $backup->{id},
                        created_at => 0 + $backup->{created_at},
                        size_bytes => 0 + $backup->{size_bytes},
                    };
                }
            } else {
                $backups_available = 0;
            }
            push @page, {
                backups => \@backups,
                backups_available => $backups_available ? JSON::PP::true : JSON::PP::false,
                backend => $backend,
                username => $candidate->{username},
                state => $state,
            };
        }
    }
    return {
        entries => \@page,
        offset => 0 + $offset,
        success => JSON::PP::true,
        total => $total,
        version => 1,
    };
}

sub _failure {
    my ($error, $audited) = @_;
    my $response = { error => $error, success => JSON::PP::false, version => 1 };
    $response->{audit_logged} = $audited ? JSON::PP::true : JSON::PP::false if defined($audited);
    return $response;
}

sub _fleet_failure {
    my ($error, $username, $action, $audited, $safety_backup_id) = @_;
    my $response = {
        action => $action,
        audit_logged => $audited ? JSON::PP::true : JSON::PP::false,
        error => $error,
        success => JSON::PP::false,
        username => $username,
        version => 1,
    };
    $response->{safety_backup_id} = $safety_backup_id if defined($safety_backup_id);
    return $response;
}

sub _valid_backup_id {
    my ($backup_id) = @_;
    return defined($backup_id) && !ref($backup_id)
        && $backup_id =~ /\Asnapshot-([0-9]{10})-[a-f0-9]{8}[.]rdb\z/;
}

sub _valid_backup_entry {
    my ($backup) = @_;
    return 0 if ref($backup) ne 'HASH' || !_valid_backup_id($backup->{id});
    return 0 if !defined($backup->{created_at}) || ref($backup->{created_at})
        || $backup->{created_at} !~ /\A[0-9]{10}\z/;
    return 0 if $backup->{created_at} != substr($backup->{id}, 9, 10);
    return 0 if !defined($backup->{size_bytes}) || ref($backup->{size_bytes})
        || $backup->{size_bytes} !~ /\A[1-9][0-9]*\z/ || $backup->{size_bytes} > $MAX_BACKUP_BYTES;
    return 1;
}

sub _audit_control {
    my ($self, $username, $action, $outcome, $state) = @_;
    return _audit_event($self, 0, $username, $action, $outcome, $state);
}

sub _audit_event {
    my ($self, $peer_uid, $username, $action, $outcome, $state) = @_;
    $peer_uid = 0 if !defined($peer_uid) || ref($peer_uid) || $peer_uid !~ /\A[0-9]{1,10}\z/;
    $state = 'unavailable' if !defined($state) || $state !~ /\A(?:stopped|starting|running|stopping|failed|unavailable)\z/;
    if (ref($self->{audit}) eq 'CODE') {
        my $recorded = eval { $self->{audit}->($peer_uid, $username, $action, $outcome, $state) };
        return $recorded ? 1 : 0;
    }
    my $recorded = eval {
        openlog('orm-broker', 'pid', 'authpriv');
        syslog(LOG_NOTICE, 'fleet_operation actor_uid=%s account=%s action=%s result=%s state=%s', $peer_uid, $username, $action, $outcome, $state)
            or die "syslog write failed";
        closelog();
        1;
    };
    eval { closelog(); };
    return $recorded ? 1 : 0;
}

sub audit_denial {
    my ($self, $peer_uid, $username, $action) = @_;
    $peer_uid = 'unknown' if !defined($peer_uid) || ref($peer_uid) || $peer_uid !~ /\A[0-9]{1,10}\z/;
    $username = 'invalid' if !defined($username) || ref($username) || $username !~ /\A[a-zA-Z0-9_-]{1,16}\z/;
    $action = 'invalid' if !defined($action) || ref($action)
        || $action !~ /\A(?:start|stop|restart|backup\.create|backup\.restore|migration\.to-valkey|diagnostics\.read)\z/;
    return _audit_event($self, $peer_uid, $username, $action, 'not_authorized', 'unavailable');
}

sub _valid_diagnostics {
    my ($diagnostics) = @_;
    my $max_integer = 9_000_000_000_000_000;
    return 0 if ref($diagnostics) ne 'HASH';
    my @expected = qw(
        backend blocked_clients commands_per_second connected_clients database_keys
        evicted_keys expired_keys keyspace_hits keyspace_misses maxclients maxmemory_bytes
        memory_peak_bytes memory_used_bytes server_version uptime_seconds
    );
    return 0 if join(',', sort keys %{$diagnostics}) ne join(',', @expected);
    return 0 if !defined($diagnostics->{backend}) || $diagnostics->{backend} !~ /\A(?:redis|valkey)\z/;
    return 0 if !defined($diagnostics->{server_version}) || $diagnostics->{server_version} !~ /\A[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}(?:[-+][A-Za-z0-9.-]{1,24})?\z/;
    for my $field (@expected) {
        next if $field eq 'backend' || $field eq 'server_version';
        return 0 if !defined($diagnostics->{$field}) || ref($diagnostics->{$field})
            || $diagnostics->{$field} !~ /\A(?:0|[1-9][0-9]{0,15})\z/
            || $diagnostics->{$field} > $max_integer;
    }
    return 0 if $diagnostics->{memory_peak_bytes} < $diagnostics->{memory_used_bytes}
        || $diagnostics->{connected_clients} > $diagnostics->{maxclients}
        || $diagnostics->{maxclients} > 100000;
    return 1;
}

1;
