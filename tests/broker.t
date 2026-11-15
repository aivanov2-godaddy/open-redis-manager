use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use Fcntl qw(:mode);
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);
use lib 'src';
use Orm::Broker::AccountResolver;
use Orm::Broker::Handler;
use Orm::Broker::BackendPolicy;
use Orm::Broker::InstanceManager;
use Orm::Broker::PeerCredentials;
use Orm::Broker::Server;
use Orm::Broker::Protocol qw(parse_request encode_response max_frame_bytes);

my $request = '{"operation":"identity","version":1}' . "\n";
is(parse_request($request)->{operation}, 'identity', 'accept the one canonical identity request');
for my $operation (qw(instance.status instance.provision instance.start instance.stop)) {
    my $frame = '{"operation":"' . $operation . '","version":1}' . "\n";
    is(parse_request($frame)->{operation}, $operation, "accept fixed operation $operation");
}
is(parse_request('{"operation":"instance.metrics","version":1}' . "\n")->{operation},
    'instance.metrics', 'accept the fixed instance metrics request');
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
    '{"maxclients":50,"maxmemory_policy":"allkeys-lru","memory_mib":65,"operation":"instance.configure","timeout":0,"version":1}' . "\n",
    '{"maxclients":50,"maxmemory_policy":"allkeys-lru","memory_mib":"48","operation":"instance.configure","timeout":0,"version":1}' . "\n",
    '{"maxclients":101,"maxmemory_policy":"allkeys-lru","memory_mib":48,"operation":"instance.configure","timeout":0,"version":1}' . "\n",
    '{"maxclients":50,"maxmemory_policy":"arbitrary","memory_mib":48,"operation":"instance.configure","timeout":0,"version":1}' . "\n",
    '{"maxclients":50,"maxmemory_policy":"allkeys-lru","memory_mib":48,"operation":"instance.configure","timeout":301,"version":1}' . "\n",
    '{"operation":"instance.configure","maxclients":50,"maxmemory_policy":"allkeys-lru","memory_mib":48,"timeout":0,"version":1}' . "\n",
) {
    ok(!parse_request($invalid), 'reject a non-canonical or oversized request');
}
like(encode_response({ success => JSON::PP::true, version => 1 }), qr/\n\z/, 'responses end in one line feed');
ok(!encode_response([]), 'response encoder rejects non-object payloads');

