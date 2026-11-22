package Orm::Broker::FleetInventory;
use strict;
use warnings;
use Fcntl qw(:mode);
use JSON::PP ();
use Sys::Syslog qw(:standard :macros);
use Orm::Broker::PodmanMetricsCollector;

# Status checks use systemctl with a five-second timeout; four checks stay below the 35-second WHM client timeout.
my $PAGE_SIZE = 4;
my $MAX_METADATA_ENTRIES = 10_000;
my $MAX_BACKUPS_PER_ACCOUNT = 3;
my $MAX_BACKUP_BATCH_TARGETS = 2;
my $BACKUP_BATCH_COOLDOWN_SECONDS = 5;
my $BACKUP_ACCOUNT_COOLDOWN_SECONDS = 60;
my $MAX_BACKUP_BYTES = 134_217_728;

sub new {
    my ($class, %args) = @_;
    return bless {
        instance_root => $args{instance_root} // '/etc/orm-instances',
        expected_owner_uid => defined($args{expected_owner_uid}) ? $args{expected_owner_uid} : 0,
        resolver => $args{resolver},
        instance_manager => $args{instance_manager},
        podman_snapshot_path => $args{podman_snapshot_path} // '/var/lib/orm-podman/summary.json',
        lookup_name => $args{lookup_name} // sub {
            my @entry = getpwnam($_[0]);
            return undef if !@entry || !defined($entry[2]);
            return { uid => 0 + $entry[2] };
        },
        read_names => $args{read_names},
        audit => $args{audit},
        clock => $args{clock} // sub { time },
        backup_account_last_at => {},
        backup_batch_last_at => undef,
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

sub auto_provision {
    my ($self, $username) = @_;
    return _fleet_failure('invalid_request', 'invalid', 'auto_provision', 0)
        if !defined($username) || ref($username) || $username !~ /\A[a-zA-Z0-9_-]{1,16}\z/;
    my $account = eval { $self->{resolver}->resolve_name($username) };
    if (ref($account) ne 'HASH' || ($account->{name} // '') ne $username) {
        my $audited = _audit_event($self, 0, $username, 'auto_provision', 'account_unavailable', 'unavailable');
        return _fleet_failure('account_unavailable', $username, 'auto_provision', $audited);
    }
    my $result = eval { $self->{instance_manager}->auto_provision($account) }
        if defined($self->{instance_manager}) && eval { $self->{instance_manager}->can('auto_provision') };
    if (ref($result) ne 'HASH') {
        my $audited = _audit_event($self, 0, $username, 'auto_provision', 'operation_failed', 'unavailable');
        return _fleet_failure('operation_failed', $username, 'auto_provision', $audited);
    }
    my $state = defined($result->{state}) && !ref($result->{state})
        && $result->{state} =~ /\A(?:not_configured|stopped|starting|running|stopping|failed)\z/
        ? $result->{state} : 'unavailable';
    my $outcome = $result->{success} ? 'success'
        : defined($result->{error}) && !ref($result->{error})
            && $result->{error} =~ /\A(?:provider_policy_denied|provider_policy_unavailable|backend_policy_required|backend_unavailable|storage_unavailable|service_failed|instance_unavailable)\z/
            ? $result->{error} : 'operation_failed';
    my $audited = _audit_event($self, 0, $username, 'auto_provision', $outcome, $state);
    my %response = (
        action => 'auto_provision',
        audit_logged => $audited ? JSON::PP::true : JSON::PP::false,
        outcome => defined($result->{outcome}) && !ref($result->{outcome})
            && $result->{outcome} =~ /\A(?:disabled|already_present|provisioned|failed)\z/
            ? $result->{outcome} : 'failed',
        state => $state,
        success => $result->{success} ? JSON::PP::true : JSON::PP::false,
        username => $username,
        version => 1,
    );
    $response{error} = $outcome if !$result->{success};
    return \%response;
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

sub backup_batch {
    my ($self, $action, $targets, $rate_limited_targets) = @_;
    return _failure('invalid_request') if !defined($action) || ref($action)
        || $action !~ /\A(?:create|restore)\z/ || ref($targets) ne 'ARRAY'
        || @{$targets} < 1 || @{$targets} > $MAX_BACKUP_BATCH_TARGETS;
    my %seen;
    for my $target (@{$targets}) {
        return _failure('invalid_request') if ref($target) ne 'HASH'
            || !defined($target->{username}) || ref($target->{username})
            || $target->{username} !~ /\A[a-zA-Z0-9_-]{1,16}\z/
            || $seen{$target->{username}}++
            || ($action eq 'create' && join(',', sort keys %{$target}) ne 'username')
            || ($action eq 'restore' && (join(',', sort keys %{$target}) ne 'backup_id,username'
                || !_valid_backup_id($target->{backup_id})));
    }
    my $now = eval { $self->{clock}->() };
    return _failure('operation_failed') if !defined($now) || ref($now) || $now !~ /\A[0-9]+(?:\.[0-9]+)?\z/;
    my $globallyLimited = defined($self->{backup_batch_last_at})
        && $now - $self->{backup_batch_last_at} < $BACKUP_BATCH_COOLDOWN_SECONDS;
    $self->{backup_batch_last_at} = $now if !$globallyLimited;

    my $eventAction = 'backup.' . $action;
    my @results;
    for my $target (@{$targets}) {
        my $username = $target->{username};
        my $previous = $self->{backup_account_last_at}->{$username};
        my $serverLimited = ref($rate_limited_targets) eq 'HASH' && $rate_limited_targets->{$username};
        if ($serverLimited || $globallyLimited || (defined($previous) && $now - $previous < $BACKUP_ACCOUNT_COOLDOWN_SECONDS)) {
            my $audited = _audit_event($self, 0, $username, $eventAction, 'rate_limited', 'unavailable');
            push @results, _fleet_failure('rate_limited', $username, $eventAction, $audited);
            next;
        }
        $self->{backup_account_last_at}->{$username} = $now;
        my $result = eval { $self->backup($username, $eventAction, $target->{backup_id}) };
        if (ref($result) ne 'HASH') {
            my $audited = _audit_event($self, 0, $username, $eventAction, 'operation_failed', 'unavailable');
            $result = _fleet_failure('operation_failed', $username, $eventAction, $audited);
        }
        push @results, $result;
    }
    my $succeeded = scalar grep { $_->{success} } @results;
    return {
        action => $eventAction,
        partial => $succeeded != @results ? JSON::PP::true : JSON::PP::false,
        requested_count => scalar(@results),
        results => \@results,
        succeeded_count => $succeeded,
        success => JSON::PP::true,
        version => 1,
    };
}

sub diagnostics {
    my ($self, $username, $command_class) = @_;
    return _fleet_failure('invalid_request', $username, 'diagnostics.read', 0)
        if !defined($command_class) || ref($command_class)
        || $command_class !~ /\A(?:ping|info_server|info_memory|info_clients|info_stats|info_commandstats|dbsize)\z/;
    my $action = 'diagnostics.' . $command_class;
    return _fleet_failure('invalid_request', $username, $action, 0)
        if !defined($username) || ref($username) || $username !~ /\A[a-zA-Z0-9_-]{1,16}\z/;

    my $account = eval { $self->{resolver}->resolve_name($username) };
    if (ref($account) ne 'HASH' || $account->{name} ne $username) {
        my $audited = _audit_event($self, 0, $username, $action, 'account_unavailable', 'unavailable');
        return _fleet_failure('account_unavailable', $username, $action, $audited);
    }

    my $result = eval { $self->{instance_manager}->read_diagnostic_command($account, $command_class) }
        if defined($self->{instance_manager}) && eval { $self->{instance_manager}->can('read_diagnostic_command') };
    if (ref($result) ne 'HASH') {
        my $audited = _audit_event($self, 0, $username, $action, 'diagnostics_unavailable', 'unavailable');
        return _fleet_failure('diagnostics_unavailable', $username, $action, $audited);
    }
    if ($result->{success}) {
        if (($result->{state} // '') ne 'running'
            || ($result->{command_class} // '') ne $command_class
            || !_valid_diagnostic_result($command_class, $result->{result})) {
            my $audited = _audit_event($self, 0, $username, $action, 'operation_failed', 'unavailable');
            return _fleet_failure('operation_failed', $username, $action, $audited);
        }
        my $audited = _audit_event($self, 0, $username, $action, 'success', 'running');
        return {
            action => $action,
            audit_logged => $audited ? JSON::PP::true : JSON::PP::false,
            command_class => $command_class,
            result => $result->{result},
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

sub recovery_scan {
    my ($self, $username) = @_;
    my $action = 'recovery.scan';
    return _fleet_failure('invalid_request', $username, $action, 0)
        if !defined($username) || ref($username) || $username !~ /\A[a-zA-Z0-9_-]{1,16}\z/;

    my $account = eval { $self->{resolver}->resolve_name($username) };
    if (ref($account) ne 'HASH' || $account->{name} ne $username) {
        my $audited = _audit_event($self, 0, $username, $action, 'account_unavailable', 'unavailable');
        return _fleet_failure('account_unavailable', $username, $action, $audited);
    }

    my $config_scan = eval { $self->{instance_manager}->recovery_config_scan($account) }
        if defined($self->{instance_manager}) && eval { $self->{instance_manager}->can('recovery_config_scan') };
    if (ref($config_scan) eq 'HASH' && $config_scan->{success}
        && ($config_scan->{finding} // '') =~ /\A(?:config_drift|config_missing|config_malformed)\z/
        && defined($config_scan->{state}) && $config_scan->{state} =~ /\A(?:running|starting|stopping|stopped|failed)\z/) {
        my $repair = $config_scan->{repair};
        my $expected_repair = $config_scan->{finding} eq 'config_drift' ? 'config_rebuild' : 'config_reset';
        $repair = undef if !defined($repair) || ref($repair) || $repair ne $expected_repair;
        $repair = undef if $config_scan->{state} ne 'stopped' && $config_scan->{state} ne 'failed';
        my $audited = _audit_event($self, 0, $username, $action, 'success', $config_scan->{state});
        return _recovery_scan_response($username, $config_scan->{finding}, $repair, $config_scan->{state}, $audited);
    }

    my $ownership_scan = eval { $self->{instance_manager}->recovery_ownership_scan($account) }
        if defined($self->{instance_manager}) && eval { $self->{instance_manager}->can('recovery_ownership_scan') };
    if (ref($ownership_scan) eq 'HASH' && $ownership_scan->{success}
        && ($ownership_scan->{finding} // '') eq 'data_directory_ownership'
        && defined($ownership_scan->{state})
        && $ownership_scan->{state} =~ /\A(?:running|starting|stopping|stopped|failed)\z/) {
        my $repair = $ownership_scan->{repair};
        $repair = undef if !defined($repair) || ref($repair) || $repair ne 'ownership_fix';
        $repair = undef if $ownership_scan->{state} ne 'stopped' && $ownership_scan->{state} ne 'failed';
        my $audited = _audit_event($self, 0, $username, $action, 'success', $ownership_scan->{state});
        return _recovery_scan_response(
            $username, $ownership_scan->{finding}, $repair, $ownership_scan->{state}, $audited
        );
    }

    my $status = eval { $self->{instance_manager}->status($account) }
        if defined($self->{instance_manager}) && eval { $self->{instance_manager}->can('status') };
    if (ref($status) ne 'HASH' || !$status->{success}) {
        my $audited = _audit_event($self, 0, $username, $action, 'instance_unavailable', 'unavailable');
        return _fleet_failure('instance_unavailable', $username, $action, $audited);
    }

    my $state = $status->{state};
    if (!defined($state) || ref($state)
        || $state !~ /\A(?:not_configured|stopped|starting|running|stopping|failed)\z/) {
        my $audited = _audit_event($self, 0, $username, $action, 'instance_unavailable', 'unavailable');
        return _fleet_failure('instance_unavailable', $username, $action, $audited);
    }
    if ($state eq 'not_configured') {
        my $audited = _audit_event($self, 0, $username, $action, 'success', 'unavailable');
        return _recovery_scan_response($username, 'not_configured', undef, 'not_configured', $audited);
    }
    if ($state eq 'stopped' || $state eq 'failed') {
        my $finding = $state eq 'stopped' ? 'service_stopped' : 'service_failed';
        my $audited = _audit_event($self, 0, $username, $action, 'success', $state);
        return _recovery_scan_response($username, $finding, 'start', $state, $audited);
    }
    if ($state eq 'starting' || $state eq 'stopping') {
        my $audited = _audit_event($self, 0, $username, $action, 'success', $state);
        return _recovery_scan_response($username, 'service_transitioning', undef, $state, $audited);
    }
    if ($state ne 'running') {
        my $audited = _audit_event($self, 0, $username, $action, 'instance_unavailable', 'unavailable');
        return _fleet_failure('instance_unavailable', $username, $action, $audited);
    }

    my $probe = eval { $self->{instance_manager}->recovery_health_check($account) }
        if defined($self->{instance_manager}) && eval { $self->{instance_manager}->can('recovery_health_check') };
    my $healthy = ref($probe) eq 'HASH' && $probe->{success};
    my $finding = $healthy ? 'service_healthy' : 'health_probe_failed';
    my $audited = _audit_event($self, 0, $username, $action,
        $healthy ? 'success' : 'health_probe_failed', 'running');
    return _recovery_scan_response($username, $finding, undef, 'running', $audited);
}

sub recovery_repair {
    my ($self, $username, $repair) = @_;
    my $action = defined($repair) && !ref($repair) && $repair eq 'config_rebuild'
        ? 'recovery.config_rebuild' : defined($repair) && !ref($repair) && $repair eq 'config_reset'
            ? 'recovery.config_reset' : defined($repair) && !ref($repair) && $repair eq 'ownership_fix'
                ? 'recovery.ownership_fix' : 'recovery.start';
    return _fleet_failure('invalid_request', $username, $action, 0)
        if !defined($username) || ref($username) || $username !~ /\A[a-zA-Z0-9_-]{1,16}\z/
        || !defined($repair) || ref($repair) || $repair !~ /\A(?:start|config_rebuild|config_reset|ownership_fix)\z/;

    my $scan = $self->recovery_scan($username);
    if (ref($scan) ne 'HASH' || !$scan->{success}) {
        my $audited = _audit_event($self, 0, $username, $action, 'scan_failed', 'unavailable');
        return _fleet_failure('instance_unavailable', $username, $action, $audited);
    }
    if (($scan->{repair} // '') ne $repair) {
        my $audited = _audit_event($self, 0, $username, $action, 'repair_not_applicable', $scan->{state});
        return _fleet_failure('repair_not_applicable', $username, $action, $audited);
    }

    my $account = eval { $self->{resolver}->resolve_name($username) };
    if (ref($account) ne 'HASH' || $account->{name} ne $username) {
        my $audited = _audit_event($self, 0, $username, $action, 'account_unavailable', 'unavailable');
        return _fleet_failure('account_unavailable', $username, $action, $audited);
    }
    my $result = eval {
        $repair eq 'start' ? $self->{instance_manager}->recovery_start_if_stopped($account)
            : $repair eq 'config_reset' ? $self->{instance_manager}->recovery_reset_config($account)
            : $repair eq 'ownership_fix' ? $self->{instance_manager}->recovery_fix_ownership($account)
            : $self->{instance_manager}->recovery_rebuild_config($account)
    } if defined($self->{instance_manager}) && eval {
        $self->{instance_manager}->can($repair eq 'start' ? 'recovery_start_if_stopped'
            : $repair eq 'config_reset' ? 'recovery_reset_config'
            : $repair eq 'ownership_fix' ? 'recovery_fix_ownership' : 'recovery_rebuild_config')
    };
    my $state_valid = ref($result) eq 'HASH' && defined($result->{state})
        && ($repair eq 'start' ? $result->{state} =~ /\A(?:starting|running)\z/ : $result->{state} =~ /\A(?:stopped|failed)\z/);
    if (ref($result) eq 'HASH' && $result->{success} && $state_valid) {
        if ($repair eq 'config_reset' && (!JSON::PP::is_bool($result->{auth_configured})
            || !$result->{auth_configured} || !defined($result->{secret}) || ref($result->{secret})
            || $result->{secret} !~ /\A[A-Za-z0-9_-]{43}\z/)) {
            my $audited = _audit_event($self, 0, $username, $action, 'operation_failed', 'unavailable');
            return _fleet_failure('operation_failed', $username, $action, $audited);
        }
        my $audited = _audit_event($self, 0, $username, $action, 'success', $result->{state});
        my $response = {
            action => $action,
            audit_logged => $audited ? JSON::PP::true : JSON::PP::false,
            state => $result->{state},
            success => JSON::PP::true,
            username => $username,
            version => 1,
        };
        if ($repair eq 'config_reset') {
            $response->{auth_configured} = JSON::PP::true;
            $response->{secret} = $result->{secret};
        }
        return $response;
    }
    my %allowed_errors = map { $_ => 1 } qw(
        auth_generation_failed configuration_storage_unavailable instance_unavailable not_configured operation_in_progress repair_not_applicable service_failed
    );
    my $error = ref($result) eq 'HASH' && defined($result->{error}) && $allowed_errors{$result->{error}}
        ? $result->{error} : 'instance_unavailable';
    my $audited = _audit_event($self, 0, $username, $action, $error, 'unavailable');
    return _fleet_failure($error, $username, $action, $audited);
}

sub _recovery_scan_response {
    my ($username, $finding, $repair, $state, $audited) = @_;
    my $response = {
        action => 'recovery.scan',
        audit_logged => $audited ? JSON::PP::true : JSON::PP::false,
        finding => $finding,
        state => $state,
        success => JSON::PP::true,
        username => $username,
        version => 1,
    };
    $response->{repair} = $repair if defined($repair);
    return $response;
}

sub rotate_auth {
    my ($self, $username) = @_;
    my $action = 'auth.rotate';
    return _fleet_failure('invalid_request', $username, $action, 0)
        if !defined($username) || ref($username) || $username !~ /\A[a-zA-Z0-9_-]{1,16}\z/;
    my $account = eval { $self->{resolver}->resolve_name($username) };
    if (ref($account) ne 'HASH' || ($account->{name} // '') ne $username) {
        my $audited = _audit_event($self, 0, $username, $action, 'account_unavailable', 'unavailable');
        return _fleet_failure('account_unavailable', $username, $action, $audited);
    }
    my $manager = $self->{instance_manager};
    my $result = eval { $manager->rotate_auth($account, 0) }
        if defined($manager) && eval { $manager->can('rotate_auth') };
    if (ref($result) eq 'HASH' && $result->{success}
        && JSON::PP::is_bool($result->{auth_configured}) && $result->{auth_configured}
        && defined($result->{secret}) && !ref($result->{secret})
        && $result->{secret} =~ /\A[A-Za-z0-9_-]{43}\z/) {
        my $audited = _audit_event($self, 0, $username, $action, 'success', 'running');
        return {
            action => $action,
            audit_logged => $audited ? JSON::PP::true : JSON::PP::false,
            auth_configured => JSON::PP::true,
            secret => $result->{secret},
            state => 'running',
            success => JSON::PP::true,
            username => $username,
            version => 1,
        };
    }
    my %allowed_errors = map { $_ => 1 } qw(
        auth_generation_failed auth_recovery_required auth_rotation_failed configuration_storage_unavailable
        configuration_unavailable instance_unavailable not_configured not_running operation_in_progress
    );
    my $error = ref($result) eq 'HASH' && defined($result->{error}) && $allowed_errors{$result->{error}}
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
    return _failure('operation_failed') if !eval { $self->{instance_manager}->can('backups') };
    my ($accounts, $scanError) = $self->_verified_accounts();
    return _failure($scanError) if defined($scanError);
    my @accounts = @{$accounts};
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
            my $usage = {
                connected_clients => undef,
                client_limit => undef,
                memory_limit_bytes => undef,
                memory_used_bytes => undef,
                sampled_at => undef,
                state => 'unknown',
            };
            if (eval { $self->{instance_manager}->can('fleet_usage') }) {
                my $candidate_usage = eval { $self->{instance_manager}->fleet_usage($candidate->{account}) };
                $usage = $candidate_usage if _valid_fleet_usage($candidate_usage);
            }
            push @page, {
                backups => \@backups,
                backups_available => $backups_available ? JSON::PP::true : JSON::PP::false,
                backend => $backend,
                username => $candidate->{username},
                state => $state,
                usage => $usage,
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

sub summary {
    my ($self) = @_;
    return _failure('operation_failed') if !eval { $self->{instance_manager}->can('fleet_summary') };
    my ($accounts, $scanError, $unverified) = $self->_verified_accounts();
    return _failure($scanError) if defined($scanError);
    my @resolved = map { $_->{account} } @{$accounts};
    my $summary = eval { $self->{instance_manager}->fleet_summary(\@resolved) };
    return _failure('operation_failed') if ref($summary) ne 'HASH' || !$summary->{success};
    my $podman = eval {
        Orm::Broker::PodmanMetricsCollector->read_snapshot($self->{podman_snapshot_path}, now => $self->{clock}->());
    };
    $summary->{podman_metrics} = ref($podman) eq 'HASH' ? $podman : undef;
    $summary->{partial} = JSON::PP::true if ref($podman) ne 'HASH' || $podman->{partial};
    $summary->{unverified_count} += $unverified;
    $summary->{account_count} += $unverified;
    $summary->{partial} = JSON::PP::true if $unverified > 0;
    return $summary;
}

sub _verified_accounts {
    my ($self) = @_;
    return (undef, 'operation_failed', 0) if !eval { $self->{resolver}->can('resolve_account') };
    my @root_stat = lstat($self->{instance_root});
    return (undef, 'operation_failed', 0) if !@root_stat || !S_ISDIR($root_stat[2])
        || $root_stat[4] != $self->{expected_owner_uid} || ($root_stat[2] & 0022) != 0;
    my @names;
    if (ref($self->{read_names}) eq 'CODE') {
        @names = eval { $self->{read_names}->($self->{instance_root}) };
        return (undef, 'operation_failed', 0) if $@;
    } else {
        opendir(my $directory, $self->{instance_root}) or return (undef, 'operation_failed', 0);
        while (my $name = readdir($directory)) {
            next if $name eq '.' || $name eq '..';
            push @names, $name;
            if (@names > $MAX_METADATA_ENTRIES) {
                closedir($directory);
                return (undef, 'operation_failed', 0);
            }
        }
        closedir($directory) or return (undef, 'operation_failed', 0);
    }
    return (undef, 'operation_failed', 0) if @names > $MAX_METADATA_ENTRIES;
    my @accounts;
    my $unverified = 0;
    for my $name (@names) {
        if (!defined($name) || ref($name) || $name !~ /\A[a-zA-Z0-9_-]{1,16}\z/) {
            ++$unverified if defined($name) && !ref($name) && $name ne '.orm-reseller-quota.lock';
            next;
        }
        my @directory_stat = lstat("$self->{instance_root}/$name");
        if (!@directory_stat || !S_ISDIR($directory_stat[2])
            || $directory_stat[4] != $self->{expected_owner_uid} || ($directory_stat[2] & 0027) != 0) {
            ++$unverified;
            next;
        }
        my $identity = eval { $self->{lookup_name}->($name) };
        if (ref($identity) ne 'HASH' || !defined($identity->{uid}) || ref($identity->{uid})
            || $identity->{uid} !~ /\A[1-9][0-9]*\z/) {
            ++$unverified;
            next;
        }
        my $account = eval { $self->{resolver}->resolve_account($identity->{uid}) };
        if (ref($account) ne 'HASH' || ($account->{name} // '') ne $name
            || ($account->{uid} // -1) != $identity->{uid}) {
            ++$unverified;
            next;
        }
        push @accounts, { account => $account, username => $name };
    }
    my %seen;
    for my $candidate (@accounts) {
        return (undef, 'operation_failed', 0) if $seen{$candidate->{username}}++;
    }
    @accounts = sort { $a->{username} cmp $b->{username} } @accounts;
    return (\@accounts, undef, $unverified);
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

sub _valid_fleet_usage {
    my ($usage) = @_;
    return 0 if ref($usage) ne 'HASH';
    return 0 if join(',', sort keys %{$usage}) ne join(',', sort qw(
        connected_clients client_limit memory_limit_bytes memory_used_bytes sampled_at state
    ));
    return 0 if !defined($usage->{state}) || ref($usage->{state})
        || $usage->{state} !~ /\A(?:fresh|stale|unknown)\z/;
    for my $field (qw(connected_clients client_limit memory_limit_bytes memory_used_bytes sampled_at)) {
        next if !defined($usage->{$field});
        return 0 if ref($usage->{$field}) || $usage->{$field} !~ /\A(?:0|[1-9][0-9]{0,15})\z/;
    }
    return 0 if defined($usage->{client_limit}) && $usage->{client_limit} < 1;
    return 0 if defined($usage->{memory_limit_bytes}) && $usage->{memory_limit_bytes} < 1;
    if ($usage->{state} eq 'unknown') {
        return !defined($usage->{connected_clients}) && !defined($usage->{memory_used_bytes})
            && !defined($usage->{sampled_at});
    }
    return defined($usage->{connected_clients}) && defined($usage->{memory_used_bytes})
        && defined($usage->{sampled_at}) && defined($usage->{client_limit})
        && defined($usage->{memory_limit_bytes});
}

sub _audit_control {
    my ($self, $username, $action, $outcome, $state) = @_;
    return _audit_event($self, 0, $username, $action, $outcome, $state);
}

sub _audit_event {
    my ($self, $peer_uid, $username, $action, $outcome, $state) = @_;
    $peer_uid = 0 if !defined($peer_uid) || ref($peer_uid) || $peer_uid !~ /\A[0-9]{1,10}\z/;
    $state = 'unavailable' if !defined($state) || ref($state)
        || $state !~ /\A(?:not_configured|stopped|starting|running|stopping|failed|unavailable)\z/;
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
        || $action !~ /\A(?:start|stop|restart|auto_provision|auth\.rotate|backup\.create|backup\.restore|backup\.batch\.create|backup\.batch\.restore|migration\.to-valkey|diagnostics\.(?:ping|info_server|info_memory|info_clients|info_stats|info_commandstats|dbsize)|recovery\.scan|recovery\.start|recovery\.config_rebuild|recovery\.config_reset|recovery\.ownership_fix)\z/;
    return _audit_event($self, $peer_uid, $username, $action, 'not_authorized', 'unavailable');
}

sub audit_rate_limited {
    my ($self, $peer_uid, $username, $action) = @_;
    $peer_uid = 'unknown' if !defined($peer_uid) || ref($peer_uid) || $peer_uid !~ /\A[0-9]{1,10}\z/;
    $username = 'invalid' if !defined($username) || ref($username) || $username !~ /\A[a-zA-Z0-9_-]{1,16}\z/;
    $action = 'recovery.scan' if !defined($action) || ref($action)
        || $action !~ /\A(?:auth\.rotate|diagnostics\.(?:ping|info_server|info_memory|info_clients|info_stats|info_commandstats|dbsize)|recovery\.scan|recovery\.start|recovery\.config_rebuild|recovery\.config_reset|recovery\.ownership_fix)\z/;
    return _audit_event($self, $peer_uid, $username, $action, 'rate_limited', 'unavailable');
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

sub _valid_diagnostic_result {
    my ($command_class, $result) = @_;
    return 0 if ref($result) ne 'HASH';
    my $max_integer = 9_000_000_000_000_000;
    my %expected = (
        ping => [qw(response)],
        dbsize => [qw(database_keys)],
        info_server => [qw(server_version uptime_seconds)],
        info_memory => [qw(maxmemory_bytes memory_peak_bytes memory_used_bytes)],
        info_clients => [qw(blocked_clients connected_clients maxclients)],
        info_stats => [qw(commands_per_second evicted_keys expired_keys keyspace_hits keyspace_misses)],
        info_commandstats => [qw(commands truncated)],
    );
    my $fields = $expected{$command_class};
    return 0 if !defined($fields) || join(',', sort keys %{$result}) ne join(',', sort @{$fields});
    if ($command_class eq 'info_commandstats') {
        return 0 if ref($result->{truncated}) || ($result->{truncated} ne '0' && $result->{truncated} ne '1')
            || ref($result->{commands}) ne 'ARRAY' || @{$result->{commands}} > 60;
        my %seen;
        for my $command (@{$result->{commands}}) {
            return 0 if ref($command) ne 'HASH' || join(',', sort keys %{$command}) ne 'calls,command,usec'
                || !defined($command->{command}) || ref($command->{command})
                || $command->{command} !~ /\A[A-Za-z0-9_.|]{1,64}\z/ || $seen{$command->{command}}++;
            for my $counter (qw(calls usec)) {
                return 0 if !defined($command->{$counter}) || ref($command->{$counter})
                    || $command->{$counter} !~ /\A(?:0|[1-9][0-9]{0,15})\z/
                    || $command->{$counter} > $max_integer;
            }
        }
        return 1;
    }
    if ($command_class eq 'ping') {
        return defined($result->{response}) && !ref($result->{response}) && $result->{response} eq 'PONG';
    }
    if ($command_class eq 'info_server') {
        return 0 if !defined($result->{server_version}) || ref($result->{server_version})
            || $result->{server_version} !~ /\A[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}(?:[-+][A-Za-z0-9.-]{1,24})?\z/;
    }
    for my $field (@{$fields}) {
        next if $field eq 'server_version' || $field eq 'response';
        return 0 if !defined($result->{$field}) || ref($result->{$field})
            || $result->{$field} !~ /\A(?:0|[1-9][0-9]{0,15})\z/ || $result->{$field} > $max_integer;
    }
    return 0 if $command_class eq 'info_memory'
        && ($result->{memory_peak_bytes} < $result->{memory_used_bytes});
    return 0 if $command_class eq 'info_clients'
        && ($result->{maxclients} < 1 || $result->{maxclients} > 100000
            || $result->{connected_clients} > $result->{maxclients});
    return 1;
}

1;
