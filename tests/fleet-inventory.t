use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use lib 'src';
use Orm::Broker::FleetInventory;
use Orm::Broker::Handler;
use Orm::Broker::Protocol qw(parse_request);
use Orm::Broker::Server;

plan skip_all => 'fleet inventory filesystem permission tests require Linux mode semantics' if $^O ne 'linux';

{
    package Local::FleetResolver;
    sub new { return bless {}, $_[0]; }
    sub resolve_account {
        my ($self, $uid) = @_;
        return undef if !defined($uid) || $uid < 10001 || $uid > 10036;
        return { name => sprintf('acct%02d', $uid - 10000), uid => $uid, gid => 1000 };
    }
    sub resolve_name {
        my ($self, $name) = @_;
        return undef if !defined($name) || $name !~ /\Aacct([0-9]{2})\z/ || $1 > 35;
        return { name => $name, uid => 10000 + $1, gid => 1000 };
    }

    package Local::FleetManager;
    our @STATUS_CALLS;
    our @USAGE_CALLS;
    our @METRICS_CALLS;
    our @CONTROL_CALLS;
    our %CONTROL_STATES;
    our @BACKUP_CALLS;
    our %BACKUPS;
    our @MIGRATION_CALLS;
    our @DIAGNOSTICS_CALLS;
    our @AUTH_ROTATE_CALLS;
    our @RECOVERY_HEALTH_CALLS;
    our @RECOVERY_CALLS;
    our %RECOVERY_ERRORS;
    our %RECOVERY_CONFIG_DRIFT;
    our %RECOVERY_CONFIG_RESET;
    our @RECOVERY_CONFIG_SCAN_CALLS;
    our @RECOVERY_CONFIG_REBUILD_CALLS;
    our @RECOVERY_CONFIG_RESET_CALLS;
    our %RECOVERY_OWNERSHIP;
    our @RECOVERY_OWNERSHIP_FIX_CALLS;
    sub new { return bless {}, $_[0]; }
    sub status {
        my ($self, $account) = @_;
        push @STATUS_CALLS, $account->{name};
        return { success => 1, state => $CONTROL_STATES{$account->{name}} }
            if exists $CONTROL_STATES{$account->{name}};
        return { success => 0, error => 'instance_unavailable' } if $account->{name} eq 'acct31';
        return { success => 1, state => 'not_configured' } if $account->{name} eq 'acct32';
        return { success => 1, state => 'running' } if $account->{name} eq 'acct01';
        return { success => 1, state => 'stopped' };
    }
    sub start { return _control($_[0], $_[1], 'start', 'running'); }
    sub stop { return _control($_[0], $_[1], 'stop', 'stopped'); }
    sub restart { return _control($_[0], $_[1], 'restart', 'starting'); }
    sub recovery_start_if_stopped {
        my ($self, $account) = @_;
        push @RECOVERY_CALLS, $account->{name};
        return { success => 0, error => $RECOVERY_ERRORS{$account->{name}} }
            if exists $RECOVERY_ERRORS{$account->{name}};
        my $state = $CONTROL_STATES{$account->{name}} // ($account->{name} eq 'acct01' ? 'running' : 'stopped');
        return { success => 0, error => 'repair_not_applicable' }
            if $state ne 'stopped' && $state ne 'failed';
        $CONTROL_STATES{$account->{name}} = 'starting';
        return { success => 1, state => 'starting' };
    }
    sub recovery_config_scan {
        my ($self, $account) = @_;
        push @RECOVERY_CONFIG_SCAN_CALLS, $account->{name};
        if ($RECOVERY_CONFIG_RESET{$account->{name}}) {
            my $state = $CONTROL_STATES{$account->{name}} // 'stopped';
            my $result = { success => 1, finding => $RECOVERY_CONFIG_RESET{$account->{name}}, state => $state };
            $result->{repair} = 'config_reset' if $state eq 'stopped' || $state eq 'failed';
            return $result;
        }
        return undef if !$RECOVERY_CONFIG_DRIFT{$account->{name}};
        my $state = $CONTROL_STATES{$account->{name}} // 'stopped';
        my $result = { success => 1, finding => 'config_drift', state => $state };
        $result->{repair} = 'config_rebuild' if $state eq 'stopped' || $state eq 'failed'
            || $account->{name} eq 'acct08';
        return $result;
    }
    sub recovery_ownership_scan {
        my ($self, $account) = @_;
        return undef if !$RECOVERY_OWNERSHIP{$account->{name}};
        my $state = $CONTROL_STATES{$account->{name}} // 'stopped';
        my $result = { success => 1, finding => 'data_directory_ownership', state => $state };
        $result->{repair} = 'ownership_fix' if $state eq 'stopped' || $state eq 'failed';
        return $result;
    }
    sub recovery_fix_ownership {
        my ($self, $account) = @_;
        push @RECOVERY_OWNERSHIP_FIX_CALLS, $account->{name};
        my $state = $CONTROL_STATES{$account->{name}} // 'stopped';
        return { success => 0, error => 'repair_not_applicable' }
            if $state ne 'stopped' && $state ne 'failed';
        return { success => 1, state => $state };
    }
    sub recovery_rebuild_config {
        my ($self, $account) = @_;
        push @RECOVERY_CONFIG_REBUILD_CALLS, $account->{name};
        my $state = $CONTROL_STATES{$account->{name}} // 'stopped';
        return { success => 0, error => 'repair_not_applicable' }
            if $state ne 'stopped' && $state ne 'failed';
        return { success => 1, state => $state };
    }
    sub recovery_reset_config {
        my ($self, $account) = @_;
        push @RECOVERY_CONFIG_RESET_CALLS, $account->{name};
        my $state = $CONTROL_STATES{$account->{name}} // 'stopped';
        return { success => 0, error => 'repair_not_applicable' }
            if $state ne 'stopped' && $state ne 'failed';
        return { success => 1, state => $state, auth_configured => JSON::PP::true, secret => 'A' x 43 };
    }
    sub backups {
        my ($self, $account) = @_;
        return { success => 1, backups => $BACKUPS{$account->{name}} // [] };
    }
    sub fleet_usage {
        my ($self, $account) = @_;
        push @USAGE_CALLS, $account->{name};
        return {
            connected_clients => $account->{name} eq 'acct01' ? 3 : undef,
            client_limit => 100,
            memory_limit_bytes => 64 * 1024 * 1024,
            memory_used_bytes => $account->{name} eq 'acct01' ? 1048576 : undef,
            sampled_at => $account->{name} eq 'acct01' ? time : undef,
            state => $account->{name} eq 'acct01' ? 'fresh' : 'unknown',
        };
    }
    sub metrics { push @METRICS_CALLS, $_[1]->{name}; die 'live metrics probe must not run from fleet inventory'; }
    sub backend { return $_[1]->{name} eq 'acct01' ? 'redis' : 'valkey'; }
    sub migrate_to_valkey {
        my ($self, $account) = @_;
        push @MIGRATION_CALLS, [$account->{name}];
        return {
            success => 1, backup_id => 'snapshot-1794760000-a1b2c3d4.rdb',
            source_backend => 'redis', target_backend => 'valkey', state => 'running',
        };
    }
    sub read_diagnostic_command {
        my ($self, $account, $command_class) = @_;
        push @DIAGNOSTICS_CALLS, [$account->{name}, $command_class];
        return { success => 0, error => 'not_running' } if $account->{name} ne 'acct01';
        my %results = (
            ping => { response => 'PONG' },
            info_server => { server_version => '7.2.4', uptime_seconds => 3600 },
            info_memory => { memory_used_bytes => 1048576, memory_peak_bytes => 2097152, maxmemory_bytes => 67108864 },
            info_clients => { connected_clients => 3, blocked_clients => 0, maxclients => 100 },
            info_stats => { commands_per_second => 12, keyspace_hits => 90, keyspace_misses => 10, expired_keys => 4, evicted_keys => 2 },
            info_commandstats => { commands => [
                { command => 'get', calls => 18, usec => 45 },
            ], truncated => 0 },
            slowlog => { entries => [
                { command => 'get', duration_usec => 456, timestamp => 1700000000 },
            ], truncated => 0 },
            dbsize => { database_keys => 42 },
        );
        return {
            success => 1,
            state => 'running',
            command_class => $command_class,
            result => $results{$command_class},
        };
    }
    sub recovery_health_check {
        my ($self, $account) = @_;
        push @RECOVERY_HEALTH_CALLS, $account->{name};
        return { success => $account->{name} eq 'acct01' ? 1 : 0 };
    }
    sub rotate_auth {
        my ($self, $account, $actor_uid) = @_;
        push @AUTH_ROTATE_CALLS, [$account->{name}, $actor_uid];
        return { success => 0, error => 'not_running' } if $account->{name} eq 'acct10';
        return { success => 1, auth_configured => JSON::PP::true, secret => 'A' x 43 };
    }
    sub create_backup {
        my ($self, $account) = @_;
        push @BACKUP_CALLS, ['create', $account->{name}];
        return { success => 1, backup => { id => 'snapshot-1794760000-a1b2c3d4.rdb', created_at => 1794760000, size_bytes => 4096 } };
    }
    sub restore_backup {
        my ($self, $account, $backup_id) = @_;
        push @BACKUP_CALLS, ['restore', $account->{name}, $backup_id];
        return { success => 1, backup_id => $backup_id, safety_backup_id => 'snapshot-1794760001-b2c3d4e5.rdb', state => 'running' };
    }
    sub _control {
        my ($self, $account, $action, $state) = @_;
        push @CONTROL_CALLS, [$action, $account->{name}];
        $CONTROL_STATES{$account->{name}} = $state;
        return { success => 1, state => $state };
    }

    package Local::FleetSummaryManager;
    sub new { return bless {}, $_[0]; }
    sub fleet_summary {
        my ($self, $accounts) = @_;
        return {
            account_count => scalar(@{$accounts}), managed_count => 0,
            unconfigured_count => scalar(@{$accounts}), unverified_count => 0,
            state_counts => { running => 0, stopped => 0, starting => 0, stopping => 0, failed => 0, unavailable => 0 },
            metrics => { fresh_accounts => 0, stale_accounts => 0, missing_accounts => 0,
                memory_used_bytes => 0, connected_clients => 0, high_memory_accounts => 0,
                high_client_accounts => 0, low_hit_ratio_accounts => 0, alert_accounts => 0, latest_sampled_at => 0 },
            partial => JSON::PP::false, success => JSON::PP::true, version => 1,
        };
    }
}

my $tmp = tempdir(CLEANUP => 1);
my $instance_root = "$tmp/instances";
make_path($instance_root);
chmod(0755, $instance_root) or die "chmod instance root: $!";
for my $number (1 .. 35) {
    my $name = sprintf('acct%02d', $number);
    make_path("$instance_root/$name");
    chmod(0750, "$instance_root/$name") or die "chmod account directory: $!";
}
make_path("$instance_root/invalid!");
chmod(0750, "$instance_root/invalid!") or die "chmod invalid account directory: $!";
my $has_symlink = symlink("$tmp/missing", "$instance_root/acct36");

my @audit;
my $inventory = Orm::Broker::FleetInventory->new(
    instance_root => $instance_root,
    expected_owner_uid => $<,
    resolver => Local::FleetResolver->new(),
    instance_manager => Local::FleetManager->new(),
    lookup_name => sub {
        my ($name) = @_;
        return undef if $name !~ /\Aacct([0-9]{2})\z/;
        return { uid => 10000 + $1 };
    },
    audit => sub { push @audit, [@_]; },
);

my $first = $inventory->page(0);
ok($first->{success}, 'return a successful fleet page');
is(scalar @Local::FleetManager::STATUS_CALLS, 4, 'query service state only for the bounded page');
SKIP: {
    skip 'filesystem does not allow symlink fixtures', 1 if !$has_symlink;
    ok(-l "$instance_root/acct36", 'create an account metadata symlink fixture');
}
is($first->{total}, 35, 'skip malformed account directories but include configured account directories');
is(scalar @{$first->{entries}}, 4, 'bound fleet responses to a four-account page');
is($first->{entries}[0]->{username}, 'acct01', 'sort fleet entries by account name');
is($first->{entries}[0]->{state}, 'running', 'report normalized running state');
is($first->{entries}[0]->{backend}, 'redis', 'include the validated backend on a root fleet row');
ok($first->{entries}[0]->{backups_available} && @{$first->{entries}[0]->{backups}} == 0,
    'report an available empty per-account snapshot list');
is($first->{entries}[0]->{usage}->{state}, 'fresh', 'include fixed per-account usage state in each fleet row');
is($first->{entries}[0]->{usage}->{memory_limit_bytes}, 64 * 1024 * 1024,
    'include validated configured memory limits in fleet rows');
is($first->{entries}[1]->{usage}->{state}, 'unknown', 'leave absent account metrics explicitly unknown');
is(scalar @Local::FleetManager::USAGE_CALLS, 4, 'read usage snapshots only for the bounded inventory page');
is(scalar @Local::FleetManager::METRICS_CALLS, 0, 'never issue live metrics probes while listing fleet rows');
is($first->{entries}[3]->{username}, 'acct04', 'first page ends at the fixed page size');
is($first->{entries}[4], undef, 'do not include entries beyond the response page');

my $second = $inventory->page(4);
is($second->{total}, 35, 'report the same total on later pages');
is(scalar @{$second->{entries}}, 4, 'return a full intermediate page');
is($second->{entries}[0]->{username}, 'acct05', 'sort entries consistently across pages');
my $unhealthy = $inventory->page(28);
is($unhealthy->{entries}[2]->{username}, 'acct31', 'include unhealthy account metadata');
is($unhealthy->{entries}[2]->{state}, 'unhealthy', 'normalize unverifiable service state');
is($unhealthy->{entries}[3]->{username}, 'acct32', 'include incomplete account directories for repair visibility');
is($unhealthy->{entries}[3]->{state}, 'unhealthy', 'mark incomplete metadata unhealthy');
my $last = $inventory->page(32);
is(scalar @{$last->{entries}}, 3, 'return only remaining entries on the last page');
is($last->{entries}[1]->{username}, 'acct34', 'retain sorted account names on the final page');
is($last->{entries}[1]->{state}, 'stopped', 'retain a verifiable stopped service state');
ok(!$inventory->page(36)->{success}, 'reject out-of-range page offsets');
ok(!$inventory->page(-1)->{success}, 'reject negative page offsets');
my $request = '{"offset":0,"operation":"fleet.list","version":1}' . "\n";
is(parse_request($request)->{operation}, 'fleet.list', 'accept the fixed fleet-list request');
ok(!parse_request('{"offset":0,"operation":"fleet.list","scope":"all","version":1}' . "\n"),
    'reject fleet requests with extra scope or identity fields');
my $root_response = Orm::Broker::Handler->handle_frame($request, 0, undef, undef, $inventory);
like($root_response, qr/"success":true/, 'allow root peers to read the scoped fleet inventory');
my $account_response = Orm::Broker::Handler->handle_frame($request, 10001, undef, undef, $inventory);
like($account_response, qr/"error":"not_authorized"/, 'deny non-root peers from reading the fleet inventory');

my $summaryInventory = Orm::Broker::FleetInventory->new(
    instance_root => $instance_root, expected_owner_uid => $<,
    resolver => Local::FleetResolver->new(), instance_manager => Local::FleetSummaryManager->new(),
    lookup_name => sub { $_[0] =~ /\Aacct([0-9]{2})\z/ ? { uid => 10000 + $1 } : undef },
    audit => sub { push @audit, [@_]; },
);
my $fleetSummary = $summaryInventory->summary();
ok($fleetSummary->{success} && $fleetSummary->{partial}, 'return a successful but explicitly partial fleet summary');
ok(exists($fleetSummary->{podman_metrics}) && !defined($fleetSummary->{podman_metrics}),
    'report a missing root Podman snapshot as unknown without probing from WHM');
is($fleetSummary->{account_count}, 37, 'count verified and unverified inventory entries');
is($fleetSummary->{unverified_count}, 2, 'count malformed and symlinked metadata as unverified');
my $summaryRequest = '{"operation":"fleet.summary","version":1}' . "\n";
like(Orm::Broker::Handler->handle_frame($summaryRequest, 0, undef, undef, $summaryInventory),
    qr/"unverified_count":2/, 'allow root to request the bounded fleet aggregate');
like(Orm::Broker::Handler->handle_frame($summaryRequest, 10001, undef, undef, $summaryInventory),
    qr/"error":"not_authorized"/, 'keep fleet aggregates root-only');

my $diagnostics_request = '{"command_class":"dbsize","operation":"fleet.diagnostics","username":"acct01","version":1}' . "\n";
is(parse_request($diagnostics_request)->{operation}, 'fleet.diagnostics', 'parse the fixed read-only diagnostics request');
ok(!parse_request('{"command":"INFO","command_class":"dbsize","operation":"fleet.diagnostics","username":"acct01","version":1}' . "\n"),
    'reject caller-provided commands at the broker protocol boundary');
my $diagnostics = $inventory->diagnostics('acct01', 'dbsize');
ok($diagnostics->{success} && $diagnostics->{command_class} eq 'dbsize'
    && $diagnostics->{result}->{database_keys} == 42,
    'return only the validated selected command result for the running account');
is_deeply($Local::FleetManager::DIAGNOSTICS_CALLS[-1], ['acct01', 'dbsize'], 'route diagnostics only to the trusted selected account and class');
is_deeply($audit[-1], [0, 'acct01', 'diagnostics.dbsize', 'success', 'running'],
    'audit the selected command class without storing command output or values');
ok(!Orm::Broker::FleetInventory::_valid_diagnostic_result('dbsize', { database_keys => 9_000_000_000_000_001 }),
    'reject selected diagnostic integers above the shared PHP-safe boundary');
my $commandstats_request = '{"command_class":"info_commandstats","operation":"fleet.diagnostics","username":"acct01","version":1}' . "\n";
ok(parse_request($commandstats_request)->{command_class} eq 'info_commandstats',
    'accept the fixed command-stat diagnostic class');
my $commandstats_response = $inventory->diagnostics('acct01', 'info_commandstats');
ok($commandstats_response->{success} && $commandstats_response->{result}->{commands}->[0]->{command} eq 'get',
    'return validated aggregate command counters without arguments');
is_deeply($audit[-1], [0, 'acct01', 'diagnostics.info_commandstats', 'success', 'running'],
    'audit command-stat reads by fixed class without storing returned counters');
ok(!Orm::Broker::FleetInventory::_valid_diagnostic_result('info_commandstats', {
    commands => [{ command => 'get', calls => 1, usec => 2, key => 'secret' }], truncated => 0,
}), 'reject command arguments and extra fields from a command-stat response');
my $slowlog_request = '{"command_class":"slowlog","operation":"fleet.diagnostics","username":"acct01","version":1}' . "\n";
ok(parse_request($slowlog_request)->{command_class} eq 'slowlog', 'accept the fixed slow-log diagnostic class');
my $slowlog_response = $inventory->diagnostics('acct01', 'slowlog');
ok($slowlog_response->{success} && $slowlog_response->{result}->{entries}->[0]->{command} eq 'get',
    'return only the validated slow-log command and timing');
is_deeply($audit[-1], [0, 'acct01', 'diagnostics.slowlog', 'success', 'running'],
    'audit slow-log reads by fixed class without storing log contents');
ok(!Orm::Broker::FleetInventory::_valid_diagnostic_result('slowlog', {
    entries => [{ command => 'get', duration_usec => 1, timestamp => 1700000000, arguments => ['secret'] }], truncated => 0,
}), 'reject slow-log command arguments and unexpected response fields');
ok(!Orm::Broker::FleetInventory::_valid_diagnostic_result('slowlog', {
    entries => [{ command => 'get', duration_usec => 1, timestamp => 253402300800 }], truncated => 0,
}), 'reject timestamps outside the supported UTC range');
is($inventory->diagnostics('acct02', 'dbsize')->{error}, 'not_running', 'require a running instance for diagnostics');
is($inventory->diagnostics('../root', 'dbsize')->{error}, 'invalid_request', 'reject malformed diagnostics targets');
is($inventory->diagnostics('acct01', 'flushall')->{error}, 'invalid_request', 'reject unknown command classes before dispatch');
my $calls_before_diagnostics_denial = scalar @Local::FleetManager::DIAGNOSTICS_CALLS;
my %non_root_diagnostics_rate;
ok(Orm::Broker::Server::_rate_allowed(\%non_root_diagnostics_rate, 10001, 10, 1, 1, 5, 'fleet.diagnostics:acct01'),
    'let the broker authorization handler inspect the first non-root diagnostics request');
my $nonRootDiagnostics = Orm::Broker::Handler->handle_frame($diagnostics_request, 10001, undef, undef, $inventory);
like($nonRootDiagnostics, qr/"error":"not_authorized"/, 'deny non-root peers before diagnostic probes');
is(scalar @Local::FleetManager::DIAGNOSTICS_CALLS, $calls_before_diagnostics_denial,
    'non-root diagnostic requests never reach the instance manager');
is_deeply($audit[-1], [10001, 'acct01', 'diagnostics.dbsize', 'not_authorized', 'unavailable'],
    'record denied diagnostic attempts using the kernel peer UID');
my $rootDiagnostics = Orm::Broker::Handler->handle_frame($diagnostics_request, 0, undef, undef, $inventory);
like($rootDiagnostics, qr/"success":true/, 'allow root peers to request bounded read-only diagnostics');
$inventory->audit_rate_limited(0, 'acct01', 'diagnostics.dbsize');
is_deeply($audit[-1], [0, 'acct01', 'diagnostics.dbsize', 'rate_limited', 'unavailable'],
    'audit rate-limited requests under the selected command class');

my $recoveryScanRequest = '{"operation":"fleet.recovery.scan","username":"acct02","version":1}' . "\n";
my $recoveryConfigScanRequest = '{"operation":"fleet.recovery.scan","username":"acct07","version":1}' . "\n";
my $recoveryRepairRequest = '{"operation":"fleet.recovery.repair","repair":"start","username":"acct02","version":1}' . "\n";
my $recoveryConfigRepairRequest = '{"operation":"fleet.recovery.repair","repair":"config_rebuild","username":"acct07","version":1}' . "\n";
my $recoveryConfigResetRequest = '{"operation":"fleet.recovery.repair","repair":"config_reset","username":"acct09","version":1}' . "\n";
my $recoveryOwnershipRepairRequest = '{"operation":"fleet.recovery.repair","repair":"ownership_fix","username":"acct10","version":1}' . "\n";
my $authRotateRequest = '{"operation":"fleet.auth.rotate","username":"acct02","version":1}' . "\n";
is(parse_request($recoveryScanRequest)->{operation}, 'fleet.recovery.scan', 'parse the fixed read-only recovery scan request');
is(parse_request($recoveryRepairRequest)->{repair}, 'start', 'parse only the fixed start repair');
is(parse_request($recoveryConfigRepairRequest)->{repair}, 'config_rebuild', 'parse the fixed configuration rebuild repair');
is(parse_request($recoveryConfigResetRequest)->{repair}, 'config_reset', 'parse the fixed malformed-config reset repair');
is(parse_request($recoveryOwnershipRepairRequest)->{repair}, 'ownership_fix', 'parse the fixed data-directory ownership repair');
ok(!parse_request('{"command":"systemctl start","operation":"fleet.recovery.repair","repair":"start","username":"acct02","version":1}' . "\n"),
    'reject arbitrary commands from recovery requests');
ok(!parse_request('{"operation":"fleet.recovery.repair","repair":"chmod","username":"acct02","version":1}' . "\n"),
    'reject recovery actions outside the fixed repair allowlist');
is(parse_request($authRotateRequest)->{operation}, 'fleet.auth.rotate', 'parse the fixed root AUTH rotation request');
ok(!parse_request('{"operation":"fleet.auth.rotate","secret":"chosen","username":"acct02","version":1}' . "\n"),
    'reject caller-selected AUTH secrets');
my $rotation = $inventory->rotate_auth('acct02');
ok($rotation->{success} && $rotation->{action} eq 'auth.rotate' && $rotation->{auth_configured}
    && $rotation->{secret} eq ('A' x 43) && $rotation->{state} eq 'running',
    'return a verified one-time generated password for a running account');
is_deeply($Local::FleetManager::AUTH_ROTATE_CALLS[-1], ['acct02', 0],
    'perform WHM AUTH rotation as the root actor against only the resolved account');
is_deeply($audit[-1], [0, 'acct02', 'auth.rotate', 'success', 'running'],
    'audit successful WHM AUTH rotation without placing the generated secret in event fields');
is($inventory->rotate_auth('acct10')->{error}, 'not_running',
    'preserve a safe failure when the selected AUTH target is not running');
is_deeply($audit[-1], [0, 'acct10', 'auth.rotate', 'not_running', 'unavailable'],
    'audit failed WHM AUTH rotation without recording credential material');
my $rotationCallsBeforeDenial = scalar @Local::FleetManager::AUTH_ROTATE_CALLS;
like(Orm::Broker::Handler->handle_frame($authRotateRequest, 10001, undef, undef, $inventory),
    qr/"error":"not_authorized"/, 'deny non-root peers from fleet AUTH rotation');
is_deeply($audit[-1], [10001, 'acct02', 'auth.rotate', 'not_authorized', 'unavailable'],
    'audit denied AUTH rotation with the kernel peer identity');
is(scalar @Local::FleetManager::AUTH_ROTATE_CALLS, $rotationCallsBeforeDenial,
    'never call the AUTH manager for a non-root rotation request');
ok($inventory->audit_rate_limited(0, 'acct02', 'auth.rotate'), 'record rate-limited AUTH rotation');
is_deeply($audit[-1], [0, 'acct02', 'auth.rotate', 'rate_limited', 'unavailable'],
    'audit AUTH rotation rate limits with fixed metadata only');
my $rootAuthRotation = Orm::Broker::Handler->handle_frame($authRotateRequest, 0, undef, undef, $inventory);
like($rootAuthRotation, qr/"secret":"A{43}"/, 'allow root and return the generated password through the fixed response');
my $control_calls_before_recovery_scan = scalar @Local::FleetManager::CONTROL_CALLS;
my $stoppedScan = $inventory->recovery_scan('acct02');
ok($stoppedScan->{success} && $stoppedScan->{finding} eq 'service_stopped'
    && $stoppedScan->{repair} eq 'start' && $stoppedScan->{state} eq 'stopped',
    'scan a verified stopped instance and offer only the fixed start repair');
is(scalar @Local::FleetManager::CONTROL_CALLS, $control_calls_before_recovery_scan,
    'recovery scans are read-only');
is_deeply($audit[-1], [0, 'acct02', 'recovery.scan', 'success', 'stopped'],
    'audit recovery findings without storing command output');
$Local::FleetManager::CONTROL_STATES{acct03} = 'failed';
my $failedScan = $inventory->recovery_scan('acct03');
ok($failedScan->{success} && $failedScan->{finding} eq 'service_failed' && $failedScan->{repair} eq 'start',
    'offer the fixed start repair for a verified failed service');
$Local::FleetManager::RECOVERY_OWNERSHIP{acct11} = 1;
$Local::FleetManager::CONTROL_STATES{acct11} = 'running';
my $runningOwnershipScan = $inventory->recovery_scan('acct11');
ok($runningOwnershipScan->{success} && $runningOwnershipScan->{finding} eq 'data_directory_ownership'
    && !exists($runningOwnershipScan->{repair}), 'never offer ownership repair while the service is running');
my $healthyScan = $inventory->recovery_scan('acct01');
ok($healthyScan->{success} && $healthyScan->{finding} eq 'service_healthy' && !exists($healthyScan->{repair}),
    'confirm running instances with the existing fixed read-only probes');
$Local::FleetManager::CONTROL_STATES{acct06} = 'running';
my $probeFailureScan = $inventory->recovery_scan('acct06');
ok($probeFailureScan->{success} && $probeFailureScan->{finding} eq 'health_probe_failed'
    && !exists($probeFailureScan->{repair}), 'do not offer a repair when the fixed health probe fails');
is_deeply($audit[-1], [0, 'acct06', 'recovery.scan', 'health_probe_failed', 'running'],
    'record failed health-probe outcomes distinctly from successful scans');
$Local::FleetManager::CONTROL_STATES{acct04} = 'stopping';
my $transitionScan = $inventory->recovery_scan('acct04');
ok($transitionScan->{success} && $transitionScan->{finding} eq 'service_transitioning' && !exists($transitionScan->{repair}),
    'avoid offering repairs during service transitions');
is($inventory->recovery_scan('acct32')->{finding}, 'not_configured',
    'report an account without a verified instance as not configured');
is($inventory->recovery_scan('acct31')->{error}, 'instance_unavailable',
    'collapse broken manifest or ownership state into a safe recovery error');
$Local::FleetManager::RECOVERY_CONFIG_DRIFT{acct07} = 1;
$Local::FleetManager::CONTROL_STATES{acct07} = 'stopped';
my $configDriftScan = $inventory->recovery_scan('acct07');
ok($configDriftScan->{success} && $configDriftScan->{finding} eq 'config_drift'
    && $configDriftScan->{repair} eq 'config_rebuild' && $configDriftScan->{state} eq 'stopped',
    'offer config rebuild only for a stopped instance with a verified drift finding');
my $configRebuildResult = $inventory->recovery_repair('acct07', 'config_rebuild');
ok($configRebuildResult->{success} && $configRebuildResult->{action} eq 'recovery.config_rebuild'
    && $configRebuildResult->{state} eq 'stopped', 'rebuild only the selected stopped account config');
is_deeply($Local::FleetManager::RECOVERY_CONFIG_REBUILD_CALLS[-1], 'acct07',
    'scope config rebuild to the account selected by WHM');
$Local::FleetManager::CONTROL_STATES{acct08} = 'running';
$Local::FleetManager::RECOVERY_CONFIG_DRIFT{acct08} = 1;
my $runningConfigDriftScan = $inventory->recovery_scan('acct08');
ok($runningConfigDriftScan->{success} && $runningConfigDriftScan->{state} eq 'running'
    && !exists($runningConfigDriftScan->{repair}), 'never offer a config rebuild while a service is running');
$Local::FleetManager::RECOVERY_CONFIG_RESET{acct09} = 'config_missing';
$Local::FleetManager::CONTROL_STATES{acct09} = 'stopped';
my $missingConfigScan = $inventory->recovery_scan('acct09');
ok($missingConfigScan->{success} && $missingConfigScan->{finding} eq 'config_missing'
    && $missingConfigScan->{repair} eq 'config_reset' && $missingConfigScan->{state} eq 'stopped',
    'offer a fixed config reset only for a verified missing config on a stopped service');
my $configResetResult = $inventory->recovery_repair('acct09', 'config_reset');
ok($configResetResult->{success} && $configResetResult->{action} eq 'recovery.config_reset'
    && $configResetResult->{state} eq 'stopped' && $configResetResult->{auth_configured}
    && $configResetResult->{secret} eq ('A' x 43), 'return the one-time replacement credential in the reset receipt');
is_deeply($Local::FleetManager::RECOVERY_CONFIG_RESET_CALLS[-1], 'acct09',
    'scope malformed-config reset to the account selected by WHM');
is_deeply($audit[-1], [0, 'acct09', 'recovery.config_reset', 'success', 'stopped'],
    'audit config reset without recording the one-time password');
$Local::FleetManager::RECOVERY_OWNERSHIP{acct10} = 1;
$Local::FleetManager::CONTROL_STATES{acct10} = 'failed';
my $ownershipScan = $inventory->recovery_scan('acct10');
ok($ownershipScan->{success} && $ownershipScan->{finding} eq 'data_directory_ownership'
    && $ownershipScan->{repair} eq 'ownership_fix' && $ownershipScan->{state} eq 'failed',
    'offer ownership repair only for a verified failed instance with an ownership finding');
my $ownershipRepair = $inventory->recovery_repair('acct10', 'ownership_fix');
ok($ownershipRepair->{success} && $ownershipRepair->{action} eq 'recovery.ownership_fix'
    && $ownershipRepair->{state} eq 'failed', 'repair only the selected account data-directory ownership');
is_deeply($Local::FleetManager::RECOVERY_OWNERSHIP_FIX_CALLS[-1], 'acct10',
    'scope ownership repair to the account selected by WHM');
is_deeply($audit[-1], [0, 'acct10', 'recovery.ownership_fix', 'success', 'failed'],
    'audit ownership repair with its fixed action and no data details');
$Local::FleetManager::CONTROL_STATES{acct05} = { unexpected => 'state' };
is($inventory->recovery_scan('acct05')->{error}, 'instance_unavailable',
    'reject non-scalar service states from the status provider');
is($inventory->recovery_scan('../root')->{error}, 'invalid_request',
    'reject malformed recovery targets before lookup');
my $recoveryResult = $inventory->recovery_repair('acct02', 'start');
ok($recoveryResult->{success} && $recoveryResult->{action} eq 'recovery.start'
    && $recoveryResult->{state} eq 'starting', 'start only the selected account after a fresh scan');
is_deeply($Local::FleetManager::RECOVERY_CALLS[-1], 'acct02', 'scope recovery repairs to one selected account');
my $calls_before_inapplicable_repair = scalar @Local::FleetManager::RECOVERY_CALLS;
is($inventory->recovery_repair('acct01', 'start')->{error}, 'repair_not_applicable',
    'refuse a start repair after a fresh scan finds a healthy service');
is(scalar @Local::FleetManager::RECOVERY_CALLS, $calls_before_inapplicable_repair,
    'do not call the repair method when a fresh scan has no repair finding');
my $calls_before_recovery_denial = scalar @Local::FleetManager::RECOVERY_CALLS;
my $nonRootRecoveryScan = Orm::Broker::Handler->handle_frame($recoveryScanRequest, 10001, undef, undef, $inventory);
like($nonRootRecoveryScan, qr/"error":"not_authorized"/, 'deny non-root recovery scans');
is_deeply($audit[-1], [10001, 'acct02', 'recovery.scan', 'not_authorized', 'unavailable'],
    'audit denied scans with the kernel peer UID');
my $nonRootRecoveryRepair = Orm::Broker::Handler->handle_frame($recoveryRepairRequest, 10001, undef, undef, $inventory);
like($nonRootRecoveryRepair, qr/"error":"not_authorized"/, 'deny non-root recovery repairs');
is_deeply($audit[-1], [10001, 'acct02', 'recovery.start', 'not_authorized', 'unavailable'],
    'audit denied repairs with the kernel peer UID');
ok($inventory->audit_rate_limited(10001, 'acct02', 'recovery.scan'),
    'record recovery requests rejected by the broker rate limiter');
is_deeply($audit[-1], [10001, 'acct02', 'recovery.scan', 'rate_limited', 'unavailable'],
    'rate-limit audit contains only actor, account, fixed action and outcome');
is(scalar @Local::FleetManager::RECOVERY_CALLS, $calls_before_recovery_denial,
    'non-root recovery requests never reach the repair method');
$Local::FleetManager::CONTROL_STATES{acct02} = 'stopped';
my $rootRecoveryScan = Orm::Broker::Handler->handle_frame($recoveryScanRequest, 0, undef, undef, $inventory);
like($rootRecoveryScan, qr/"finding":"service_stopped"/, 'allow root peers to scan one selected account');
my $rootRecoveryRepair = Orm::Broker::Handler->handle_frame($recoveryRepairRequest, 0, undef, undef, $inventory);
like($rootRecoveryRepair, qr/"action":"recovery.start"/, 'allow root peers to invoke the fixed recovery repair');
$Local::FleetManager::CONTROL_STATES{acct07} = 'stopped';
my $rootConfigRecoveryScan = Orm::Broker::Handler->handle_frame($recoveryConfigScanRequest, 0, undef, undef, $inventory);
like($rootConfigRecoveryScan, qr/"finding":"config_drift"/, 'allow root to scan config drift without exposing file contents');
my $rootConfigRecoveryRepair = Orm::Broker::Handler->handle_frame($recoveryConfigRepairRequest, 0, undef, undef, $inventory);
like($rootConfigRecoveryRepair, qr/"action":"recovery\.config_rebuild"/, 'allow root peers to invoke the fixed config rebuild');
$Local::FleetManager::CONTROL_STATES{acct09} = 'stopped';
my $rootConfigResetScan = Orm::Broker::Handler->handle_frame(
    '{"operation":"fleet.recovery.scan","username":"acct09","version":1}' . "\n", 0, undef, undef, $inventory);
like($rootConfigResetScan, qr/"repair":"config_reset"/, 'allow root to scan and receive the fixed config-reset action');
my $rootConfigReset = Orm::Broker::Handler->handle_frame($recoveryConfigResetRequest, 0, undef, undef, $inventory);
like($rootConfigReset, qr/"action":"recovery\.config_reset".*"secret":"A{43}"/,
    'allow root to receive the one-time password from the fixed reset repair');
$Local::FleetManager::RECOVERY_OWNERSHIP{acct10} = 1;
$Local::FleetManager::CONTROL_STATES{acct10} = 'failed';
my $rootOwnershipScan = Orm::Broker::Handler->handle_frame(
    '{"operation":"fleet.recovery.scan","username":"acct10","version":1}' . "\n", 0, undef, undef, $inventory);
like($rootOwnershipScan, qr/"finding":"data_directory_ownership".*"repair":"ownership_fix"/,
    'allow root to scan and receive the fixed ownership-repair action');
my $rootOwnershipFix = Orm::Broker::Handler->handle_frame($recoveryOwnershipRepairRequest, 0, undef, undef, $inventory);
like($rootOwnershipFix, qr/"action":"recovery\.ownership_fix"/,
    'allow root peers to invoke the fixed ownership repair');

my $controlRequest = '{"action":"start","operation":"fleet.control","username":"acct01","version":1}' . "\n";
is(parse_request($controlRequest)->{operation}, 'fleet.control', 'accept the fixed root fleet-control request');
ok(!parse_request('{"action":"start","operation":"fleet.control","unit":"other","username":"acct01","version":1}' . "\n"),
    'reject fleet control requests with an arbitrary unit field');
my $controlResponse = $inventory->control('acct01', 'stop');
ok($controlResponse->{success} && $controlResponse->{username} eq 'acct01'
    && $controlResponse->{action} eq 'stop' && $controlResponse->{state} eq 'stopped',
    'control only the validated target account through a fixed action method');
is_deeply($Local::FleetManager::CONTROL_CALLS[-1], ['stop', 'acct01'], 'never pass a caller-selected unit to the manager');
is_deeply($audit[-1], [0, 'acct01', 'stop', 'success', 'stopped'], 'audit actor, account, action, result, and state without secrets');
is($inventory->control('acct32', 'start')->{error}, 'not_configured', 'do not start an account without an ORM manifest');
is($inventory->control('acct99', 'start')->{error}, 'account_unavailable', 'reject accounts absent from trusted system lookup');
is($inventory->control('../root', 'start')->{error}, 'invalid_request', 'reject malformed account names before lookup');
is($inventory->control('acct01', 'status')->{error}, 'invalid_request', 'reject actions outside start, stop, and restart');
my $calls_before_denial = scalar @Local::FleetManager::CONTROL_CALLS;
my $nonRootControl = Orm::Broker::Handler->handle_frame($controlRequest, 10001, undef, undef, $inventory);
like($nonRootControl, qr/"error":"not_authorized"/, 'deny non-root peers before target lookup and control');
is_deeply($audit[-1], [10001, 'acct01', 'start', 'not_authorized', 'unavailable'],
    'audit denied control attempts using the kernel peer UID');
is(scalar @Local::FleetManager::CONTROL_CALLS, $calls_before_denial, 'non-root control never reaches service methods');
$Local::FleetManager::CONTROL_STATES{acct01} = 'stopped';
my $calls_before_stopped_restart = scalar @Local::FleetManager::CONTROL_CALLS;
is($inventory->control('acct01', 'restart')->{error}, 'instance_unavailable', 'reject restart for a stopped instance');
is(scalar @Local::FleetManager::CONTROL_CALLS, $calls_before_stopped_restart, 'do not invoke restart for a stopped instance');
$Local::FleetManager::CONTROL_STATES{acct01} = 'running';
my $rootControl = Orm::Broker::Handler->handle_frame($controlRequest, 0, undef, undef, $inventory);
like($rootControl, qr/"success":true/, 'allow root peers to use the fixed fleet-control operation');
like($rootControl, qr/"audit_logged":true/, 'report whether the action outcome was recorded');
my $noAuditInventory = Orm::Broker::FleetInventory->new(
    resolver => Local::FleetResolver->new(),
    instance_manager => Local::FleetManager->new(),
    audit => sub { die "audit unavailable"; },
);
my $noAuditControl = $noAuditInventory->control('acct01', 'restart');
ok($noAuditControl->{success} && !$noAuditControl->{audit_logged}
    && $noAuditControl->{state} eq 'starting',
    'report the service outcome separately when audit delivery cannot be confirmed');

my $backup_id = 'snapshot-1794760000-a1b2c3d4.rdb';
$Local::FleetManager::BACKUPS{acct01} = [{ id => $backup_id, created_at => 1794760000, size_bytes => 4096 }];
my $backup_page = $inventory->page(0);
ok($backup_page->{entries}[0]->{backups_available}
    && $backup_page->{entries}[0]->{backups}[0]->{id} eq $backup_id,
    'include only bounded validated account snapshot metadata on its fleet row');
my $create_response = $inventory->backup('acct01', 'backup.create');
ok($create_response->{success} && $create_response->{backup}->{id} eq $backup_id,
    'create a snapshot for the resolved account');
is_deeply($Local::FleetManager::BACKUP_CALLS[-1], ['create', 'acct01'],
    'never pass a caller-selected account path to backup creation');
my $restore_response = $inventory->backup('acct01', 'backup.restore', $backup_id);
ok($restore_response->{success} && $restore_response->{backup_id} eq $backup_id
    && $restore_response->{safety_backup_id} eq 'snapshot-1794760001-b2c3d4e5.rdb',
    'return the selected snapshot and generated safety snapshot for restore');
is_deeply($Local::FleetManager::BACKUP_CALLS[-1], ['restore', 'acct01', $backup_id],
    'restore only the selected validated snapshot of the resolved account');
is_deeply($audit[-1], [0, 'acct01', 'backup.restore', 'success', 'running'],
    'audit root fleet restore outcome without snapshot contents');
my $migration_result = $inventory->migrate('acct01', 'valkey', 1);
ok($migration_result->{success} && $migration_result->{target_backend} eq 'valkey'
    && $migration_result->{safety_backup_id} eq $backup_id,
    'migrate a resolved Redis account and return only the retained safety snapshot');
is_deeply($Local::FleetManager::MIGRATION_CALLS[-1], ['acct01'],
    'migrate only the account resolved from the trusted name lookup');
is_deeply($audit[-1], [0, 'acct01', 'migration.to-valkey', 'success', 'running'],
    'audit migration outcome without Redis contents or credentials');
is($inventory->migrate('acct01', 'redis', 1)->{error}, 'invalid_request',
    'accept only the fixed Valkey migration target');
is($inventory->migrate('acct01', 'valkey', 0)->{error}, 'invalid_request',
    'require an explicit application-writer quiescence acknowledgement');
is($inventory->migrate('acct99', 'valkey', 1)->{error}, 'account_unavailable',
    'reject migration for an account absent from the trusted system lookup');
my $migrationRequest = '{"operation":"fleet.migrate","target_backend":"valkey","username":"acct01","version":1,"writes_quiesced":true}' . "\n";
is(parse_request($migrationRequest)->{operation}, 'fleet.migrate', 'accept the fixed root migration request');
ok(!parse_request('{"operation":"fleet.migrate","target_backend":"redis","username":"acct01","version":1,"writes_quiesced":true}' . "\n")
    && !parse_request('{"operation":"fleet.migrate","target_backend":"valkey","username":"acct01","version":1,"writes_quiesced":false}' . "\n")
    && !parse_request('{"operation":"fleet.migrate","target_backend":"valkey","username":"acct01","path":"/tmp/x","version":1,"writes_quiesced":true}' . "\n"),
    'reject a mutable target, missing write-quiescence acknowledgement, and extra migration fields');
my $nonRootMigration = Orm::Broker::Handler->handle_frame($migrationRequest, 10001, undef, undef, $inventory);
like($nonRootMigration, qr/"error":"not_authorized"/, 'deny non-root peers from account migration');
is_deeply($audit[-1], [10001, 'acct01', 'migration.to-valkey', 'not_authorized', 'unavailable'],
    'audit denied migration using only the kernel peer identity');
my $calls_before_migration = scalar @Local::FleetManager::MIGRATION_CALLS;
my $rootMigration = Orm::Broker::Handler->handle_frame($migrationRequest, 0, undef, undef, $inventory);
like($rootMigration, qr/"target_backend":"valkey"/, 'allow root to request the fixed Valkey migration');
is(scalar @Local::FleetManager::MIGRATION_CALLS, $calls_before_migration + 1,
    'route an authorized migration to the account manager exactly once');
is($inventory->backup('acct99', 'backup.create')->{error}, 'account_unavailable',
    'reject fleet backup actions for accounts absent from trusted lookup');
is($inventory->backup('../root', 'backup.create')->{error}, 'invalid_request',
    'reject malformed account names before backup lookup');
is($inventory->backup('acct01', 'backup.restore', '../dump.rdb')->{error}, 'invalid_request',
    'reject caller-supplied backup paths');
my $fleetBackupRequest = '{"operation":"fleet.backup.create","username":"acct01","version":1}' . "\n";
is(parse_request($fleetBackupRequest)->{operation}, 'fleet.backup.create', 'accept canonical fleet snapshot creation request');
ok(!parse_request('{"operation":"fleet.backup.create","username":"acct01","path":"/tmp/x","version":1}' . "\n"),
    'reject extra fields in fleet snapshot requests');
my $nonRootBackup = Orm::Broker::Handler->handle_frame($fleetBackupRequest, 10001, undef, undef, $inventory);
like($nonRootBackup, qr/"error":"not_authorized"/, 'deny non-root fleet snapshot operations');
is_deeply($audit[-1], [10001, 'acct01', 'backup.create', 'not_authorized', 'unavailable'],
    'record denied backup attempts using the kernel peer UID');
my $rootBackup = Orm::Broker::Handler->handle_frame($fleetBackupRequest, 0, undef, undef, $inventory);
like($rootBackup, qr/"success":true/, 'allow root to request an account snapshot through the broker');

my $batchNow = 2000;
my $batchInventory = Orm::Broker::FleetInventory->new(
    instance_root => $instance_root, expected_owner_uid => $<,
    resolver => Local::FleetResolver->new(), instance_manager => Local::FleetManager->new(),
    lookup_name => sub { $_[0] =~ /\Aacct([0-9]{2})\z/ ? { uid => 10000 + $1 } : undef },
    clock => sub { $batchNow }, audit => sub { push @audit, [@_]; },
);
my $batchResult = $batchInventory->backup_batch('create', [
    { username => 'acct01' }, { username => 'acct99' },
]);
ok($batchResult->{success} && $batchResult->{partial} && $batchResult->{succeeded_count} == 1,
    'continue a bounded backup batch after one account lookup fails');
is($batchResult->{results}[0]->{username}, 'acct01', 'preserve batch outcome order');
is($batchResult->{results}[1]->{error}, 'account_unavailable', 'report a per-account failure in the batch result');
my $batchRequest = '{"operation":"fleet.backup.batch.create","targets":["acct01","acct02"],"version":1}' . "\n";
like(Orm::Broker::Handler->handle_frame($batchRequest, 10001, undef, undef, $batchInventory),
    qr/"error":"not_authorized"/, 'deny a batch snapshot request from non-root');
my $rateNow = 3000;
my $rateBatchInventory = Orm::Broker::FleetInventory->new(
    instance_root => $instance_root, expected_owner_uid => $<,
    resolver => Local::FleetResolver->new(), instance_manager => Local::FleetManager->new(),
    lookup_name => sub { $_[0] =~ /\Aacct([0-9]{2})\z/ ? { uid => 10000 + $1 } : undef },
    clock => sub { $rateNow }, audit => sub { push @audit, [@_]; },
);
my $isolatedRateResult = $rateBatchInventory->backup_batch('create', [
    { username => 'acct01' }, { username => 'acct02' },
], { acct01 => 1 });
ok($isolatedRateResult->{partial} && $isolatedRateResult->{results}[0]->{error} eq 'rate_limited'
    && $isolatedRateResult->{results}[1]->{success}, 'isolate per-account rate limiting inside a batch');
my $globalRateResult = $batchInventory->backup_batch('create', [{ username => 'acct02' }]);
is($globalRateResult->{results}[0]->{error}, 'rate_limited', 'apply a short global cooldown to repeated batches');

chmod(0777, $instance_root) or die "weaken instance root: $!";
ok(!$inventory->page(0)->{success}, 'fail closed when the metadata root is writable by others');

done_testing();