my $tmp = tempdir(CLEANUP => 1);
my $account_root = "$tmp/accounts";
my @test_groups = split /\s+/, $);
my $test_gid = 0 + ($test_groups[0] // $<);
make_path($account_root);
chmod(0755, $account_root) or die "chmod account root: $!";
my $account_file = "$account_root/ormtest";
open(my $file, '>', $account_file) or die "create account fixture: $!";
print {$file} "SHELL=/bin/bash\n";
close($file) or die "close account fixture: $!";
chmod(0644, $account_file) or die "chmod account fixture: $!";

my $resolver = Orm::Broker::AccountResolver->new(
    account_root => $account_root,
    expected_owner_uid => $<,
    lookup => sub { return { name => 'ormtest', uid => $_[0], gid => $test_gid }; },
);
is($resolver->resolve_uid(43210), 'ormtest', 'resolve a mapped UID through a trusted account record');
is_deeply($resolver->resolve_account(43210), { name => 'ormtest', uid => 43210, gid => $test_gid }, 'resolve trusted UID and primary GID');
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

my $unit_state = 'inactive';
my $metrics_info = join("\r\n",
    'used_memory:1048576', 'used_memory_peak:2097152', 'connected_clients:3',
    'uptime_in_seconds:3600', 'instantaneous_ops_per_sec:12', 'keyspace_hits:90', 'keyspace_misses:10', '');
my @metrics_calls;
my @systemctl_calls;
my @config_calls;
my $fail_config_once;
my $fail_config_always;
my $fail_config_commit_once;
my $fail_config_get;
my %runtime_settings = (memory_mib => 64, maxmemory_policy => 'allkeys-lru', maxclients => 100, timeout => 0);
my $manager = Orm::Broker::InstanceManager->new(
    etc_root => $etc_instances,
    data_root => $data_instances,
    policy => $policy,
    expected_owner_uid => $<,
    binary_paths => { redis => ['/usr/bin/redis-server'], valkey => ['/usr/bin/valkey-server'] },
    binary_probe => sub { return $_[0] eq 'redis' && $_[1] eq '/usr/bin/redis-server'; },
    metrics_probe => sub {
        push @metrics_calls, [@_];
        return $metrics_info;
    },
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
    atomic_commit => sub {
        my ($temporary, $path) = @_;
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
            return ($unit_state eq 'active' || $unit_state eq 'activating' || $unit_state eq 'deactivating', $unit_state);
        }
        if ($args[0] eq 'start') { $unit_state = 'active'; return (1, ''); }
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
my $provisioned = $manager->dispatch('instance.provision', $account);
ok($provisioned->{success} && $provisioned->{state} eq 'running', 'provision and start a private account instance');
is($provisioned->{preset}, 'generic', 'default new instances to the generic preset');
is_deeply($provisioned->{config}, { memory_mib => 64, maxmemory_policy => 'allkeys-lru', maxclients => 100, timeout => 0 },
    'return validated saved settings in the instance status');
my $metrics = $manager->dispatch('instance.metrics', $account);
ok($metrics->{success}, 'collect current metrics for the running account instance');
is_deeply([@{$metrics}{qw(memory_used_bytes memory_peak_bytes connected_clients uptime_seconds commands_per_second keyspace_hits keyspace_misses)}],
    [1048576, 2097152, 3, 3600, 12, 90, 10], 'return only parsed numeric metrics');
is_deeply([sort keys %{$metrics}], [qw(commands_per_second connected_clients keyspace_hits keyspace_misses memory_peak_bytes memory_used_bytes success uptime_seconds version)],
    'metrics response contains only the fixed numeric allowlist and envelope');
is_deeply($metrics_calls[0], ['redis', "$data_instances/ormtest/redis.sock"],
    'probe the trusted account socket with the manifest backend');
my $metrics_frame = '{"operation":"instance.metrics","version":1}' . "\n";
my $metrics_response = Orm::Broker::Handler->handle_frame($metrics_frame, $account->{uid}, $resolver, $manager);
my $decoded_metrics = JSON::PP->new->decode($metrics_response);
ok($decoded_metrics->{success} && $decoded_metrics->{connected_clients} == 3,
    'route account metrics through peer-credential resolution');
is($manager->dispatch('instance.status', { name => 'ormother', uid => $< + 1, gid => $account->{gid} })->{state},
    'not_configured', 'another account cannot see the first account manifest');
is($manager->dispatch('instance.stop', $account)->{state}, 'stopped', 'stop the account-scoped unit');
is($manager->dispatch('instance.metrics', $account)->{error}, 'not_running', 'do not collect metrics for a stopped instance');
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
$metrics_info = "used_memory:not-a-number\n";
is($manager->dispatch('instance.metrics', $account)->{error}, 'metrics_unavailable', 'reject malformed or incomplete metric output');
ok(!(grep { $_->[-1] !~ /\Aorm-instance\@ormtest\.service\z/ && $_->[0] ne 'is-active' } @systemctl_calls),
    'only the account-specific ORM systemd template is controlled');
ok(!(grep { $_->[0] eq 'is-active' && $_->[1] !~ /\Aorm-instance\@ormtest\.service\z/ } @systemctl_calls),
    'status never queries a global Redis or Valkey unit');
my %root_rates;
ok(!Orm::Broker::Server::_rate_allowed(\%root_rates, 0, 1, 1, 0), 'deny root broker requests by default');
ok(Orm::Broker::Server::_rate_allowed(\%root_rates, 0, 1, 1, 1), 'allow the explicitly gated root inventory operation');
ok(!Orm::Broker::Server::_rate_allowed(\%root_rates, 0, 1.1, 1, 1), 'rate-limit root inventory requests');
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
like($generated_config, qr/^maxmemory 67108864$/m, 'generic preset uses the fixed 64 MiB ceiling');
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
