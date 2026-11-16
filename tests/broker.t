use strict;
use warnings;
use Errno qw(ENOSPC);
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use Fcntl qw(:mode :flock);
use MIME::Base64 qw(encode_base64);
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);
use lib 'src';
use Orm::Broker::AccountResolver;
use Orm::Broker::Handler;
use Orm::Broker::BackendPolicy;
use Orm::Broker::ProviderPolicy;
use Orm::Broker::InstanceManager;
use Orm::Broker::PeerCredentials;
use Orm::Broker::Server;
use Orm::Broker::Protocol qw(parse_request encode_response max_frame_bytes);

my $request = '{"operation":"identity","version":1}' . "\n";
is(parse_request($request)->{operation}, 'identity', 'accept the one canonical identity request');
for my $operation (qw(instance.status instance.auth.status instance.auth.rotate instance.auth.disable instance.provision instance.start instance.stop provider.exposure provider.branding provider.resellers)) {
    my $frame = '{"operation":"' . $operation . '","version":1}' . "\n";
is(parse_request($frame)->{operation}, $operation, "accept fixed operation $operation");
}
is(parse_request('{"operation":"fleet.summary","version":1}' . "\n")->{operation},
    'fleet.summary', 'accept the fixed root fleet summary request');
my $batch_create = parse_request('{"operation":"fleet.backup.batch.create","targets":["acct01","acct02"],"version":1}' . "\n");
ok($batch_create && $batch_create->{operation} eq 'fleet.backup.batch.create'
    && $batch_create->{targets}[1]->{username} eq 'acct02', 'accept a bounded batch snapshot request');
my $batch_restore = parse_request('{"operation":"fleet.backup.batch.restore","targets":[{"backup_id":"snapshot-1794760000-a1b2c3d4.rdb","username":"acct01"}],"version":1}' . "\n");
ok($batch_restore && $batch_restore->{targets}[0]->{backup_id} eq 'snapshot-1794760000-a1b2c3d4.rdb',
    'accept only account-scoped snapshot IDs in a batch restore');
ok(!parse_request('{"operation":"fleet.backup.batch.create","targets":["acct01","acct01"],"version":1}' . "\n")
    && !parse_request('{"operation":"fleet.backup.batch.restore","targets":[{"backup_id":"snapshot-1794760000-a1b2c3d4.rdb","username":"acct01"},{"backup_id":"snapshot-1794760000-a1b2c3d4.rdb","username":"acct01"}],"version":1}' . "\n")
    && !parse_request('{"operation":"fleet.backup.batch.create","targets":["acct01","acct02","acct03"],"version":1}' . "\n"),
    'reject duplicate and oversized fleet batch targets');
is(parse_request('{"operation":"instance.metrics","version":1}' . "\n")->{operation},
    'instance.metrics', 'accept the fixed instance metrics request');
for my $operation (qw(backup.list backup.create)) {
    is(parse_request('{"operation":"' . $operation . '","version":1}' . "\n")->{operation},
        $operation, "accept fixed $operation request");
}
is(parse_request('{"operation":"fleet.backup.create","username":"acct01","version":1}' . "\n")->
    { operation }, 'fleet.backup.create', 'accept a canonical root fleet backup request');
my $fleet_diagnostics_request = '{"operation":"fleet.diagnostics","username":"acct01","version":1}' . "\n";
is(parse_request($fleet_diagnostics_request)->{operation}, 'fleet.diagnostics',
    'accept a canonical root read-only diagnostics request');
my $fleet_restore = parse_request('{"backup_id":"snapshot-1794760000-a1b2c3d4.rdb","operation":"fleet.backup.restore","username":"acct01","version":1}' . "\n");
ok($fleet_restore && $fleet_restore->{backup_id} eq 'snapshot-1794760000-a1b2c3d4.rdb'
    && $fleet_restore->{username} eq 'acct01', 'accept a canonical account-scoped fleet restore request');
my $fleet_migration_request = '{"operation":"fleet.migrate","target_backend":"valkey","username":"acct01","version":1,"writes_quiesced":true}' . "\n";
my $fleet_migration = parse_request($fleet_migration_request);
ok($fleet_migration && $fleet_migration->{operation} eq 'fleet.migrate'
    && $fleet_migration->{target_backend} eq 'valkey' && $fleet_migration->{writes_quiesced},
    'accept only an acknowledged root Redis-to-Valkey migration request');
for my $range (qw(24h 7d)) {
    is(parse_request('{"operation":"metrics.history","range":"' . $range . '","version":1}' . "\n")->{range},
        $range, "accept a canonical $range metrics history request");
}
my $restore_request = '{"backup_id":"snapshot-1794760000-a1b2c3d4.rdb","operation":"backup.restore","version":1}' . "\n";
is(parse_request($restore_request)->{operation}, 'backup.restore', 'accept a canonical selected-backup restore request');
is(parse_request($restore_request)->{backup_id}, 'snapshot-1794760000-a1b2c3d4.rdb', 'retain only the selected snapshot identifier');
my $config_request = '{"maxclients":50,"maxmemory_policy":"allkeys-lru","memory_mib":48,"operation":"instance.configure","timeout":0,"version":1}' . "\n";
my $parsed_config = parse_request($config_request);
ok($parsed_config && $parsed_config->{operation} eq 'instance.configure'
    && $parsed_config->{memory_mib} == 48 && $parsed_config->{maxclients} == 50,
    'accept the canonical bounded instance configuration request');
for my $preset (qw(wordpress laravel magento session generic)) {
    my $frame = '{"operation":"instance.provision","preset":"' . $preset . '","version":1}' . "\n";
    is(parse_request($frame)->{preset}, $preset, "accept the fixed $preset provisioning preset");
}
for my $invalid (
    '', '{}', $request . "\n", '{"version":1,"operation":"identity"}' . "\n",
    '{"operation":"identity","version":2}' . "\n", ('x' x (max_frame_bytes() + 1)),
    '{"operation":"instance.provision","preset":"../../root","version":1}' . "\n",
    '{"operation":"instance.start","preset":"generic","version":1}' . "\n",
    '{"operation":"instance.auth.rotate","secret":"client-chosen","version":1}' . "\n",
    '{"maxclients":50,"maxmemory_policy":"allkeys-lru","memory_mib":65,"operation":"instance.configure","timeout":0,"version":1}' . "\n",
    '{"maxclients":50,"maxmemory_policy":"allkeys-lru","memory_mib":"48","operation":"instance.configure","timeout":0,"version":1}' . "\n",
    '{"maxclients":101,"maxmemory_policy":"allkeys-lru","memory_mib":48,"operation":"instance.configure","timeout":0,"version":1}' . "\n",
    '{"maxclients":50,"maxmemory_policy":"arbitrary","memory_mib":48,"operation":"instance.configure","timeout":0,"version":1}' . "\n",
    '{"maxclients":50,"maxmemory_policy":"allkeys-lru","memory_mib":48,"operation":"instance.configure","timeout":301,"version":1}' . "\n",
    '{"operation":"instance.configure","maxclients":50,"maxmemory_policy":"allkeys-lru","memory_mib":48,"timeout":0,"version":1}' . "\n",
    '{"backup_id":"../other.rdb","operation":"backup.restore","version":1}' . "\n",
    '{"operation":"fleet.backup.create","username":"acct01","path":"/tmp/x","version":1}' . "\n",
    '{"operation":"fleet.summary","version":1,"scope":"all"}' . "\n",
    '{"operation":"fleet.backup.batch.create","targets":["acct01","../root"],"version":1}' . "\n",
    '{"command":"CONFIG SET dir /tmp","operation":"fleet.diagnostics","username":"acct01","version":1}' . "\n",
    '{"backup_id":"../x.rdb","operation":"fleet.backup.restore","username":"acct01","version":1}' . "\n",
    '{"backup_id":"snapshot-1794760000-a1b2c3d4.rdb","operation":"backup.restore","path":"/tmp/other.rdb","version":1}' . "\n",
    '{"operation":"fleet.migrate","target_backend":"redis","username":"acct01","version":1,"writes_quiesced":true}' . "\n",
    '{"operation":"fleet.migrate","target_backend":"valkey","username":"acct01","version":1,"writes_quiesced":false}' . "\n",
    '{"operation":"fleet.migrate","target_backend":"valkey","username":"acct01","path":"/tmp/x","version":1,"writes_quiesced":true}' . "\n",
    '{"operation":"backup.restore","backup_id":"snapshot-1794760000-a1b2c3d4.rdb","version":1}' . "\n",
    '{"operation":"metrics.history","range":"30d","version":1}' . "\n",
    '{"range":"24h","operation":"metrics.history","version":1}' . "\n",
) {
    ok(!parse_request($invalid), 'reject a non-canonical or oversized request');
}
like(encode_response({ success => JSON::PP::true, version => 1 }), qr/\n\z/, 'responses end in one line feed');
ok(!encode_response([]), 'response encoder rejects non-object payloads');
ok(!encode_response({ payload => 'x' x 262144 }), 'response encoder rejects oversized broker frames');

