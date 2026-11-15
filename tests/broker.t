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
for my $preset (qw(wordpress laravel magento session generic)) {
    my $frame = '{"operation":"instance.provision","preset":"' . $preset . '","version":1}' . "\n";
    is(parse_request($frame)->{preset}, $preset, "accept the fixed $preset provisioning preset");
}
for my $invalid (
    '', '{}', $request . "\n", '{"version":1,"operation":"identity"}' . "\n",
    '{"operation":"identity","version":2}' . "\n", ('x' x (max_frame_bytes() + 1)),
    '{"operation":"instance.provision","preset":"../../root","version":1}' . "\n",
    '{"operation":"instance.start","preset":"generic","version":1}' . "\n",
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

chmod(0666, $account_file) or die "make writable account fixture: $!";
ok(!defined($resolver->resolve_uid(43210)), 'reject group/world-writable account file');
chmod(0644, $account_file) or die "restore account fixture mode: $!";
unlink($account_file) or die "remove account fixture: $!";
symlink("$tmp/outside", $account_file) or die "create symlink fixture: $!";
ok(!defined($resolver->resolve_uid(43210)), 'reject a symlink account file');
unlink($account_file) or die "remove symlink fixture: $!";
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
my $account = { name => 'ormtest', uid => $<, gid => $test_gid };
is($manager->dispatch('instance.status', $account)->{state}, 'not_configured', 'status is scoped to an unconfigured account');
my $provisioned = $manager->dispatch('instance.provision', $account);
ok($provisioned->{success} && $provisioned->{state} eq 'running', 'provision and start a private account instance');
is($provisioned->{preset}, 'generic', 'default new instances to the generic preset');
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
