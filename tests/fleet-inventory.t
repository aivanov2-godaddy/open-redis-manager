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
    our @CONTROL_CALLS;
    our %CONTROL_STATES;
    our @BACKUP_CALLS;
    our %BACKUPS;
    our @MIGRATION_CALLS;
    our @DIAGNOSTICS_CALLS;
    our @RECOVERY_HEALTH_CALLS;
    our @RECOVERY_CALLS;
    our %RECOVERY_ERRORS;
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
    sub backups {
        my ($self, $account) = @_;
        return { success => 1, backups => $BACKUPS{$account->{name}} // [] };
    }
    sub backend { return $_[1]->{name} eq 'acct01' ? 'redis' : 'valkey'; }
    sub migrate_to_valkey {
        my ($self, $account) = @_;
        push @MIGRATION_CALLS, [$account->{name}];
        return {
            success => 1, backup_id => 'snapshot-1794760000-a1b2c3d4.rdb',
            source_backend => 'redis', target_backend => 'valkey', state => 'running',
        };
    }
    sub read_diagnostics {
        my ($self, $account) = @_;
        push @DIAGNOSTICS_CALLS, $account->{name};
        return { success => 0, error => 'not_running' } if $account->{name} ne 'acct01';
        return {
            success => 1,
            state => 'running',
            diagnostics => {
                backend => 'redis', server_version => '7.2.4', uptime_seconds => 3600,
                memory_used_bytes => 1048576, memory_peak_bytes => 2097152, maxmemory_bytes => 67108864,
                connected_clients => 3, blocked_clients => 0, maxclients => 100,
                commands_per_second => 12, database_keys => 42, keyspace_hits => 90,
                keyspace_misses => 10, expired_keys => 4, evicted_keys => 2,
            },
        };
    }
    sub recovery_health_check {
        my ($self, $account) = @_;
        push @RECOVERY_HEALTH_CALLS, $account->{name};
        return { success => $account->{name} eq 'acct01' ? 1 : 0 };
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

my $diagnostics_request = '{"operation":"fleet.diagnostics","username":"acct01","version":1}' . "\n";
is(parse_request($diagnostics_request)->{operation}, 'fleet.diagnostics', 'parse the fixed read-only diagnostics request');
ok(!parse_request('{"command":"INFO","operation":"fleet.diagnostics","username":"acct01","version":1}' . "\n"),
    'reject caller-provided commands at the broker protocol boundary');
my $diagnostics = $inventory->diagnostics('acct01');
ok($diagnostics->{success} && $diagnostics->{diagnostics}->{database_keys} == 42
    && $diagnostics->{diagnostics}->{server_version} eq '7.2.4',
    'return only validated diagnostic metrics for the selected running account');
my %diagnostics_at_numeric_boundary = %{$diagnostics->{diagnostics}};
$diagnostics_at_numeric_boundary{database_keys} = 9_000_000_000_000_000;
ok(Orm::Broker::FleetInventory::_valid_diagnostics(\%diagnostics_at_numeric_boundary),
    'accept diagnostics integers within the shared PHP-safe boundary');
$diagnostics_at_numeric_boundary{database_keys}++;
ok(!Orm::Broker::FleetInventory::_valid_diagnostics(\%diagnostics_at_numeric_boundary),
    'reject diagnostics integers above the shared PHP-safe boundary');
is_deeply($Local::FleetManager::DIAGNOSTICS_CALLS[-1], 'acct01', 'route diagnostics only to the trusted selected account');
is_deeply($audit[-1], [0, 'acct01', 'diagnostics.read', 'success', 'running'],
    'audit diagnostic reads without storing command output or values');
is($inventory->diagnostics('acct02')->{error}, 'not_running', 'require a running instance for diagnostics');
is($inventory->diagnostics('../root')->{error}, 'invalid_request', 'reject malformed diagnostics targets');
my $calls_before_diagnostics_denial = scalar @Local::FleetManager::DIAGNOSTICS_CALLS;
my %non_root_diagnostics_rate;
ok(Orm::Broker::Server::_rate_allowed(\%non_root_diagnostics_rate, 10001, 10, 1, 1, 5, 'fleet.diagnostics:acct01'),
    'let the broker authorization handler inspect the first non-root diagnostics request');
my $nonRootDiagnostics = Orm::Broker::Handler->handle_frame($diagnostics_request, 10001, undef, undef, $inventory);
like($nonRootDiagnostics, qr/"error":"not_authorized"/, 'deny non-root peers before diagnostic probes');
is(scalar @Local::FleetManager::DIAGNOSTICS_CALLS, $calls_before_diagnostics_denial,
    'non-root diagnostic requests never reach the instance manager');
is_deeply($audit[-1], [10001, 'acct01', 'diagnostics.read', 'not_authorized', 'unavailable'],
    'record denied diagnostic attempts using the kernel peer UID');
my $rootDiagnostics = Orm::Broker::Handler->handle_frame($diagnostics_request, 0, undef, undef, $inventory);
like($rootDiagnostics, qr/"success":true/, 'allow root peers to request bounded read-only diagnostics');

my $recoveryScanRequest = '{"operation":"fleet.recovery.scan","username":"acct02","version":1}' . "\n";
my $recoveryRepairRequest = '{"repair":"start","operation":"fleet.recovery.repair","username":"acct02","version":1}' . "\n";
is(parse_request($recoveryScanRequest)->{operation}, 'fleet.recovery.scan', 'parse the fixed read-only recovery scan request');
is(parse_request($recoveryRepairRequest)->{repair}, 'start', 'parse only the fixed start repair');
ok(!parse_request('{"command":"systemctl start","operation":"fleet.recovery.repair","repair":"start","username":"acct02","version":1}' . "\n"),
    'reject arbitrary commands from recovery requests');
ok(!parse_request('{"operation":"fleet.recovery.repair","repair":"chmod","username":"acct02","version":1}' . "\n"),
    'reject recovery actions outside the fixed start repair');
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

chmod(0777, $instance_root) or die "weaken instance root: $!";
ok(!$inventory->page(0)->{success}, 'fail closed when the metadata root is writable by others');

done_testing();