my $tmp = tempdir(CLEANUP => 1);
my $account_root = "$tmp/accounts";
my @test_groups = split /\s+/, $);
my $test_gid = 0 + ($test_groups[0] // $<);
make_path($account_root);
chmod(0755, $account_root) or die "chmod account root: $!";
my $account_file = "$account_root/ormtest";
open(my $file, '>', $account_file) or die "create account fixture: $!";
print {$file} "SHELL=/bin/bash\nPLAN=starter\nOWNER=reseller1\n";
close($file) or die "close account fixture: $!";
chmod(0644, $account_file) or die "chmod account fixture: $!";

my $resolver = Orm::Broker::AccountResolver->new(
    account_root => $account_root,
    expected_owner_uid => $<,
    restore_state_timeout => 1,
    lookup => sub { return { name => 'ormtest', uid => $_[0], gid => $test_gid }; },
    lookup_name => sub { return { name => $_[0], uid => 43210, gid => $test_gid } if $_[0] eq 'ormtest'; return undef; },
);
is($resolver->resolve_uid(43210), 'ormtest', 'resolve a mapped UID through a trusted account record');
is_deeply($resolver->resolve_account(43210), { name => 'ormtest', uid => 43210, gid => $test_gid, plan => 'starter', owner => 'reseller1' }, 'resolve trusted UID, primary GID, package and owner');
is_deeply($resolver->resolve_name('ormtest'), { name => 'ormtest', uid => 43210, gid => $test_gid, plan => 'starter', owner => 'reseller1' },
    'resolve an administrator-selected account name through its trusted account record');
ok(!defined($resolver->resolve_name('../root')), 'reject unsafe target names before account lookup');
ok(!defined($resolver->resolve_name('missing')), 'reject names absent from trusted account lookup');
ok(!defined($resolver->resolve_uid(0)), 'reject root identity');
ok(!defined($resolver->resolve_uid(undef)), 'reject missing UID');

SKIP: {
    skip 'POSIX permission checks run on Linux CI', 1
        if $^O eq 'MSWin32' || ($^O eq 'cygwin' && $ENV{WINDIR});
    chmod(0666, $account_file) or die "make writable account fixture: $!";
    ok(!defined($resolver->resolve_uid(43210)), 'reject group/world-writable account file');
    chmod(0644, $account_file) or die "restore account fixture mode: $!";
}
unlink($account_file) or die "remove account fixture: $!";
SKIP: {
    skip 'POSIX symlink checks run on Linux CI', 1
        if $^O eq 'MSWin32' || ($^O eq 'cygwin' && $ENV{WINDIR});
    symlink("$tmp/outside", $account_file) or die "create symlink fixture: $!";
    ok(!defined($resolver->resolve_uid(43210)), 'reject a symlink account file');
    unlink($account_file) or die "remove symlink fixture: $!";
}
open($file, '>', $account_file) or die "recreate account fixture: $!";
print {$file} ('x' x 1_048_577);
close($file) or die "close oversized fixture: $!";
chmod(0644, $account_file) or die "chmod oversized fixture: $!";
ok(!defined($resolver->resolve_uid(43210)), 'reject oversized account file');
unlink($account_file) or die "remove oversized account fixture: $!";
open($file, '>', $account_file) or die "restore account fixture: $!";
print {$file} "SHELL=/bin/bash\n";
close($file) or die "close restored account fixture: $!";
chmod(0644, $account_file) or die "chmod restored account fixture: $!";

my $unsafe_resolver = Orm::Broker::AccountResolver->new(
    account_root => $account_root,
    expected_owner_uid => $<,
    lookup => sub { return { name => '../root', uid => $_[0], gid => $< }; },
);
ok(!defined($unsafe_resolver->resolve_uid(43210)), 'reject unsafe mapped account names');

my $denied = Orm::Broker::Handler->handle_frame($request, 0, $resolver);
like($denied, qr/"success":false/, 'handler denies root peer identity');
my $invalid = Orm::Broker::Handler->handle_frame('{}' . "\n", 43210, $resolver);
like($invalid, qr/"error":"invalid_request"/, 'handler returns a generic invalid-request response');
my $reseller_denied = Orm::Broker::Handler->handle_frame(
    '{"operation":"provider.resellers","version":1}' . "\n", 43210, $resolver,
);
like($reseller_denied, qr/"error":"not_authorized"/, 'reseller usage summary is root-only at the broker boundary');

my $etc_instances = "$tmp/etc/instances";
my $data_instances = "$tmp/var/lib/instances";
make_path($etc_instances, $data_instances);
chmod(0750, $etc_instances) or die "chmod instance config root: $!";
chmod(0700, $data_instances) or die "chmod instance data root: $!";
my $policy_path = "$tmp/etc/backend-policy.json";
open(my $policy_file, '>', $policy_path) or die "create backend policy: $!";
print {$policy_file} '{"backend":"redis","version":1}' . "\n";
close($policy_file) or die "close backend policy: $!";
chmod(0600, $policy_path) or die "chmod backend policy: $!";
my $policy = Orm::Broker::BackendPolicy->new(path => $policy_path, expected_owner_uid => $<);
is($policy->selected_backend(), 'redis', 'read a root-owned explicit backend policy');

my $provider_policy_path = "$tmp/etc/provider-policy.json";
my @policy_audit;
my $provider_policy = Orm::Broker::ProviderPolicy->new(
    path => $provider_policy_path,
    expected_owner_uid => $<,
    audit => sub { push @policy_audit, $_[0]; return 1; },
);
my $policy_account = { name => 'policyacct', uid => 43210, gid => $test_gid, plan => 'starter', owner => 'reseller1' };
my $default_decision = $provider_policy->provision_decision($policy_account, 64);
ok($default_decision && $default_decision->{allowed} && $default_decision->{mode} eq 'report-only'
    && $default_decision->{max_memory_mib} == 64, 'missing provider policy uses the non-blocking report-only default');
my $enforced_package_policy = {
    version => 1,
    mode => 'enforce',
    default => { enabled => JSON::PP::true, max_memory_mib => 64, backup_retention => 3 },
    packages => {
        starter => { enabled => JSON::PP::true, max_memory_mib => 16, backup_retention => 2 },
        blocked => { enabled => JSON::PP::false, max_memory_mib => 8, backup_retention => 2 },
    },
};
open(my $provider_policy_file, '>', $provider_policy_path) or die "create provider policy: $!";
print {$provider_policy_file} JSON::PP->new->canonical(1)->encode($enforced_package_policy) . "\n";
close($provider_policy_file) or die "close provider policy: $!";
chmod(0600, $provider_policy_path) or die "chmod provider policy: $!";
my $over_limit = $provider_policy->provision_decision($policy_account, 32);
ok($over_limit && !$over_limit->{allowed} && $over_limit->{violations}->[0] eq 'memory_limit_exceeded'
    && $over_limit->{max_memory_mib} == 16, 'enforce a package memory ceiling on new provisioning');
my $within_limit = $provider_policy->provision_decision($policy_account, 16);
ok($within_limit && $within_limit->{allowed}, 'allow provisioning within the package memory ceiling');
my $disabled_package = $provider_policy->provision_decision({%{$policy_account}, plan => 'blocked'}, 8);
ok($disabled_package && !$disabled_package->{allowed}
    && $disabled_package->{violations}->[0] eq 'package_disabled', 'deny new provisioning for a disabled package');
my $config_limit = $provider_policy->memory_decision($policy_account, 32);
ok($config_limit && !$config_limit->{allowed}, 'enforce the package memory ceiling on later configuration requests');
$enforced_package_policy->{mode} = 'report-only';
open($provider_policy_file, '>', $provider_policy_path) or die "rewrite provider policy: $!";
print {$provider_policy_file} JSON::PP->new->canonical(1)->encode($enforced_package_policy) . "\n";
close($provider_policy_file) or die "close report-only provider policy: $!";
chmod(0600, $provider_policy_path) or die "chmod report-only provider policy: $!";
my $reported_only = $provider_policy->provision_decision({%{$policy_account}, plan => 'blocked'}, 32);
ok($reported_only && $reported_only->{allowed} && @{$reported_only->{violations}} == 2
    && $reported_only->{mode} eq 'warn' && @policy_audit == 4,
    'migrate version-one report-only policy to compatible warnings without blocking package provisioning');
like($policy_audit[-1], qr/\Aprovider_policy actor_uid=43210 account=policyacct action=policy\.violation result=warn state=/,
    'emit provider policy violations with the trusted account actor and a fixed structured audit schema');
$enforced_package_policy->{version} = 3;
$enforced_package_policy->{mode} = 'enforce';
$enforced_package_policy->{exposure} = 'developer';
$enforced_package_policy->{resellers} = {
    reseller1 => { max_instances => 2, max_memory_mib => 64 },
};
$enforced_package_policy->{branding} = {
    product_name => 'Northstar Cache',
    logo_png_base64 => '',
    support_url => 'https://support.example.com/redis',
    preset => 'orm',
    primary_color => '#C92319',
    secondary_color => '#A91F18',
    surface_color => '#FFFFFF',
    text_color => '#172536',
    footer_visible => JSON::PP::true,
};
open(my $logo_file, '<', 'packaging/whm/icons/orm-whm.png') or die "read branded PNG fixture: $!";
binmode($logo_file);
my $logo_bytes = do { local $/; <$logo_file> };
close($logo_file) or die "close branded PNG fixture: $!";
$enforced_package_policy->{branding}->{logo_png_base64} = encode_base64($logo_bytes, '');
$enforced_package_policy->{packages}->{starter}->{max_memory_mib} = 64;
open($provider_policy_file, '>', $provider_policy_path) or die "write reseller provider policy: $!";
print {$provider_policy_file} JSON::PP->new->canonical(1)->encode($enforced_package_policy) . "\n";
close($provider_policy_file) or die "close reseller provider policy: $!";
chmod(0600, $provider_policy_path) or die "chmod reseller provider policy: $!";
is($provider_policy->exposure_mode(), 'developer', 'read the validated provider exposure tier');
is_deeply($provider_policy->branding_settings(), $enforced_package_policy->{branding},
    'read the validated product branding including a bounded PNG logo');
ok(Orm::Broker::ProviderPolicy::_valid_branding($enforced_package_policy->{branding}),
    'validate product branding at the broker policy boundary');
my $invalid_branding = { %{$enforced_package_policy->{branding}}, primary_color => '#FFFFFF' };
ok(!Orm::Broker::ProviderPolicy::_valid_branding($invalid_branding),
    'reject provider colors that do not meet the contrast minimum');
$invalid_branding = { %{$enforced_package_policy->{branding}}, surface_color => '#111111' };
ok(!Orm::Broker::ProviderPolicy::_valid_branding($invalid_branding),
    'reject a surface theme that makes its text unreadable');
$invalid_branding = { %{$enforced_package_policy->{branding}}, preset => 'unlisted' };
ok(!Orm::Broker::ProviderPolicy::_valid_branding($invalid_branding),
    'reject an unknown branding preset identifier');
$invalid_branding = { %{$enforced_package_policy->{branding}}, logo_png_base64 => encode_base64("\x89PNG\r\n\x1a\n" . pack('N', 13) . 'IHDR' . pack('N2', 16, 16), '') };
ok(!Orm::Broker::ProviderPolicy::_valid_branding($invalid_branding),
    'reject a truncated PNG at the broker policy boundary');
$invalid_branding = { %{$enforced_package_policy->{branding}}, support_url => 'https://bad..example.com/' };
ok(!Orm::Broker::ProviderPolicy::_valid_branding($invalid_branding),
    'reject malformed support hosts in the broker policy');
is_deeply($provider_policy->reseller_rules(), { reseller1 => { max_instances => 2, max_memory_mib => 64 } },
    'read exact reseller limits for the root WHM summary');
my $quota_at_boundary = $provider_policy->provision_decision($policy_account, 16,
    sub { return { instances => 1, memory_mib => 48 }; });
ok($quota_at_boundary && $quota_at_boundary->{allowed},
    'allow a new instance at the exact aggregate memory boundary and below the instance cap');
my $quota_memory_exceeded = $provider_policy->provision_decision($policy_account, 17,
    sub { return { instances => 1, memory_mib => 48 }; });
ok($quota_memory_exceeded && !$quota_memory_exceeded->{allowed}
    && $quota_memory_exceeded->{violations}->[0] eq 'reseller_memory_quota_exceeded',
    'enforce the aggregate reseller memory ceiling for new provisioning');
my $quota_instances_exceeded = $provider_policy->provision_decision($policy_account, 8,
    sub { return { instances => 2, memory_mib => 48 }; });
ok($quota_instances_exceeded && !$quota_instances_exceeded->{allowed}
    && $quota_instances_exceeded->{violations}->[0] eq 'reseller_instance_quota_exceeded',
    'enforce the reseller instance ceiling at its exact boundary');
my $quota_usage_unavailable = $provider_policy->provision_decision($policy_account, 8, sub { return undef; });
ok($quota_usage_unavailable && !$quota_usage_unavailable->{allowed}
    && $quota_usage_unavailable->{violations}->[0] eq 'reseller_usage_unavailable',
    'fail closed when enforced reseller usage cannot be established');
my $existing_memory_change = $provider_policy->memory_decision($policy_account, 64);
ok($existing_memory_change && $existing_memory_change->{allowed},
    'do not apply new-instance reseller quotas to existing instance configuration changes');
$enforced_package_policy->{mode} = 'warn';
open($provider_policy_file, '>', $provider_policy_path) or die "write warning-mode policy: $!";
print {$provider_policy_file} JSON::PP->new->canonical(1)->encode($enforced_package_policy) . "\n";
close($provider_policy_file) or die "close warning-mode policy: $!";
chmod(0600, $provider_policy_path) or die "chmod warning-mode policy: $!";
my $warn_quota = $provider_policy->provision_decision($policy_account, 8,
    sub { return { instances => 2, memory_mib => 48 }; });
ok($warn_quota && $warn_quota->{allowed}
    && $warn_quota->{violations}->[0] eq 'reseller_instance_quota_exceeded',
    'allow a reseller quota violation with a fixed warning in warn mode');
$enforced_package_policy->{packages}->{starter}->{max_memory_mib} = 65;
open($provider_policy_file, '>', $provider_policy_path) or die "rewrite invalid provider policy: $!";
print {$provider_policy_file} JSON::PP->new->canonical(1)->encode($enforced_package_policy) . "\n";
close($provider_policy_file) or die "close invalid provider policy: $!";
chmod(0600, $provider_policy_path) or die "chmod invalid provider policy: $!";
ok(!defined($provider_policy->effective_for($policy_account)), 'reject malformed provider policy instead of falling back to unlimited defaults');
unlink($provider_policy_path) or die "remove provider policy fixture: $!";

my $unit_state = 'inactive';
my $timer_state = 'inactive';
my $metrics_info = join("\r\n",
    'used_memory:1048576', 'used_memory_peak:2097152', 'connected_clients:3',
    'uptime_in_seconds:3600', 'instantaneous_ops_per_sec:12', 'keyspace_hits:90', 'keyspace_misses:10',
    'evicted_keys:4', 'total_commands_processed:50000', 'acl_access_denied_auth:100', '');
my @metrics_calls;
my @systemctl_calls;
my @config_calls;
my $fail_config_once;
my $fail_config_always;
my $fail_config_commit_once;
my $fail_metrics_commit_once;
my $fail_backup_once;
my $fail_rdb_check;
my $fail_restore_start_once;
my $fail_auth_probe_once = 0;
my @auth_probe_calls;
my $current_snapshot = 'synthetic RDB snapshot';
my @restore_audit;
my @auth_audit;
my @rdb_check_calls;
my $fail_config_get;
my %runtime_settings = (memory_mib => 64, maxmemory_policy => 'allkeys-lru', maxclients => 100, timeout => 0);
my $manager = Orm::Broker::InstanceManager->new(
    etc_root => $etc_instances,
    data_root => $data_instances,
    policy => $policy,
    provider_policy => Orm::Broker::ProviderPolicy->new(
        path => "$tmp/etc/missing-instance-policy.json", expected_owner_uid => $<,
    ),
    expected_owner_uid => $<,
    binary_paths => { redis => ['/usr/bin/redis-server'], valkey => ['/usr/bin/valkey-server'] },
    binary_probe => sub { return $_[0] eq 'redis' && $_[1] eq '/usr/bin/redis-server'; },
    metrics_probe => sub {
        push @metrics_calls, [@_];
        return $metrics_info;
    },
    backup_create => sub {
        my ($backend, $socket, $path) = @_;
        if ($fail_backup_once) {
            $fail_backup_once = 0;
            open(my $partial, '>', $path) or return 0;
            print {$partial} 'partial RDB fixture';
            close($partial);
            return 0;
        }
        open(my $snapshot, '>', $path) or return 0;
        binmode($snapshot);
        print {$snapshot} $current_snapshot;
        return close($snapshot) ? 1 : 0;
    },
    rdb_check => sub {
        my ($backend, $path, $checked_account) = @_;
        push @rdb_check_calls, [$backend, $path, $checked_account->{name}];
        return 0 if $fail_rdb_check;
        open(my $checked, '<', $path) or return 0;
        local $/;
        my $content = <$checked>;
        close($checked);
        return defined($content) && $content =~ /\A(?:synthetic RDB snapshot|live pre-restore state|live before rollback)\z/;
    },
    restore_audit => sub { push @restore_audit, [@_]; return 1; },
    auth_audit => sub { push @auth_audit, [@_]; return 1; },
    config_set => sub {
        my ($backend, $socket, $parameter, $value) = @_;
        push @config_calls, [$backend, $socket, $parameter, $value];
        if (defined($fail_config_once) && $parameter eq $fail_config_once) {
            undef $fail_config_once;
            return 0;
        }
        return 0 if defined($fail_config_always) && $parameter eq $fail_config_always;
        if ($parameter eq 'maxmemory') { $runtime_settings{memory_mib} = $value / (1024 * 1024); }
        elsif ($parameter eq 'maxmemory-policy') { $runtime_settings{maxmemory_policy} = $value; }
        elsif ($parameter eq 'maxclients') { $runtime_settings{maxclients} = 0 + $value; }
        elsif ($parameter eq 'timeout') { $runtime_settings{timeout} = 0 + $value; }
        return 1;
    },
    config_get => sub { return undef if $fail_config_get; return { %runtime_settings }; },
    auth_probe => sub {
        my ($backend, $socket) = @_;
        push @auth_probe_calls, [$backend, $socket];
        if ($fail_auth_probe_once) {
            --$fail_auth_probe_once;
            return 0;
        }
        return 1;
    },
    atomic_commit => sub {
        my ($temporary, $path) = @_;
        if ($fail_metrics_commit_once && $path =~ /metrics[.]json\z/) {
            $fail_metrics_commit_once = 0;
            return 0;
        }
        if ($fail_config_commit_once && index($path, 'ormtest') >= 0 && $path =~ /redis[.]conf\z/) {
            $fail_config_commit_once = 0;
            return 0;
        }
        return rename($temporary, $path);
    },
    systemctl_call => sub {
        my (@args) = @_;
        push @systemctl_calls, [@args];
        if ($args[0] eq 'is-active') {
            return ($timer_state eq 'active', $timer_state) if ($args[1] // '') =~ /\.timer\z/;
            return ($unit_state eq 'active' || $unit_state eq 'activating' || $unit_state eq 'deactivating', $unit_state);
        }
        if ($args[0] eq 'start') {
            if (($args[1] // '') =~ /\.timer\z/) { $timer_state = 'active'; return (1, ''); }
            if ($fail_restore_start_once) { $fail_restore_start_once = 0; $unit_state = 'failed'; return (1, ''); }
            $unit_state = 'active'; return (1, '');
        }
        if ($args[0] eq 'stop') { $unit_state = 'inactive'; return (1, ''); }
        return (1, '');
    },
);
my @config_get_cli_calls;
my %config_get_cli_values = (
    maxmemory => '50331648',
    'maxmemory-policy' => 'allkeys-lfu',
    maxclients => '50',
    timeout => '60',
);
my $config_get_cli_manager = Orm::Broker::InstanceManager->new(
    redis_cli_call => sub {
        my ($backend, $socket, @arguments) = @_;
        push @config_get_cli_calls, [$backend, $socket, @arguments];
        return undef if @arguments != 3 || $arguments[0] ne 'CONFIG'
            || $arguments[1] ne 'GET' || !exists($config_get_cli_values{$arguments[2]});
        return "$arguments[2]\n$config_get_cli_values{$arguments[2]}\n";
    },
);
is_deeply($config_get_cli_manager->_redis_config_get('redis', '/var/lib/orm-instances/ormtest/redis.sock'),
    { memory_mib => 48, maxmemory_policy => 'allkeys-lfu', maxclients => 50, timeout => 60 },
    'read bounded runtime settings with individual CONFIG GET patterns');
is_deeply([map { [@{$_}[2 .. $#$_]] } @config_get_cli_calls], [
    ['CONFIG', 'GET', 'maxmemory'], ['CONFIG', 'GET', 'maxmemory-policy'],
    ['CONFIG', 'GET', 'maxclients'], ['CONFIG', 'GET', 'timeout'],
], 'use one CONFIG GET pattern per command for pre-7.0 compatibility');
my $account = { name => 'ormtest', uid => $<, gid => $test_gid };
is($manager->dispatch('instance.status', $account)->{state}, 'not_configured', 'status is scoped to an unconfigured account');
my $diskfull_account = { name => 'ormdiskfull', uid => $<, gid => $test_gid };
my $write_calls_before_diskfull = scalar @systemctl_calls;
$manager->{atomic_write_call} = sub {
    my ($handle, $content, $path) = @_;
    if ($path =~ m!ormdiskfull[/\\]redis[.]conf\z!) {
        my $partial = substr($content, 0, 32);
        my $written = syswrite($handle, $partial);
        die "write ENOSPC fixture prefix: $!" if !defined($written) || $written != length($partial);
        $! = ENOSPC;
        return 0;
    }
    return print {$handle} $content;
};
my $diskfull_result = $manager->provision($diskfull_account, 'generic');
is($diskfull_result->{error}, 'storage_unavailable', 'report storage failure when an atomic config write hits ENOSPC');
ok(!-e "$etc_instances/ormdiskfull" && !-l "$etc_instances/ormdiskfull"
    && !-e "$data_instances/ormdiskfull" && !-l "$data_instances/ormdiskfull",
    'remove the partial configuration, manifest, and instance data after ENOSPC');
is(scalar(@systemctl_calls), $write_calls_before_diskfull,
    'do not start or enable a service after an ENOSPC provisioning failure');
is_deeply($manager->dispatch('instance.status', $diskfull_account),
    { state => 'not_configured', success => JSON::PP::true, version => 1 },
    'leave the account unconfigured after partial state is rolled back');
delete $manager->{atomic_write_call};
my $provisioned = $manager->dispatch('instance.provision', $account);
ok($provisioned->{success} && $provisioned->{state} eq 'running', 'provision and start a private account instance');
is($provisioned->{preset}, 'generic', 'default new instances to the generic preset');
my $start_calls_before_healthy_recovery = scalar grep { $_->[0] eq 'start' && $_->[1] eq '--no-block' } @systemctl_calls;
is($manager->recovery_start_if_stopped($account)->{error}, 'repair_not_applicable',
    'do not offer a start repair when the manifest is verified and service is already running');
is(scalar(grep { $_->[0] eq 'start' && $_->[1] eq '--no-block' } @systemctl_calls), $start_calls_before_healthy_recovery,
    'avoid a systemd start call for a healthy running instance');
my $held_instance_lock = $manager->_acquire_instance_lock($account);
ok(defined($held_instance_lock), 'acquire the root-owned per-account operation lock');
is($manager->start($account)->{error}, 'operation_in_progress',
    'serialize service lifecycle requests against migrations and restore operations');
is($manager->recovery_start_if_stopped($account)->{error}, 'operation_in_progress',
    'serialize fixed recovery repairs against concurrent per-instance operations');
close($held_instance_lock) or die "close held instance lock: $!";
my $restarted = $manager->restart($account);
ok($restarted->{success} && $restarted->{state} eq 'running', 'restart a validated instance through its fixed systemd unit');
ok((grep { $_->[0] eq 'restart' && $_->[1] eq '--no-block' && $_->[2] eq 'orm-instance@ormtest.service' } @systemctl_calls),
    'restart uses a server-generated unit and fixed no-block invocation');
my $stopped_for_restart_test = $manager->stop($account);
ok($stopped_for_restart_test->{success}, 'stop the test instance before checking restart guards');
my $restart_calls_before_stopped = scalar grep { $_->[0] eq 'restart' } @systemctl_calls;
is($manager->restart($account)->{error}, 'instance_unavailable', 'refuse restart when the instance is not running');
is(scalar(grep { $_->[0] eq 'restart' } @systemctl_calls), $restart_calls_before_stopped,
    'do not invoke systemd restart for a stopped instance');
my $recovered_start = $manager->recovery_start_if_stopped($account);
ok($recovered_start->{success} && $recovered_start->{state} eq 'running',
    'start a verified stopped instance through the fixed recovery repair');
ok((grep { $_->[0] eq 'start' && $_->[1] eq '--no-block' && $_->[2] eq 'orm-instance@ormtest.service' } @systemctl_calls),
    'recovery repair uses only the server-generated unit and fixed start invocation');
{
    my @diagnostics_commands;
    local $manager->{redis_cli_call} = sub {
        my ($backend, $socket, @arguments) = @_;
        push @diagnostics_commands, [$backend, $socket, @arguments];
        return "PONG\n" if @arguments == 1 && $arguments[0] eq 'PING';
        if (@arguments == 2 && $arguments[0] eq 'INFO' && $arguments[1] eq 'server') {
            my $version_fields = $backend eq 'valkey'
                ? "redis_version:7.2.4\r\nvalkey_version:8.1.3\r\n"
                : "redis_version:7.2.4\r\n";
            return "# Server\r\n${version_fields}uptime_in_seconds:3600\r\n";
        }
        return "# Memory\r\nused_memory:1048576\r\nused_memory_peak:2097152\r\nmaxmemory:67108864\r\n" if @arguments == 2 && $arguments[0] eq 'INFO' && $arguments[1] eq 'memory';
        return "# Clients\r\nconnected_clients:3\r\nblocked_clients:0\r\nmaxclients:100\r\n" if @arguments == 2 && $arguments[0] eq 'INFO' && $arguments[1] eq 'clients';
        return "# Stats\r\ninstantaneous_ops_per_sec:12\r\nkeyspace_hits:90\r\nkeyspace_misses:10\r\nexpired_keys:4\r\nevicted_keys:2\r\n" if @arguments == 2 && $arguments[0] eq 'INFO' && $arguments[1] eq 'stats';
        return "42\n" if @arguments == 1 && $arguments[0] eq 'DBSIZE';
        return undef;
    };
    my $recovery_health = $manager->recovery_health_check($account);
    ok($recovery_health->{success}, 'run one bounded fixed PING in the read-only recovery health check');
    is_deeply([map { [@{$_}[2 .. $#{$_}]] } @diagnostics_commands], [['PING']],
        'recovery health checks never issue commands beyond PING');
    @diagnostics_commands = ();
    {
        local $manager->{redis_cli_call} = sub { return "raw private error\n"; };
        my $failed_health = $manager->recovery_health_check($account);
        is($failed_health->{error}, 'health_probe_failed', 'map probe failures to a fixed safe result');
        is_deeply([sort keys %{$failed_health}], [qw(error success version)],
            'never return raw command output from recovery health checks');
    }
    my $diagnostics = $manager->read_diagnostics($account);
    ok($diagnostics->{success} && $diagnostics->{state} eq 'running',
        'collect safe read-only diagnostics only for a running instance');
    is_deeply([sort keys %{$diagnostics->{diagnostics}}], [sort qw(
        backend blocked_clients commands_per_second connected_clients database_keys evicted_keys expired_keys
        keyspace_hits keyspace_misses maxclients maxmemory_bytes memory_peak_bytes memory_used_bytes server_version uptime_seconds
    )], 'return only the fixed diagnostics field allowlist');
    is_deeply([@{$diagnostics->{diagnostics}}{qw(backend server_version memory_used_bytes database_keys)}],
        ['redis', '7.2.4', 1048576, 42], 'parse bounded values without returning raw INFO output');
    is_deeply([map { [@{$_}[2 .. $#{$_}]] } @diagnostics_commands], [
        ['PING'], ['INFO', 'server'], ['INFO', 'memory'], ['INFO', 'clients'], ['INFO', 'stats'], ['DBSIZE'],
    ], 'run only the fixed read-only Redis command and INFO section allowlist');
    is(Orm::Broker::InstanceManager::_parse_info_fields("counter:9000000000000001\n", { counter => 'integer' }), undef,
        'reject counters above the numeric response boundary shared with PHP');
    my $valkey_info = Orm::Broker::InstanceManager::_parse_info_fields(
        "valkey_version:8.1.3\nuptime_in_seconds:3600\n",
        { valkey_version => 'version', uptime_in_seconds => 'integer' },
    );
    is($valkey_info->{valkey_version}, '8.1.3', 'parse Valkey version independently from Redis compatibility version');
    my $manifest_path = $manager->_manifest_path($account->{name});
    my $manifest;
    {
        local $/;
        open(my $manifest_handle, '<', $manifest_path) or die "read diagnostics manifest fixture: $!";
        $manifest = JSON::PP->new->decode(<$manifest_handle>);
        close($manifest_handle) or die "close diagnostics manifest fixture: $!";
    }
    my $redis_manifest_json = JSON::PP->new->canonical(1)->encode($manifest) . "\n";
    $manifest->{backend} = 'valkey';
    local $manager->{binary_probe} = sub { return 1; };
    open(my $valkey_manifest_handle, '>', $manifest_path) or die "write Valkey diagnostics manifest fixture: $!";
    print {$valkey_manifest_handle} JSON::PP->new->canonical(1)->encode($manifest) . "\n";
    close($valkey_manifest_handle) or die "close Valkey diagnostics manifest fixture: $!";
    my $valkey_diagnostics = $manager->read_diagnostics($account);
    my $valkey_version = ref($valkey_diagnostics->{diagnostics}) eq 'HASH'
        ? [@{$valkey_diagnostics->{diagnostics}}{qw(backend server_version)}]
        : undef;
    is_deeply($valkey_version, ['valkey', '8.1.3'],
        'report the actual Valkey version while keeping its Redis compatibility version private');
    open(my $redis_manifest_handle, '>', $manifest_path) or die "restore Redis diagnostics manifest fixture: $!";
    print {$redis_manifest_handle} $redis_manifest_json;
    close($redis_manifest_handle) or die "close restored diagnostics manifest fixture: $!";
    {
        local $manager->{redis_cli_call} = sub { return 'x' x 2048; };
        is(length(Orm::Broker::InstanceManager::_run_redis_cli(
            $manager, 'redis', '/var/lib/orm-instances/acct01/redis.sock', 'INFO', 'stats',
        )), 2048, 'accept INFO sections above 1 KiB within the fixed 32 KiB cap');
        local $manager->{redis_cli_call} = sub { return 'x' x 32769; };
        ok(!defined(Orm::Broker::InstanceManager::_run_redis_cli(
            $manager, 'redis', '/var/lib/orm-instances/acct01/redis.sock', 'INFO', 'stats',
        )), 'reject INFO output above its fixed 32 KiB cap');
    }
    my $bad_diagnostics = Orm::Broker::InstanceManager->new(
        etc_root => $etc_instances,
        data_root => $data_instances,
        policy => $policy,
        expected_owner_uid => $<,
        binary_paths => { redis => ['/usr/bin/redis-server'], valkey => ['/usr/bin/valkey-server'] },
        binary_probe => sub { return $_[0] eq 'redis'; },
        systemctl_call => sub { return (1, 'active'); },
        redis_cli_call => sub {
            my ($backend, $socket, @arguments) = @_;
            return "PONG\n" if $arguments[0] eq 'PING';
            return "redis_version:7.2.4\nuptime_in_seconds:1\n" if $arguments[0] eq 'INFO' && $arguments[1] eq 'server';
            return "used_memory:2097152\nused_memory_peak:1048576\nmaxmemory:67108864\n" if $arguments[0] eq 'INFO' && $arguments[1] eq 'memory';
            return "connected_clients:3\nblocked_clients:0\nmaxclients:100\n" if $arguments[0] eq 'INFO' && $arguments[1] eq 'clients';
            return "instantaneous_ops_per_sec:1\nkeyspace_hits:1\nkeyspace_misses:0\nexpired_keys:0\nevicted_keys:0\n" if $arguments[0] eq 'INFO' && $arguments[1] eq 'stats';
            return "42\n" if $arguments[0] eq 'DBSIZE';
            return undef;
        },
    );
    is($bad_diagnostics->read_diagnostics($account)->{error}, 'diagnostics_unavailable',
        'reject contradictory or incomplete Redis diagnostics');
}
is_deeply($provisioned->{config}, { memory_mib => 64, maxmemory_policy => 'allkeys-lru', maxclients => 100, timeout => 0 },
    'return validated saved settings in the instance status');
my $existing_config_path = "$etc_instances/ormtest/redis.conf";
open(my $existing_config_handle, '<', $existing_config_path) or die "read existing instance config: $!";
my $existing_config_before_defaults = do { local $/; <$existing_config_handle> };
close($existing_config_handle) or die "close existing instance config: $!";
my $custom_defaults_path = "$tmp/etc/missing-instance-policy.json";
my $custom_defaults_policy = {
    version => 4,
    mode => 'enforce',
    exposure => 'advanced',
    default => { enabled => JSON::PP::true, max_memory_mib => 64, backup_retention => 2 },
    instance_defaults => {
        memory_mib => 24,
        maxmemory_policy => 'allkeys-lfu',
        databases => 5,
        metrics_history_retention_days => 7,
    },
    packages => { starter => { enabled => JSON::PP::true, max_memory_mib => 16, backup_retention => 2 } },
    resellers => {},
    branding => {
        product_name => 'Open Redis Manager', logo_png_base64 => '', support_url => '', preset => 'orm',
        primary_color => '#C92319', secondary_color => '#A91F18', surface_color => '#FFFFFF',
        text_color => '#172536', footer_visible => JSON::PP::true,
    },
};
open(my $custom_defaults_file, '>', $custom_defaults_path) or die "write custom defaults policy: $!";
print {$custom_defaults_file} JSON::PP->new->canonical(1)->encode($custom_defaults_policy) . "\n";
close($custom_defaults_file) or die "close custom defaults policy: $!";
chmod(0600, $custom_defaults_path) or die "chmod custom defaults policy: $!";
my $defaults_account = { name => 'ormdefaults', uid => $<, gid => $test_gid };
my $defaults_provisioned = $manager->provision($defaults_account, 'generic');
ok($defaults_provisioned->{success} && $defaults_provisioned->{config}->{memory_mib} == 24
    && $defaults_provisioned->{config}->{maxmemory_policy} eq 'allkeys-lfu',
    'apply configured global memory and eviction defaults to a new ORM instance');
my $defaults_config_path = "$etc_instances/ormdefaults/redis.conf";
open(my $defaults_config_handle, '<', $defaults_config_path) or die "read new defaults config: $!";
my $defaults_config_text = do { local $/; <$defaults_config_handle> };
close($defaults_config_handle) or die "close new defaults config: $!";
like($defaults_config_text, qr/^databases 5$/m, 'apply the bounded database count only to the newly provisioned instance');
my $defaults_manifest = $manager->_read_manifest($defaults_account);
is_deeply($defaults_manifest->{provisioned_defaults}, {
    backup_retention => 2, databases => 5, metrics_history_retention_days => 7,
}, 'record snapshot, database, and history defaults in the new root-owned manifest');
my $old_history_sample = {
    commands_per_second => 1, connected_clients => 1, keyspace_hits => 1, keyspace_misses => 0,
    memory_peak_bytes => 1024, memory_used_bytes => 512, uptime_seconds => 100,
    sampled_at => int(time - 8 * 24 * 60 * 60),
};
my $old_history_path = "$etc_instances/ormdefaults/metrics-history.json";
open(my $old_history_handle, '>', $old_history_path) or die "write expired history fixture: $!";
print {$old_history_handle} JSON::PP->new->canonical(1)->encode([$old_history_sample]) . "\n";
close($old_history_handle) or die "close expired history fixture: $!";
chmod(0600, $old_history_path) or die "chmod expired history fixture: $!";
chown($<, $<, $old_history_path) or die "chown expired history fixture: $!";
my $new_history_sample = { %{$old_history_sample}, sampled_at => int(time) };
ok($manager->_write_metrics_history($defaults_account, $new_history_sample),
    'prune history using the instance-specific retention while preserving bounded root-owned storage');
my $retained_defaults_history = $manager->dispatch('metrics.history', $defaults_account, undef, undef, undef, '7d');
ok($retained_defaults_history->{success} && @{$retained_defaults_history->{history}} == 1,
    'keep only samples inside the configured seven-day retention window');
open($existing_config_handle, '<', $existing_config_path) or die "recheck existing instance config: $!";
my $existing_config_after_defaults = do { local $/; <$existing_config_handle> };
close($existing_config_handle) or die "close existing instance config: $!";
is($existing_config_after_defaults, $existing_config_before_defaults,
    'leave an existing instance configuration unchanged after global defaults change');
is_deeply($manager->_read_manifest($account)->{provisioned_defaults}, {
    backup_retention => 3, databases => 16, metrics_history_retention_days => 30,
}, 'leave an existing instance snapshot, database, and history defaults unchanged after a global default change');
my $capped_account = { name => 'ormcapped', uid => $<, gid => $test_gid, plan => 'starter' };
is($manager->provision($capped_account, 'generic')->{error}, 'provider_policy_denied',
    'continue enforcing the package memory ceiling against global defaults');
ok(!-e "$etc_instances/ormcapped" && !-e "$data_instances/ormcapped",
    'do not create instance files when a package ceiling rejects the configured default');
unlink($custom_defaults_path) or die "remove custom defaults policy: $!";

my $migration_etc = "$tmp/migration-etc";
my $migration_data = "$tmp/migration-data";
make_path($migration_etc, $migration_data);
chmod(0755, $migration_etc, $migration_data) or die "chmod migration roots: $!";
my $migration_unit_state = 'inactive';
my $migration_source_version = '7.4.0';
my $fail_target_rdb_check = 0;
my $fail_valkey_ping_once = 0;
my $migration_manager = Orm::Broker::InstanceManager->new(
    etc_root => $migration_etc,
    data_root => $migration_data,
    policy => $policy,
    provider_policy => Orm::Broker::ProviderPolicy->new(
        path => "$tmp/etc/missing-migration-policy.json", expected_owner_uid => $<,
    ),
    expected_owner_uid => $<,
    restore_state_timeout => 1,
    binary_paths => { redis => ['/usr/bin/redis-server'], valkey => ['/usr/bin/valkey-server'] },
    binary_probe => sub { return 1; },
    backend_version_probe => sub { return 'Valkey server v=7.2.5'; },
    redis_cli_call => sub {
        my ($backend, $socket, @arguments) = @_;
        return "redis_version:$migration_source_version\r\n" if $backend eq 'redis' && $arguments[0] eq 'INFO' && $arguments[1] eq 'server';
        return "# Keyspace\r\ndb0:keys=2,expires=1,avg_ttl=10\r\n" if $arguments[0] eq 'INFO' && $arguments[1] eq 'keyspace';
        return "PONG\n" if $arguments[0] eq 'PING' && $backend eq 'redis';
        if ($arguments[0] eq 'PING' && $backend eq 'valkey' && $fail_valkey_ping_once) {
            $fail_valkey_ping_once = 0;
            return "NOAUTH\n";
        }
        return "PONG\n" if $arguments[0] eq 'PING';
        return "OK\n" if $arguments[0] eq 'CLIENT';
        return undef;
    },
    backup_create => sub {
        my ($backend, $socket, $path) = @_;
        open(my $snapshot, '>', $path) or return 0;
        binmode($snapshot);
        print {$snapshot} 'synthetic RDB snapshot';
        return close($snapshot) ? 1 : 0;
    },
    rdb_check => sub {
        my ($backend, $path) = @_;
        return 0 if $backend eq 'valkey' && $fail_target_rdb_check;
        open(my $snapshot, '<', $path) or return 0;
        local $/;
        my $content = <$snapshot>;
        close($snapshot);
        return defined($content) && $content eq 'synthetic RDB snapshot';
    },
    systemctl_call => sub {
        my (@args) = @_;
        return ($migration_unit_state eq 'active', $migration_unit_state) if $args[0] eq 'is-active';
        if ($args[0] eq 'start') { $migration_unit_state = 'active'; return (1, ''); }
        if ($args[0] eq 'stop') { $migration_unit_state = 'inactive'; return (1, ''); }
        return (1, '');
    },
);
my $migration_account = { name => 'ormmig', uid => $<, gid => $test_gid };
my $migration_provisioned = $migration_manager->provision($migration_account, 'generic');
ok($migration_provisioned->{success}, 'provision an isolated Redis fixture for migration tests');
my $run_migration = sub {
    return $migration_manager->migrate_to_valkey($migration_account);
};
my $migration_manifest_path = "$migration_etc/ormmig/manifest.json";
my $legacy_manifest;
{
    local $/;
    open(my $legacy_manifest_handle, '<', $migration_manifest_path) or die "read migration manifest fixture: $!";
    $legacy_manifest = JSON::PP->new->decode(<$legacy_manifest_handle>);
    close($legacy_manifest_handle) or die "close migration manifest fixture: $!";
}
delete $legacy_manifest->{preset};
delete $legacy_manifest->{provisioned_defaults};
$legacy_manifest->{version} = 1;
open(my $legacy_manifest_write, '>', $migration_manifest_path) or die "write legacy migration manifest fixture: $!";
print {$legacy_manifest_write} JSON::PP->new->canonical(1)->encode($legacy_manifest) . "\n";
close($legacy_manifest_write) or die "close legacy migration manifest fixture: $!";
chmod(0640, $migration_manifest_path) or die "chmod legacy migration manifest fixture: $!";
chown($<, $migration_account->{gid}, $migration_manifest_path) or die "chown legacy migration manifest fixture: $!";
is($run_migration->()->{error}, 'migration_unsupported',
    'reject Redis 7.4 before pausing or modifying the instance');
is($migration_unit_state, 'active', 'keep Redis running when the source version is unsupported');
$migration_source_version = '7.2.5';
$fail_target_rdb_check = 1;
is($run_migration->()->{error}, 'migration_validation_failed',
    'refuse to stop Redis when the Valkey checker rejects the snapshot');
is($migration_unit_state, 'active', 'leave the Redis service active after target snapshot validation fails');
$fail_target_rdb_check = 0;
$fail_valkey_ping_once = 1;
my $rolled_back_migration = $run_migration->();
diag('migration rollback fixture response: ' . JSON::PP->new->canonical(1)->encode($rolled_back_migration))
    if !$rolled_back_migration->{success};
ok(!$rolled_back_migration->{success} && $rolled_back_migration->{error} eq 'migration_failed'
    && defined($rolled_back_migration->{safety_backup_id}), 'roll back a target health failure and return its retained snapshot');
is($migration_manager->backend($migration_account), 'redis', 'restore the Redis backend manifest after a failed Valkey start check');
is($migration_manager->_read_manifest($migration_account)->{version}, 1,
    'restore the original version-one manifest exactly after migration rollback');
is($migration_unit_state, 'active', 'restart the Redis service after a failed migration');
my $successful_migration = $run_migration->();
diag('migration success fixture response: ' . JSON::PP->new->canonical(1)->encode($successful_migration))
    if !$successful_migration->{success};
ok($successful_migration->{success} && $successful_migration->{source_backend} eq 'redis'
    && $successful_migration->{target_backend} eq 'valkey', 'switch a validated Redis instance to Valkey');
is($migration_manager->backend($migration_account), 'valkey', 'persist the Valkey backend only after verification');
is($migration_manager->_read_manifest($migration_account)->{version}, 2,
    'write a version-two manifest when the Valkey backend is committed');
is($migration_unit_state, 'active', 'leave the verified Valkey service running');

my $backup_root_path = "$data_instances/.orm-backups";
my $account_backup_path = "$backup_root_path/ormtest";
my $created_backup = $manager->dispatch('backup.create', $account);
ok($created_backup->{success} && $created_backup->{backup}->{size_bytes} > 0,
    'create an account-scoped RDB snapshot for a running instance');
like($created_backup->{backup}->{id}, qr/\Asnapshot-[0-9]{10}-[a-f0-9]{8}[.]rdb\z/, 'return only the generated snapshot identifier');
my @backup_root_stat = stat($backup_root_path);
is($backup_root_stat[4], $<, 'shared backup root is controlled by the privileged manager');
is($backup_root_stat[2] & 0777, 0711, 'shared backup root cannot be listed or modified by accounts');
my @account_backup_stat = stat($account_backup_path);
is($account_backup_stat[4], $<, 'per-account backup directory is root-owned');
is($account_backup_stat[5], $account->{gid}, 'per-account backup directory is group-readable only by its account');
is($account_backup_stat[2] & 0777, 0750, 'account can list backups but cannot replace them');
my $backup_file_path = "$account_backup_path/$created_backup->{backup}->{id}";
my @backup_file_stat = stat($backup_file_path);
is($backup_file_stat[4], $<, 'snapshot is owned by the privileged manager');
is($backup_file_stat[5], $account->{gid}, 'snapshot is readable by its cPanel account group');
is($backup_file_stat[2] & 0777, 0640, 'snapshot is not writable by the cPanel account');
my $listed_backups = $manager->dispatch('backup.list', $account);
ok($listed_backups->{success} && @{$listed_backups->{backups}} == 1
    && $listed_backups->{backups}->[0]->{id} eq $created_backup->{backup}->{id},
    'list only validated account snapshots with their metadata');
for (1 .. 3) {
    sleep 1;
    my $additional_backup = $manager->dispatch('backup.create', $account);
    ok($additional_backup->{success}, 'create a subsequent bounded retained backup');
}
$listed_backups = $manager->dispatch('backup.list', $account);
ok($listed_backups->{success} && @{$listed_backups->{backups}} == 3,
    'retain only the three most recent account snapshots');
ok(!(grep { $_->{id} eq $created_backup->{backup}->{id} } @{$listed_backups->{backups}}),
    'remove the oldest snapshot only after its replacements complete');
$fail_backup_once = 1;
is($manager->dispatch('backup.create', $account)->{error}, 'backup_failed',
    'reject a failed RDB transfer and remove its partial temporary file');
$listed_backups = $manager->dispatch('backup.list', $account);
ok($listed_backups->{success} && @{$listed_backups->{backups}} == 3,
    'preserve existing snapshots after a failed backup');
my $restore_id = $listed_backups->{backups}->[1]->{id};
my $dump_path = "$data_instances/ormtest/dump.rdb";
open(my $old_dump, '>', $dump_path) or die "create previous dump fixture: $!";
binmode($old_dump);
print {$old_dump} 'old on-disk cache state';
close($old_dump) or die "close previous dump fixture: $!";
chmod(0600, $dump_path) or die "chmod previous dump fixture: $!";
$current_snapshot = 'live pre-restore state';
my $restored = $manager->dispatch('backup.restore', $account, undef, undef, $restore_id);
ok($restored->{success} && $restored->{backup_id} eq $restore_id && $restored->{state} eq 'running',
    'restore only the selected validated account snapshot and verify the service is running');
like($restored->{safety_backup_id}, qr/\Asnapshot-[0-9]{10}-[a-f0-9]{8}[.]rdb\z/,
    'return the safety snapshot created before replacing cache data');
open(my $restored_dump, '<', $dump_path) or die "read restored dump fixture: $!";
binmode($restored_dump);
local $/;
is(<$restored_dump>, 'synthetic RDB snapshot', 'replace dump.rdb with the validated selected snapshot');
close($restored_dump) or die "close restored dump fixture: $!";
$listed_backups = $manager->dispatch('backup.list', $account);
ok($listed_backups->{success} && @{$listed_backups->{backups}} == 3
    && (grep { $_->{id} eq $restore_id } @{$listed_backups->{backups}})
    && (grep { $_->{id} eq $restored->{safety_backup_id} } @{$listed_backups->{backups}}),
    'retain both the selected snapshot and safety snapshot within the three-backup limit');
is_deeply($restore_audit[-1], [$account->{uid}, 'ormtest', $restore_id, $restored->{safety_backup_id}, 'success', 'running'],
    'audit restore actor, account, snapshot IDs, result, and service state');
my $missing_restore = $manager->dispatch('backup.restore', $account, undef, undef, 'snapshot-0000000000-00000000.rdb');
is($missing_restore->{error}, 'backup_not_found', 'reject a validly-shaped snapshot ID absent from this account');
my $stop_calls_before_bad_rdb = scalar grep { $_->[0] eq 'stop' } @systemctl_calls;
$fail_rdb_check = 1;
is($manager->dispatch('backup.restore', $account, undef, undef, $restore_id)->{error}, 'backup_invalid',
    'reject a snapshot that fails backend RDB validation');
$fail_rdb_check = 0;
is(scalar(grep { $_->[0] eq 'stop' } @systemctl_calls), $stop_calls_before_bad_rdb,
    'do not stop or replace data when the selected RDB is invalid');
$current_snapshot = 'live before rollback';
$fail_restore_start_once = 1;
my $rolled_back_restore = $manager->dispatch('backup.restore', $account, undef, undef, $restore_id);
is($rolled_back_restore->{error}, 'restore_failed', 'report a rejected restored RDB after rollback succeeds');
like($rolled_back_restore->{safety_backup_id}, qr/\Asnapshot-[0-9]{10}-[a-f0-9]{8}[.]rdb\z/,
    'identify the fresh safety snapshot when the attempted restore fails');
$listed_backups = $manager->dispatch('backup.list', $account);
ok($listed_backups->{success} && (grep { $_->{id} eq $rolled_back_restore->{safety_backup_id} } @{$listed_backups->{backups}}),
    'retain the failed attempt safety snapshot for manual recovery');
open(my $rollback_dump, '<', $dump_path) or die "read rollback dump fixture: $!";
binmode($rollback_dump);
is(<$rollback_dump>, 'live before rollback', 'restore the safety snapshot after the selected backup fails to start');
close($rollback_dump) or die "close rollback dump fixture: $!";
is($unit_state, 'active', 'restart the service after automatic rollback');
my $retention_policy_path = "$tmp/etc/missing-instance-policy.json";
open($provider_policy_file, '>', $retention_policy_path) or die "create retention policy fixture: $!";
print {$provider_policy_file} JSON::PP->new->canonical(1)->encode({
    version => 1, mode => 'enforce',
    default => { enabled => JSON::PP::true, max_memory_mib => 64, backup_retention => 2 },
    packages => {},
}) . "\n";
close($provider_policy_file) or die "close retention policy fixture: $!";
chmod(0600, $retention_policy_path) or die "chmod retention policy fixture: $!";
sleep 1;
ok($manager->dispatch('backup.create', $account)->{success}, 'create a snapshot under an enforced two-snapshot retention policy');
sleep 1;
ok($manager->dispatch('backup.create', $account)->{success}, 'create the next snapshot under the enforced retention policy');
$listed_backups = $manager->dispatch('backup.list', $account);
ok($listed_backups->{success} && @{$listed_backups->{backups}} == 3,
    'retain the existing instance snapshot policy captured when it was provisioned');
unlink($retention_policy_path) or die "remove retention policy fixture: $!";
my $metrics = $manager->dispatch('instance.metrics', $account);
ok($metrics->{success}, 'collect current metrics for the running account instance');
is_deeply([@{$metrics}{qw(memory_used_bytes memory_peak_bytes connected_clients uptime_seconds commands_per_second keyspace_hits keyspace_misses)}],
    [1048576, 2097152, 3, 3600, 12, 90, 10], 'return only parsed numeric metrics');
ok(!$metrics->{stale} && $metrics->{retained} && $metrics->{sampled_at} =~ /\A[0-9]{10}\z/,
    'mark the live sample fresh, retained, and record its capture time');
is_deeply([sort keys %{$metrics}], [qw(commands_per_second connected_clients keyspace_hits keyspace_misses memory_peak_bytes memory_used_bytes retained sampled_at stale success uptime_seconds version)],
    'metrics response contains only the fixed numeric allowlist and envelope');
my $metrics_path = "$etc_instances/ormtest/metrics.json";
ok(-f $metrics_path, 'persist the latest metrics sample in the root-owned account metadata directory');
my @metrics_stat = stat($metrics_path);
is($metrics_stat[4], $<, 'metrics snapshot is owned by the privileged manager');
is($metrics_stat[5], $<, 'metrics snapshot is not readable through the cPanel account group');
is($metrics_stat[2] & 0777, 0600, 'metrics snapshot permissions are root-only');
my $security_metrics_path = "$etc_instances/ormtest/security-metrics.json";
unlink($security_metrics_path) if -e $security_metrics_path;
my $security_now = time - 3600;
ok($manager->_write_security_metrics_snapshot($account, {
    sampled_at => $security_now - 7200, uptime_seconds => 3600,
    evicted_keys => 4, total_commands_processed => 50000, acl_access_denied_auth => 100,
}), 'store the first bounded security counter sample as a baseline');
my $baseline_security_sample = $manager->_read_security_metrics_snapshot($account);
ok($baseline_security_sample && $baseline_security_sample->{available} == 1
    && !defined($baseline_security_sample->{window_seconds}),
    'keep rate evidence unknown until a second valid counter sample exists');
ok($manager->_write_security_metrics_snapshot($account, {
    sampled_at => $security_now - 3600, uptime_seconds => 7200,
    evicted_keys => 6, total_commands_processed => 68000, acl_access_denied_auth => 107,
}), 'store a later security counter sample');
my $measured_security_sample = $manager->_read_security_metrics_snapshot($account);
is_deeply([@{$measured_security_sample}{qw(evicted_keys_delta total_commands_processed_delta window_seconds window_start_at)}],
    [2, 18000, 3600, $security_now - 7200],
    'derive eviction and operation counter deltas over the actual one-hour sample interval');
is_deeply([@{$measured_security_sample}{qw(auth_failures_delta auth_window_seconds auth_window_start_at)}],
    [7, 3600, $security_now - 7200],
    'derive anonymous backend authentication-failure deltas over their own bounded sample window');
my $measured_fleet_summary = $manager->fleet_summary([$account]);
ok($measured_fleet_summary && $measured_fleet_summary->{metrics}->{rate_accounts} == 1
    && $measured_fleet_summary->{metrics}->{eviction_activity_accounts} == 1
    && $measured_fleet_summary->{metrics}->{max_evictions_per_window} == 2
    && $measured_fleet_summary->{metrics}->{max_operations_per_second} == 5
    && $measured_fleet_summary->{metrics}->{rate_window_min_seconds} == 3600
    && $measured_fleet_summary->{metrics}->{auth_rate_accounts} == 1
    && $measured_fleet_summary->{metrics}->{auth_rate_missing_accounts} == 0
    && $measured_fleet_summary->{metrics}->{auth_failure_accounts} == 1
    && $measured_fleet_summary->{metrics}->{max_auth_failures_per_window} == 7
    && $measured_fleet_summary->{metrics}->{auth_rate_window_min_seconds} == 3600,
    'aggregate only bounded per-account counter rates and their evidence window for root WHM');
my @security_metrics_stat = stat($security_metrics_path);
is($security_metrics_stat[4], $<, 'keep the security counter snapshot owned by the privileged manager');
is($security_metrics_stat[2] & 0777, 0600, 'keep the security counter snapshot private to root');
ok($manager->_write_security_metrics_snapshot($account, {
    sampled_at => $security_now - 1800, uptime_seconds => 10,
    evicted_keys => 1, total_commands_processed => 200, acl_access_denied_auth => 1,
}), 'record a lower counter sample as a new post-reset baseline');
my $reset_security_sample = $manager->_read_security_metrics_snapshot($account);
ok($reset_security_sample && !defined($reset_security_sample->{window_seconds})
    && $reset_security_sample->{evicted_keys} == 1,
    'treat counter decreases and uptime resets as unknown instead of negative rates');
ok($manager->_write_security_metrics_snapshot($account, {
    sampled_at => $security_now - 900, uptime_seconds => 910,
    evicted_keys => 3, total_commands_processed => 9200, acl_access_denied_auth => 3,
}), 'resume rate measurement from the post-reset baseline');
my $recovered_security_sample = $manager->_read_security_metrics_snapshot($account);
ok($recovered_security_sample && $recovered_security_sample->{window_seconds} == 900
    && $recovered_security_sample->{evicted_keys_delta} == 2
    && $recovered_security_sample->{auth_window_seconds} == 900
    && $recovered_security_sample->{auth_failures_delta} == 2,
    'recover with a valid rate window after a counter reset');
ok($manager->_write_security_metrics_snapshot($account, {
    sampled_at => $security_now - 600, uptime_seconds => 1210,
    evicted_keys => 4, total_commands_processed => 10000, acl_access_denied_auth => 0,
}), 'record an authentication counter reset without changing the process uptime');
my $auth_reset_sample = $manager->_read_security_metrics_snapshot($account);
ok($auth_reset_sample && $auth_reset_sample->{window_seconds} == 300
    && $auth_reset_sample->{evicted_keys_delta} == 1
    && !defined($auth_reset_sample->{auth_window_seconds})
    && !defined($auth_reset_sample->{auth_failures_delta}),
    'keep unrelated monotonic rates while treating an independently reset auth counter as unknown');
ok($manager->_write_security_metrics_snapshot($account, {
    sampled_at => $security_now - 300, uptime_seconds => 1510,
    evicted_keys => 5, total_commands_processed => 15000, acl_access_denied_auth => 2,
}), 'resume auth counter sampling after its reset baseline');
my $auth_recovered_sample = $manager->_read_security_metrics_snapshot($account);
ok($auth_recovered_sample && $auth_recovered_sample->{auth_window_seconds} == 300
    && $auth_recovered_sample->{auth_failures_delta} == 2,
    'recover anonymous authentication-failure deltas from the new monotonic baseline');
ok($manager->_write_security_metrics_snapshot($account, {
    sampled_at => $security_now - 150, uptime_seconds => 1660,
    evicted_keys => 6, total_commands_processed => 20000, acl_access_denied_auth => 2,
}), 'store a compatible authentication sample with no counter increase');
my $zero_auth_delta_sample = $manager->_read_security_metrics_snapshot($account);
ok($zero_auth_delta_sample && $zero_auth_delta_sample->{auth_window_seconds} == 150
    && $zero_auth_delta_sample->{auth_failures_delta} == 0,
    'distinguish a measured zero authentication-failure delta from unavailable evidence');
ok($manager->_write_security_metrics_snapshot($account, {
    sampled_at => $security_now, uptime_seconds => 1810,
    evicted_keys => 8, total_commands_processed => 50000, acl_access_denied_auth => 4,
}), 'record the next current security counter sample');
ok(defined($manager->_read_security_metrics_snapshot($account)),
    'keep the latest root-owned security counter sample readable');
ok($manager->_write_security_metrics_snapshot($account, {
    sampled_at => $security_now + 900, uptime_seconds => 30,
    evicted_keys => 1, total_commands_processed => 100, acl_access_denied_auth => 5,
}), 'store a post-restart sample when the authentication counter itself increased');
my $auth_restart_sample = $manager->_read_security_metrics_snapshot($account);
ok($auth_restart_sample && !defined($auth_restart_sample->{auth_window_seconds})
    && !defined($auth_restart_sample->{auth_failures_delta}),
    'invalidate auth deltas across process restart even when the cumulative auth counter increased');
ok($manager->_write_security_metrics_snapshot($account, {
    sampled_at => $security_now + 1800, uptime_seconds => 930,
    evicted_keys => 2, total_commands_processed => 2000, acl_access_denied_auth => 6,
}), 'record a follow-up sample after the restarted process establishes its baseline');
my $auth_restart_recovered = $manager->_read_security_metrics_snapshot($account);
ok($auth_restart_recovered && $auth_restart_recovered->{auth_window_seconds} == 900
    && $auth_restart_recovered->{auth_failures_delta} == 1,
    'resume authentication-failure evidence only after a compatible post-restart interval');
unlink($security_metrics_path) or die "reset security metrics fixture for gap test: $!";
$manager->_write_security_metrics_snapshot($account, {
    sampled_at => $security_now - 27 * 3600, uptime_seconds => 1000,
    evicted_keys => 8, total_commands_processed => 50000, acl_access_denied_auth => 8,
});
$manager->_write_security_metrics_snapshot($account, {
    sampled_at => $security_now - 60, uptime_seconds => 27 * 3600 + 940,
    evicted_keys => 9, total_commands_processed => 51000, acl_access_denied_auth => 9,
});
my $gapped_security_sample = $manager->_read_security_metrics_snapshot($account);
ok($gapped_security_sample && !defined($gapped_security_sample->{window_seconds}),
    'leave rate evidence unknown when the sample gap exceeds the 26-hour bound');
$manager->_write_security_metrics_snapshot($account, {
    sampled_at => $security_now, uptime_seconds => 3601,
});
my $unavailable_security_sample = $manager->_read_security_metrics_snapshot($account);
ok($unavailable_security_sample && $unavailable_security_sample->{available} == 0
    && !defined($unavailable_security_sample->{evicted_keys})
    && $unavailable_security_sample->{auth_available} == 0,
    'represent missing Redis counter fields explicitly as unavailable');
unlink($security_metrics_path) or die "reset security metrics fixture for unsupported-auth test: $!";
$manager->_write_security_metrics_snapshot($account, {
    sampled_at => $security_now - 7200, uptime_seconds => 3600,
    evicted_keys => 4, total_commands_processed => 50000,
});
$manager->_write_security_metrics_snapshot($account, {
    sampled_at => $security_now - 3600, uptime_seconds => 7200,
    evicted_keys => 6, total_commands_processed => 68000,
});
my $unsupported_auth_sample = $manager->_read_security_metrics_snapshot($account);
ok($unsupported_auth_sample && $unsupported_auth_sample->{available} == 1
    && $unsupported_auth_sample->{window_seconds} == 3600
    && $unsupported_auth_sample->{auth_available} == 0
    && !defined($unsupported_auth_sample->{auth_failures_delta}),
    'preserve supported eviction and operation rates when older Redis lacks the optional auth counter');
unlink($security_metrics_path) or die "remove security metrics fixture: $!";
my $last_good_info = $metrics_info;
$metrics_info = join("\n", 'used_memory:3145728', 'used_memory_peak:4194304', 'connected_clients:7',
    'uptime_in_seconds:7200', 'instantaneous_ops_per_sec:24', 'keyspace_hits:180', 'keyspace_misses:20',
    'evicted_keys:8', 'total_commands_processed:68000', 'acl_access_denied_auth:107', '');
$fail_metrics_commit_once = 1;
my $uncached_metrics = $manager->dispatch('instance.metrics', $account);
ok($uncached_metrics->{success} && !$uncached_metrics->{stale} && !$uncached_metrics->{retained}
    && $uncached_metrics->{memory_used_bytes} == 3145728,
    'return a live-only sample and flag a snapshot persistence failure');
$metrics_info = undef;
my $stale_metrics = $manager->dispatch('instance.metrics', $account);
ok($stale_metrics->{success} && $stale_metrics->{stale} && $stale_metrics->{retained}
    && $stale_metrics->{memory_used_bytes} == 1048576,
    'retain and mark the last successfully saved sample when probing fails');
$metrics_info = $last_good_info;
is_deeply($metrics_calls[0], ['redis', "$data_instances/ormtest/redis.sock"],
    'probe the trusted account socket with the manifest backend');
my $metrics_frame = '{"operation":"instance.metrics","version":1}' . "\n";
my $metrics_response = Orm::Broker::Handler->handle_frame($metrics_frame, $account->{uid}, $resolver, $manager);
my $decoded_metrics = JSON::PP->new->decode($metrics_response);
ok($decoded_metrics->{success} && $decoded_metrics->{connected_clients} == 3,
    'route account metrics through peer-credential resolution');
my $history = $manager->dispatch('metrics.history', $account, undef, undef, undef, '24h');
diag('initial history response: ' . JSON::PP->new->canonical(1)->encode($history))
    if !$history->{success} || !$history->{scheduled} || !@{$history->{history} // []};
ok($history->{success} && $history->{range} eq '24h' && $history->{scheduled}
    && @{$history->{history}} <= 24 && @{$history->{history}} > 0
    && $history->{history}->[-1]->{connected_clients} == 3,
    'return bounded account-scoped hourly metrics history and report scheduled collection');
my $history_file = "$etc_instances/ormtest/metrics-history.json";
my @history_stat = stat($history_file);
is($history_stat[4], $<, 'keep hourly history owned by the privileged manager');
is($history_stat[2] & 0777, 0600, 'keep hourly history private to root');
is((stat("$etc_instances/ormtest/metrics-history.lock"))[2] & 0777, 0600,
    'keep the history coordination lock private to root');
my $history_frame = '{"operation":"metrics.history","range":"7d","version":1}' . "\n";
my $history_response = JSON::PP->new->decode(Orm::Broker::Handler->handle_frame(
    $history_frame, $account->{uid}, $resolver, $manager));
ok($history_response->{success} && $history_response->{range} eq '7d',
    'route the selected history range through peer-credential account resolution');
is($manager->dispatch('metrics.history', $account, undef, undef, undef, '30d')->{error}, 'invalid_request',
    'reject unsupported metrics history ranges');
is($manager->dispatch('metrics.history', { name => 'ormother', uid => $< + 1, gid => $account->{gid} }, undef, undef, undef, '24h')->{error}, 'not_configured',
    'keep metric history isolated to the authenticated account');
my $same_hour_history = $manager->dispatch('metrics.history', $account, undef, undef, undef, '24h');
my $repeated_sample = {
    commands_per_second => 12, connected_clients => 9, keyspace_hits => 90, keyspace_misses => 10,
    memory_peak_bytes => 2097152, memory_used_bytes => 1048576, uptime_seconds => 3600,
    sampled_at => $same_hour_history->{history}->[-1]->{sampled_at},
};
ok($manager->_write_metrics_history($account, $repeated_sample), 'persist a replacement for a sampled hour');
my $replaced_history = $manager->dispatch('metrics.history', $account, undef, undef, undef, '24h');
is(scalar @{$replaced_history->{history}}, scalar @{$same_hour_history->{history}},
    'replace repeated samples in the same hourly bucket instead of adding duplicate points');
is($replaced_history->{history}->[-1]->{connected_clients}, 9, 'keep the latest sample values for a repeated hour');
my $history_lock_path = "$etc_instances/ormtest/metrics-history.lock";
open(my $held_history_lock, '+<', $history_lock_path) or die "open metrics history lock: $!";
flock($held_history_lock, LOCK_EX) or die "hold metrics history lock: $!";
is($manager->dispatch('metrics.history', $account, undef, undef, undef, '24h')->{error}, 'metrics_history_unavailable',
    'fail closed while another process is writing the history file');
close($held_history_lock) or die "release metrics history lock: $!";
my @history_fixture;
my $history_now = time;
for my $index (0 .. 719) {
    push @history_fixture, {
        commands_per_second => 12, connected_clients => 3, keyspace_hits => 90, keyspace_misses => 10,
        memory_peak_bytes => 2097152, memory_used_bytes => 1048576, uptime_seconds => 3600,
        sampled_at => int($history_now - (720 - $index) * 3600),
    };
}
open(my $history_fixture_file, '>', $history_file) or die "write bounded history fixture: $!";
print {$history_fixture_file} JSON::PP->new->canonical(1)->encode(\@history_fixture) . "\n";
close($history_fixture_file) or die "close bounded history fixture: $!";
chmod(0600, $history_file) or die "chmod bounded history fixture: $!";
chown($<, $<, $history_file) or die "chown bounded history fixture: $!";
my $bounded_history = $manager->dispatch('metrics.history', $account, undef, undef, undef, '7d');
diag('bounded history response: ' . JSON::PP->new->canonical(1)->encode($bounded_history))
    if !$bounded_history->{success} || @{$bounded_history->{history} // []} > 168;
ok($bounded_history->{success} && @{$bounded_history->{history}} <= 168,
    'return at most one week of hourly points from retained history');
my $invalid_history_path = "$etc_instances/ormtest/metrics-history.json";
open(my $invalid_history_file, '>', $invalid_history_path) or die "write invalid history fixture: $!";
print {$invalid_history_file} '{"unexpected":[]}' . "\n";
close($invalid_history_file) or die "close invalid history fixture: $!";
chmod(0600, $invalid_history_path) or die "chmod invalid history fixture: $!";
chown($<, $<, $invalid_history_path) or die "chown invalid history fixture: $!";
is($manager->dispatch('metrics.history', $account, undef, undef, undef, '24h')->{error}, 'metrics_history_unavailable',
    'reject malformed history instead of returning partial data');
is($manager->dispatch('instance.status', { name => 'ormother', uid => $< + 1, gid => $account->{gid} })->{state},
    'not_configured', 'another account cannot see the first account manifest');
is($manager->dispatch('instance.stop', $account)->{state}, 'stopped', 'stop the account-scoped unit');
my $stopped_metrics = $manager->dispatch('instance.metrics', $account);
ok($stopped_metrics->{success} && $stopped_metrics->{stale} && $stopped_metrics->{retained}
    && $stopped_metrics->{memory_used_bytes} == 1048576,
    'show the last sample with a stale marker while the instance is stopped');
is($manager->dispatch('instance.start', $account)->{state}, 'running', 'start the account-scoped unit');
my $settings = { memory_mib => 48, maxmemory_policy => 'allkeys-lfu', maxclients => 50, timeout => 60 };
my $config_calls_before_invalid = scalar @config_calls;
is($manager->dispatch('instance.configure', $account, undef, { %{$settings}, memory_mib => 65 })->{error},
    'invalid_request', 'reject an over-cap configuration in the manager');
is(scalar @config_calls, $config_calls_before_invalid, 'do not call Redis for invalid settings');
$unit_state = 'activating';
is($manager->dispatch('instance.configure', $account, undef, $settings)->{error},
    'instance_unavailable', 'reject configuration while the service is changing state');
is(scalar @config_calls, $config_calls_before_invalid, 'do not apply settings during a service transition');
$unit_state = 'active';
my $configured = $manager->dispatch('instance.configure', $account, undef, $settings);
ok($configured->{success} && $configured->{state} eq 'running', 'apply bounded settings to a running instance');
is_deeply($configured->{config}, $settings, 'return the selected settings after a successful update');
is_deeply(\%runtime_settings, $settings, 'apply the settings to the live runtime');
is_deeply([map { $_->[2] } @config_calls], ['maxmemory-policy', 'maxclients', 'timeout', 'maxmemory'],
    'use only the four fixed Redis CONFIG parameters');
is($config_calls[3]->[3], 48 * 1024 * 1024, 'apply the potentially evicting memory change last and send bytes');
my $config_file_text;
open(my $configured_file, '<', "$etc_instances/ormtest/redis.conf") or die "read configured Redis config: $!";
$config_file_text = do { local $/; <$configured_file> };
close($configured_file);
like($config_file_text, qr/^maxmemory 50331648$/m, 'persist the configured memory ceiling');
like($config_file_text, qr/^maxmemory-policy allkeys-lfu$/m, 'persist the selected eviction policy');
my $handler_config = Orm::Broker::Handler->handle_frame($config_request, $account->{uid}, $resolver, $manager);
my $decoded_config = JSON::PP->new->decode($handler_config);
ok($decoded_config->{success} && $decoded_config->{config}->{memory_mib} == 48,
    'route only allowlisted settings through the peer-credential handler');
my $handler_settings = { memory_mib => 48, maxmemory_policy => 'allkeys-lru', maxclients => 50, timeout => 0 };
is_deeply(\%runtime_settings, $handler_settings, 'apply the canonical handler request values');
$fail_config_once = 'timeout';
my $failed_settings = { memory_mib => 56, maxmemory_policy => 'allkeys-lru', maxclients => 60, timeout => 90 };
my $config_failure = $manager->dispatch('instance.configure', $account, undef, $failed_settings);
is($config_failure->{error}, 'configuration_failed', 'report a rejected setting after restoring changed runtime values');
is($manager->dispatch('instance.status', $account)->{config}->{memory_mib}, 48,
    'preserve the saved configuration after a rolled-back update');
is_deeply(\%runtime_settings, $handler_settings, 'restore the exact prior live values after a failed update');

my $calls_before_unavailable = scalar @config_calls;
$fail_config_get = 1;
is($manager->dispatch('instance.configure', $account, undef, $failed_settings)->{error},
    'configuration_unavailable', 'refuse changes when current runtime settings cannot be read');
$fail_config_get = 0;
is(scalar @config_calls, $calls_before_unavailable, 'do not change runtime values when the initial read fails');

%runtime_settings = (memory_mib => 40, maxmemory_policy => 'allkeys-random', maxclients => 70, timeout => 45);
$fail_config_once = 'timeout';
is($manager->dispatch('instance.configure', $account, undef, $failed_settings)->{error},
    'configuration_failed', 'rollback a failed update to out-of-band runtime values');
is_deeply(\%runtime_settings, { memory_mib => 40, maxmemory_policy => 'allkeys-random', maxclients => 70, timeout => 45 },
    'preserve tenant runtime changes when a configuration update fails');

%runtime_settings = %{$settings};
$fail_config_commit_once = 1;
my $commit_failure_settings = { memory_mib => 40, maxmemory_policy => 'volatile-lfu', maxclients => 45, timeout => 90 };
is($manager->dispatch('instance.configure', $account, undef, $commit_failure_settings)->{error},
    'configuration_storage_unavailable', 'roll back runtime changes when atomic file replacement fails');
is_deeply(\%runtime_settings, $settings, 'restore live values after a config-file commit failure');
is($manager->dispatch('instance.status', $account)->{config}->{memory_mib}, 48,
    'keep the prior saved config when the atomic commit fails');

my $config_calls_before_uncertain = scalar @config_calls;
$fail_config_always = 'timeout';
my $uncertain_settings = { memory_mib => 56, maxmemory_policy => 'allkeys-lru', maxclients => 60, timeout => 120 };
is($manager->dispatch('instance.configure', $account, undef, $uncertain_settings)->{error},
    'configuration_uncertain', 'report when runtime rollback cannot be confirmed');
undef $fail_config_always;
ok(scalar(@config_calls) > $config_calls_before_uncertain, 'attempt rollback after an uncertain runtime update');
my $calls_before_stopped_config = scalar @config_calls;
is($manager->dispatch('instance.stop', $account)->{state}, 'stopped', 'stop the account-scoped unit');
my $stopped_settings = { memory_mib => 32, maxmemory_policy => 'volatile-lru', maxclients => 40, timeout => 30 };
my $stopped_config = $manager->dispatch('instance.configure', $account, undef, $stopped_settings);
ok($stopped_config->{success} && $stopped_config->{state} eq 'stopped', 'save settings without starting a stopped service');
is(scalar @config_calls, $calls_before_stopped_config, 'do not issue runtime commands when the service is stopped');
is($manager->dispatch('instance.status', $account)->{config}->{memory_mib}, 32,
    'read stopped-service settings back from its trusted config file');
$unit_state = 'failed';
my $failed_service_config = { memory_mib => 40, maxmemory_policy => 'allkeys-lfu', maxclients => 45, timeout => 15 };
my $failed_service_result = $manager->dispatch('instance.configure', $account, undef, $failed_service_config);
ok($failed_service_result->{success} && $failed_service_result->{state} eq 'failed',
    'keep a failed service state when saving configuration for its next start');
is(scalar @config_calls, $calls_before_stopped_config, 'do not issue runtime commands for a failed service');
$unit_state = 'inactive';
is($manager->dispatch('instance.start', $account)->{state}, 'running', 'start the account-scoped unit');
my $auth_status = $manager->dispatch('instance.auth.status', $account);
ok($auth_status->{success} && JSON::PP::is_bool($auth_status->{auth_configured})
    && !$auth_status->{auth_configured}, 'report passwordless AUTH state as a boolean only');
my $auth_config_path = "$etc_instances/ormtest/redis.conf";
$fail_auth_probe_once = 1;
is($manager->dispatch('instance.auth.rotate', $account)->{error}, 'auth_rotation_failed',
    'restore the previous passwordless configuration when the new AUTH probe fails');
is_deeply($auth_audit[-1], [$account->{uid}, 'ormtest', 'auth.rotate', 'auth_rotation_failed', 'running'],
    'audit a verified AUTH rollback using fixed metadata only');
is($manager->dispatch('instance.auth.status', $account)->{auth_configured}, JSON::PP::false,
    'retain the previous disabled AUTH state after a verified rollback');
$fail_config_commit_once = 1;
is($manager->dispatch('instance.auth.rotate', $account)->{error}, 'configuration_storage_unavailable',
    'do not restart the service when the atomic AUTH config commit fails');
is($manager->dispatch('instance.auth.status', $account)->{auth_configured}, JSON::PP::false,
    'leave AUTH disabled after an atomic credential write failure');
my $auth_rotation = $manager->dispatch('instance.auth.rotate', $account);
ok($auth_rotation->{success} && $auth_rotation->{auth_configured}
    && $auth_rotation->{secret} =~ /\A[A-Za-z0-9_-]{43}\z/,
    'generate and return a one-time URL-safe per-account AUTH credential after restart verification');
my $rotated_secret = $auth_rotation->{secret};
is_deeply($auth_audit[-1], [$account->{uid}, 'ormtest', 'auth.rotate', 'success', 'running'],
    'audit successful AUTH rotation without adding the password to the audit event');
open(my $auth_config_file, '<', $auth_config_path) or die "read rotated AUTH config: $!";
my $auth_config_text = do { local $/; <$auth_config_file> };
close($auth_config_file) or die "close rotated AUTH config: $!";
like($auth_config_text, qr/^requirepass \Q$rotated_secret\E$/m,
    'persist the generated AUTH secret only in the private instance config');
my $auth_configured_status = $manager->dispatch('instance.auth.status', $account);
ok($auth_configured_status->{success} && $auth_configured_status->{auth_configured} == JSON::PP::true,
    'report AUTH as configured after a verified rotation');
my @auth_config_stat = stat($auth_config_path);
ok(@auth_config_stat && $auth_config_stat[4] == $< && $auth_config_stat[5] == $test_gid
    && ($auth_config_stat[2] & 0777) == 0640,
    'keep the generated password in the manager-owned account-group-readable config mode');
my $auth_status_json = JSON::PP->new->canonical(1)->encode($manager->dispatch('instance.auth.status', $account));
unlike($auth_status_json, qr/\Q$rotated_secret\E/, 'never return the credential from the masked AUTH status operation');
my $status_json = JSON::PP->new->canonical(1)->encode($manager->dispatch('instance.status', $account));
unlike($status_json, qr/\Q$rotated_secret\E/, 'never return the credential in ordinary instance status');
my $metrics_after_auth = $manager->dispatch('instance.metrics', $account);
unlike(JSON::PP->new->canonical(1)->encode($metrics_after_auth), qr/\Q$rotated_secret\E/,
    'never include AUTH material in metrics');
my $config_after_auth = $manager->dispatch('instance.configure', $account, undef, $failed_service_config);
ok($config_after_auth->{success}, 'continue bounded configuration updates after enabling AUTH');
open(my $preserved_auth_file, '<', $auth_config_path) or die "read AUTH config after configure: $!";
my $preserved_auth_config = do { local $/; <$preserved_auth_file> };
close($preserved_auth_file) or die "close AUTH config after configure: $!";
like($preserved_auth_config, qr/^requirepass \Q$rotated_secret\E$/m,
    'preserve the credential when ordinary configuration is updated');
unlike(JSON::PP->new->canonical(1)->encode(\@auth_probe_calls), qr/\Q$rotated_secret\E/,
    'keep credentials out of AUTH verification callback arguments');
unlike(JSON::PP->new->canonical(1)->encode(\@auth_audit), qr/\Q$rotated_secret\E/,
    'keep credentials out of AUTH audit metadata');
$fail_auth_probe_once = 1;
is($manager->dispatch('instance.auth.disable', $account)->{error}, 'auth_disable_failed',
    'restore the authenticated configuration when disabling AUTH fails its PING check');
is_deeply($auth_audit[-1], [$account->{uid}, 'ormtest', 'auth.disable', 'auth_disable_failed', 'running'],
    'audit a verified AUTH-disable rollback using fixed metadata only');
is($manager->dispatch('instance.auth.status', $account)->{auth_configured}, JSON::PP::true,
    'retain AUTH after a verified disable rollback');
my $auth_disabled = $manager->dispatch('instance.auth.disable', $account);
ok($auth_disabled->{success} && JSON::PP::is_bool($auth_disabled->{auth_configured})
    && !$auth_disabled->{auth_configured}, 'disable AUTH only after passwordless PING verification');
open(my $disabled_auth_file, '<', $auth_config_path) or die "read disabled AUTH config: $!";
my $disabled_auth_config = do { local $/; <$disabled_auth_file> };
close($disabled_auth_file) or die "close disabled AUTH config: $!";
unlike($disabled_auth_config, qr/^requirepass /m, 'remove the password directive after verified AUTH disable');
is($auth_audit[-1]->[2], 'auth.disable', 'audit AUTH disable with a fixed action name');
unlike(JSON::PP->new->canonical(1)->encode(\@auth_audit), qr/\Q$rotated_secret\E/,
    'never include the disabled password in the audit record');
$metrics_info = "used_memory:not-a-number\n";
my $malformed_stale_metrics = $manager->dispatch('instance.metrics', $account);
ok($malformed_stale_metrics->{success} && $malformed_stale_metrics->{stale} && $malformed_stale_metrics->{retained},
    'serve the last sample when live metric output is malformed');
open(my $corrupt_metrics_file, '>', $metrics_path) or die "corrupt metrics fixture: $!";
print {$corrupt_metrics_file} '{"unexpected":"field"}' . "\n";
close($corrupt_metrics_file) or die "close corrupt metrics fixture: $!";
chmod(0600, $metrics_path) or die "chmod corrupt metrics fixture: $!";
chown($<, $<, $metrics_path) or die "chown corrupt metrics fixture: $!";
is($manager->dispatch('instance.metrics', $account)->{error}, 'metrics_unavailable',
    'reject malformed cached fields instead of serving them');
open(my $outside_metrics_file, '>', "$tmp/outside_metrics.json") or die "write outside metrics fixture: $!";
print {$outside_metrics_file} JSON::PP->new->canonical(1)->encode({
    commands_per_second => 12, connected_clients => 3, keyspace_hits => 90, keyspace_misses => 10,
    memory_peak_bytes => 2097152, memory_used_bytes => 1048576, sampled_at => time,
    uptime_seconds => 3600,
}) . "\n";
close($outside_metrics_file) or die "close outside metrics fixture: $!";
chmod(0600, "$tmp/outside_metrics.json") or die "chmod outside metrics fixture: $!";
chown($<, $<, "$tmp/outside_metrics.json") or die "chown outside metrics fixture: $!";
unlink($metrics_path) or die "remove corrupt metrics fixture: $!";
symlink("$tmp/outside_metrics.json", $metrics_path) or die "symlink metrics fixture: $!";
is($manager->dispatch('instance.metrics', $account)->{error}, 'metrics_unavailable',
    'refuse a symlink even when its target contains a valid sample');
unlink($metrics_path) or die "remove metrics symlink fixture: $!";
open(my $expired_metrics_file, '>', $metrics_path) or die "write expired metrics fixture: $!";
print {$expired_metrics_file} JSON::PP->new->canonical(1)->encode({
    commands_per_second => 12, connected_clients => 3, keyspace_hits => 90, keyspace_misses => 10,
    memory_peak_bytes => 2097152, memory_used_bytes => 1048576, sampled_at => time - 31 * 24 * 60 * 60,
    uptime_seconds => 3600,
}) . "\n";
close($expired_metrics_file) or die "close expired metrics fixture: $!";
chmod(0600, $metrics_path) or die "chmod expired metrics fixture: $!";
chown($<, $<, $metrics_path) or die "chown expired metrics fixture: $!";
$unit_state = 'inactive';
is($manager->dispatch('instance.metrics', $account)->{error}, 'not_running',
    'preserve the stopped error when the saved sample is expired');
ok(!-e $metrics_path, 'remove an expired root-owned snapshot on access');
ok(!(grep { $_->[0] ne 'is-active' && $_->[-1] !~ /\A(?:orm-instance\@ormtest\.service|orm-metrics-collect\@ormtest\.timer)\z/ } @systemctl_calls),
    'only the account-specific service and metrics timer templates are controlled');
ok(!(grep { $_->[0] eq 'is-active' && $_->[1] !~ /\A(?:orm-instance\@ormtest\.service|orm-metrics-collect\@ormtest\.timer)\z/ } @systemctl_calls),
    'status never queries a global Redis, Valkey or metrics unit');
my %root_rates;
ok(!Orm::Broker::Server::_rate_allowed(\%root_rates, 0, 1, 1, 0), 'deny root broker requests by default');
ok(Orm::Broker::Server::_rate_allowed(\%root_rates, 0, 1, 1, 1), 'allow the explicitly gated root inventory operation');
ok(!Orm::Broker::Server::_rate_allowed(\%root_rates, 0, 1.1, 1, 1), 'rate-limit root inventory requests');
ok(Orm::Broker::Server::_rate_allowed(\%root_rates, 0, 2, 1, 1, 1, 'fleet.control'),
    'allow a root control action in its separate rate bucket');
ok(Orm::Broker::Server::_rate_allowed(\%root_rates, 0, 2.1, 1, 1, 1, 1),
    'keep root inventory reads available after a fleet control action');
ok(!Orm::Broker::Server::_rate_allowed(\%root_rates, 0, 2.2, 1, 1, 1, 'fleet.control'),
    'rate-limit repeated fleet control actions independently');
my %root_read_rates;
ok(Orm::Broker::Server::_rate_allowed(\%root_read_rates, 0, 10, 1, 1, 1, 'fleet.list'),
    'allow the fleet page read in its operation-specific bucket');
ok(Orm::Broker::Server::_rate_allowed(\%root_read_rates, 0, 10, 1, 1, 1, 'provider.resellers'),
    'allow reseller usage on the same WHM page without colliding with fleet inventory');
ok(Orm::Broker::Server::_rate_allowed(\%root_read_rates, 43210, 10, 2, 0, 1, 'provider.exposure'),
    'allow the account exposure lookup independently of ordinary status and metrics reads');
ok(!Orm::Broker::Server::_rate_allowed(\%root_read_rates, 0, 10.1, 1, 1, 1, 'provider.resellers'),
    'rate-limit repeated reseller summaries in their own bucket');
my %fleet_diagnostics_rates;
ok(Orm::Broker::Server::_rate_allowed(\%fleet_diagnostics_rates, 0, 20, 1, 1, 5, 'fleet.diagnostics:acct01'),
    'allow one root diagnostics request per account');
ok(Orm::Broker::Server::_rate_allowed(\%fleet_diagnostics_rates, 0, 20, 1, 1, 5, 'fleet.diagnostics:acct02'),
    'keep diagnostics rate limits independent between accounts');
ok(!Orm::Broker::Server::_rate_allowed(\%fleet_diagnostics_rates, 0, 21, 1, 1, 5, 'fleet.diagnostics:acct01'),
    'rate-limit repeated diagnostics for one account within five seconds');
ok(Orm::Broker::Server::_rate_allowed(\%fleet_diagnostics_rates, 0, 25, 1, 1, 5, 'fleet.diagnostics:acct01'),
    'allow diagnostics again when the five-second window expires');
my %fleet_recovery_rates;
ok(Orm::Broker::Server::_rate_allowed(\%fleet_recovery_rates, 0, 30, 1, 1, 15, 'fleet.recovery.scan:acct01'),
    'allow one read-only recovery scan per account in its bounded window');
ok(Orm::Broker::Server::_rate_allowed(\%fleet_recovery_rates, 0, 30, 1, 1, 15, 'fleet.recovery.scan:acct02'),
    'keep recovery scan limits independent between accounts');
ok(!Orm::Broker::Server::_rate_allowed(\%fleet_recovery_rates, 0, 44, 1, 1, 15, 'fleet.recovery.scan:acct01'),
    'rate-limit repeated scans for the same account within fifteen seconds');
ok(Orm::Broker::Server::_rate_allowed(\%fleet_recovery_rates, 0, 45, 1, 1, 15, 'fleet.recovery.scan:acct01'),
    'allow a recovery scan when its per-account window expires');
ok(Orm::Broker::Server::_rate_allowed(\%fleet_recovery_rates, 0, 30, 1, 1, 60, 'fleet.recovery.repair:acct01'),
    'allow a fixed recovery repair in its per-account slow-operation bucket');
ok(!Orm::Broker::Server::_rate_allowed(\%fleet_recovery_rates, 0, 89, 1, 1, 60, 'fleet.recovery.repair:acct01'),
    'rate-limit repeated recovery repairs within sixty seconds');
my %backup_rates;
ok(Orm::Broker::Server::_rate_allowed(\%backup_rates, 43210, 100, 1, 0, 60, 60),
    'allow one account backup operation in its sixty-second window');
ok(!Orm::Broker::Server::_rate_allowed(\%backup_rates, 43210, 101, 1, 0, 60, 60),
    'share the slow-operation limit between backup creation and restore');
ok(Orm::Broker::Server::_rate_allowed(\%backup_rates, 43210, 101, 4, 0, 1, 1),
    'keep ordinary account operations available while backup restore is rate-limited');
my %fleet_backup_rates;
ok(Orm::Broker::Server::_rate_allowed(\%fleet_backup_rates, 0, 100, 1, 1, 60, 'fleet.backup:acct01'),
    'allow a root fleet backup in its per-account slow-operation bucket');
ok(Orm::Broker::Server::_rate_allowed(\%fleet_backup_rates, 0, 101, 1, 1, 60, 'fleet.backup:acct02'),
    'rate-limit fleet backup actions per account instead of blocking the whole fleet');
ok(!Orm::Broker::Server::_rate_allowed(\%fleet_backup_rates, 0, 101, 1, 1, 60, 'fleet.backup:acct01'),
    'share the slow-operation limit between snapshot creation and restore for one account');
my %fleet_migration_rates;
ok(Orm::Broker::Server::_rate_allowed(\%fleet_migration_rates, 0, 100, 1, 1, 60, 'fleet.migrate:acct01'),
    'allow one root migration per account in its bounded slow-operation bucket');
ok(Orm::Broker::Server::_rate_allowed(\%fleet_migration_rates, 0, 101, 1, 1, 60, 'fleet.migrate:acct02'),
    'rate-limit long migrations per account rather than blocking other accounts');
ok(!Orm::Broker::Server::_rate_allowed(\%fleet_migration_rates, 0, 101, 1, 1, 60, 'fleet.migrate:acct01'),
    'rate-limit repeated migration attempts for the same account');
my $manifest_path = "$etc_instances/ormtest/manifest.json";
ok(-f $manifest_path, 'provisioning writes a trusted manifest');
my @manifest_stat = stat($manifest_path);
is($manifest_stat[4], $<, 'manifest is owned by the privileged manager');
is($manifest_stat[5], $account->{gid}, 'manifest is readable by only the account group');
my $data_path = "$data_instances/ormtest";
my @data_stat = stat($data_path);
is($data_stat[4], $account->{uid}, 'runtime data belongs to the cPanel account');
is($data_stat[2] & 0777, 0700, 'runtime data is private to the cPanel account');
open(my $config_file, '<', "$etc_instances/ormtest/redis.conf") or die "read generated config: $!";
my $generated_config = do { local $/; <$config_file> };
close($config_file);
like($generated_config, qr/^port 0$/m, 'Redis TCP listener is disabled');
like($generated_config, qr/^unixsocketperm 700$/m, 'Redis Unix socket is account-private');
like($generated_config, qr/^maxmemory 41943040$/m, 'saved failed-service config keeps its selected memory setting');
my $wordpress_account = { name => 'ormwp', uid => $account->{uid}, gid => $account->{gid} };
my $wordpress_provisioned = $manager->dispatch('instance.provision', $wordpress_account, 'wordpress');
ok($wordpress_provisioned->{success} && $wordpress_provisioned->{preset} eq 'wordpress',
    'provision an account with its selected fixed preset');
open(my $wordpress_config, '<', "$etc_instances/ormwp/redis.conf") or die "read WordPress config: $!";
my $wordpress_config_text = do { local $/; <$wordpress_config> };
close($wordpress_config);
like($wordpress_config_text, qr/^maxmemory 50331648$/m, 'WordPress preset applies its bounded memory value');
my $bad_preset = $manager->dispatch('instance.provision', { name => 'badpreset', uid => $account->{uid}, gid => $account->{gid} }, '../root');
is($bad_preset->{error}, 'invalid_request', 'reject unknown provisioning presets');
my $forged = $manager->dispatch('instance.start', { name => 'ormtest', uid => $< + 1, gid => $account->{gid} });
ok(!$forged->{success}, 'manifest UID mismatch fails closed');
ok(!$manager->dispatch('instance.some-other-action', $account)->{success}, 'unknown lifecycle operation is rejected');
open(my $legacy_manifest_file, '>', $manifest_path) or die "rewrite legacy manifest fixture: $!";
print {$legacy_manifest_file} JSON::PP->new->canonical(1)->encode({
    backend => 'redis', config => "$etc_instances/ormtest/redis.conf", data => $data_path,
    gid => $account->{gid}, socket => "$data_instances/ormtest/redis.sock", uid => $account->{uid}, version => 1,
}) . "\n";
close($legacy_manifest_file) or die "close legacy manifest fixture: $!";
chmod(0640, $manifest_path) or die "chmod legacy manifest fixture: $!";
chown($<, $account->{gid}, $manifest_path) or die "chown legacy manifest fixture: $!";
is($manager->dispatch('instance.status', $account)->{preset}, 'generic', 'read legacy v1 manifests as the generic preset');
my $no_policy = Orm::Broker::BackendPolicy->new(path => "$tmp/etc/missing-policy.json", expected_owner_uid => $<);
my $no_policy_manager = Orm::Broker::InstanceManager->new(
    etc_root => $etc_instances, data_root => $data_instances, policy => $no_policy,
    expected_owner_uid => $<, binary_probe => sub { 1 },
);
is($no_policy_manager->dispatch('instance.provision', { name => 'newacct', uid => $<, gid => $account->{gid} })->{error},
    'backend_policy_required', 'provisioning requires an explicit provider backend policy');

socketpair(my $left, my $right, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die "socketpair: $!";
is(Orm::Broker::PeerCredentials->uid_from_socket($left), $<, 'read peer UID from Linux socket credentials');
close($left);
close($right);

done_testing();
