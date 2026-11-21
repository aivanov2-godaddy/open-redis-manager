use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use IO::Socket::UNIX;
use Socket qw(SOCK_STREAM);
use POSIX ();
use Digest::SHA qw(sha256_hex);
use lib 'src';
use Orm::Broker::PodmanMetricsCollector;

plan skip_all => 'root-socket fixtures require Linux and a non-root test account'
    if $^O ne 'linux' || $> == 0;

my $uid = $<;
my $gid = $(;
$gid =~ s/ .*//;
is(Orm::Broker::PodmanMetricsCollector::_peer_uid_from_credentials(pack('iii', 4321, 1234, 5678)), 1234,
    'read the peer user ID from the middle SO_PEERCRED field');
ok(!defined(Orm::Broker::PodmanMetricsCollector::_peer_uid_from_credentials("short")),
    'reject incomplete SO_PEERCRED data');
my $base = tempdir('orm-podman-metrics-XXXXXX', TMPDIR => 1, CLEANUP => 1);
my $account_root = "$base/cpanel-users";
my $home = "$base/home/ormtest";
my $podman_root = "$home/ea-podman.d";
my $container = 'ea-redis62.ormtest.01';
my $container_dir = "$podman_root/$container";
my $socket_path = "$container_dir/redis.sock";
my $state_dir = "$base/state";
my $snapshot_path = "$state_dir/summary.json";
make_path($account_root, $home, $podman_root, $container_dir, $state_dir);
chmod 0700, $account_root, $home, $podman_root, $container_dir, $state_dir;

my $listener = IO::Socket::UNIX->new(Type => SOCK_STREAM, Local => $socket_path, Listen => 1);
ok($listener, 'create an account-owned EA Podman Redis socket fixture');
chmod 0600, $socket_path;

my %values = (
    connected_clients => 4, evicted_keys => 2, keyspace_hits => 30,
    keyspace_misses => 10, memory_used_bytes => 4096, total_commands_processed => 120,
);
my $resolver = bless { uid => $uid, gid => $gid }, 'TestResolver';
sub TestResolver::resolve_name {
    my ($self, $username) = @_;
    return undef if $ENV{ORM_TEST_UNVERIFIED};
    return { name => $username, uid => $self->{uid}, gid => $self->{gid} };
}
my $collector = Orm::Broker::PodmanMetricsCollector->new(
    account_root => $account_root,
    snapshot_path => $snapshot_path,
    resolver => $resolver,
    expected_owner_uid => $uid,
    expected_owner_gid => $gid,
    read_names => sub { return ('ormtest') },
    lookup_home => sub { return $home },
    probe => sub { return { %values } },
    clock => sub { return 1_800_000_000 },
);
my $snapshot = $collector->collect();
is($snapshot->{discovered_count}, 1, 'discover one exact-name EA Redis container');
is($snapshot->{sampled_count}, 1, 'sample one validated socket');
is($snapshot->{reachable_count}, 1, 'count one complete metrics response');
is($snapshot->{backend_counts}->{redis}, 1, 'keep Redis discovery in its own backend count');
is($snapshot->{backend_counts}->{valkey}, 0, 'do not misclassify Redis as Valkey');
is($snapshot->{metrics}->{memory_used_bytes}, 4096, 'aggregate allowlisted memory metrics');
ok(!$snapshot->{partial}, 'complete healthy collection is not marked partial');
is($snapshot->{version}, 2, 'emit the counter-window snapshot schema');
is($snapshot->{counter_window}->{status}, 'unknown', 'keep counter rates unknown when probe identity is absent');
is($snapshot->{counter_window}->{reason}, 'identity_missing', 'do not claim continuity without a valid server run ID');
my %numeric_success = (%{$snapshot}, success => 1);
ok(!Orm::Broker::PodmanMetricsCollector::_valid_snapshot(\%numeric_success),
    'reject a numeric success flag instead of a JSON boolean');
my %contradictory_scan = (%{$snapshot}, scan_complete => JSON::PP::true, unverified_account_count => 1);
ok(!Orm::Broker::PodmanMetricsCollector::_valid_snapshot(\%contradictory_scan),
    'reject a complete-scan flag with unverified accounts');

my $server_pid = fork();
die 'could not fork the Unix socket fixture server' if !defined($server_pid);
if ($server_pid == 0) {
    my $client = $listener->accept() or POSIX::_exit(2);
    my $request = '';
    sysread($client, $request, 256);
    my $body = "# Server\r\nused_memory:4096\r\n# Clients\r\nconnected_clients:4\r\n# Stats\r\ntotal_commands_processed:120\r\nevicted_keys:2\r\nkeyspace_hits:30\r\nkeyspace_misses:10\r\n";
    my $response = '$' . length($body) . "\r\n" . $body . "\r\n";
    my $written = syswrite($client, $response);
    close($client);
    POSIX::_exit(defined($written) && $written == length($response) ? 0 : 3);
}
my $socket_collector = Orm::Broker::PodmanMetricsCollector->new(
    account_root => $account_root, snapshot_path => $snapshot_path, resolver => $resolver,
    expected_owner_uid => $uid, expected_owner_gid => $gid,
    read_names => sub { return ('ormtest') }, lookup_home => sub { return $home },
    clock => sub { return 1_800_000_000 },
);
my $socket_snapshot = $socket_collector->collect();
is($socket_snapshot->{reachable_count}, 1, 'probe the Unix socket and verify peer credentials');
is($socket_snapshot->{metrics}->{memory_used_bytes}, 4096, 'parse only allowlisted RESP INFO counters');
waitpid($server_pid, 0);
is($? >> 8, 0, 'complete the local Unix socket response fixture');

chmod 0770, $container_dir;
my $unsafe_directory = $collector->collect();
is($unsafe_directory->{unmeasured_count}, 1, 'reject a container directory writable by its group');
ok($unsafe_directory->{partial}, 'unsafe socket paths remain partial instead of looking like zero');
chmod 0700, $container_dir;

my $empty_home = "$base/home/ormempty";
make_path($empty_home);
chmod 0700, $empty_home;
my $empty_account = Orm::Broker::PodmanMetricsCollector->new(
    account_root => $account_root, snapshot_path => $snapshot_path, resolver => $resolver,
    expected_owner_uid => $uid, expected_owner_gid => $gid,
    read_names => sub { return ('ormempty') },
    lookup_home => sub { return $empty_home },
    probe => sub { return { %values } }, clock => sub { return 1_800_000_000 },
);
my $empty_snapshot = $empty_account->collect();
is($empty_snapshot->{discovered_count}, 0, 'an account without an EA Podman directory has zero discovered containers');
is($empty_snapshot->{unverified_account_count}, 0, 'a missing optional EA Podman directory is not unverified');
ok(!$empty_snapshot->{partial}, 'accounts without EA Podman containers do not make coverage partial');

my $outside = "$base/home/ormoutside";
my $evil_home = "$base/home/ormevil";
make_path($outside, $evil_home);
chmod 0700, $outside, $evil_home;
symlink($outside, "$evil_home/ea-podman.d") or die 'could not create symlink fixture';
my $evil_account = Orm::Broker::PodmanMetricsCollector->new(
    account_root => $account_root, snapshot_path => $snapshot_path, resolver => $resolver,
    expected_owner_uid => $uid, expected_owner_gid => $gid,
    read_names => sub { return ('ormevil') },
    lookup_home => sub { return $evil_home },
    probe => sub { return { %values } }, clock => sub { return 1_800_000_000 },
);
my $evil_snapshot = $evil_account->collect();
is($evil_snapshot->{unverified_account_count}, 1, 'reject a symlinked EA Podman directory');
ok($evil_snapshot->{partial}, 'a hostile directory path remains unknown');

my $written = $collector->collect_and_write();
ok($written, 'write the anonymous aggregate snapshot');
my $readback = Orm::Broker::PodmanMetricsCollector->read_snapshot(
    $snapshot_path, expected_owner_uid => $uid, now => 1_800_000_100,
);
is($readback->{discovered_count}, 1, 'read back a fresh root-owned snapshot');
is($readback->{counter_window}->{status}, 'unknown', 'retain aggregate-only unknown rate state in the snapshot');
ok(!exists($readback->{username}) && !exists($readback->{container}) && !exists($readback->{socket_path}),
    'snapshot contains no account or container identifiers');
ok(!defined(Orm::Broker::PodmanMetricsCollector->read_snapshot(
    $snapshot_path, expected_owner_uid => $uid, now => 1_800_002_000,
)), 'reject an expired metrics snapshot');

my %rate_values = (%values, run_id => '0123456789abcdef0123456789abcdef01234567', acl_access_denied_auth => 1);
my $rate_time = 1_800_100_000;
my $rate_baseline_path = "$state_dir/rate-baseline.json";
my $rate_collector = Orm::Broker::PodmanMetricsCollector->new(
    account_root => $account_root, snapshot_path => $snapshot_path, baseline_path => $rate_baseline_path,
    resolver => $resolver, expected_owner_uid => $uid, expected_owner_gid => $gid,
    read_names => sub { return ('ormtest') }, lookup_home => sub { return $home },
    probe => sub { return { %rate_values } }, clock => sub { return $rate_time },
);
my $first_rate_snapshot = $rate_collector->collect();
is($first_rate_snapshot->{counter_window}->{reason}, 'first_sample', 'seed a protected continuity baseline on the first complete sample');
ok(!-e "$state_dir/counter-baseline.json" || ((stat("$state_dir/counter-baseline.json"))[2] & 0777) == 0600,
    'keep the continuity baseline private');
$rate_values{evicted_keys} += 6;
$rate_values{total_commands_processed} += 7200;
$rate_values{acl_access_denied_auth} += 3;
$rate_time += 3600;
my $second_rate_snapshot = $rate_collector->collect();
is($second_rate_snapshot->{counter_window}->{status}, 'measured', 'measure rates after an exact process-set match');
is($second_rate_snapshot->{counter_window}->{max_evictions_delta}, 6, 'measure the maximum per-process eviction delta');
is($second_rate_snapshot->{counter_window}->{max_operations_per_second}, 2, 'measure the maximum per-process operation rate');
is($second_rate_snapshot->{counter_window}->{max_auth_failures_delta}, 3, 'measure optional auth failures when both samples provide the counter');
my $baseline_text = do { local (@ARGV, $/) = ($rate_baseline_path); <> };
ok(index($baseline_text, '0123456789abcdef0123456789abcdef01234567') < 0
    && index($baseline_text, sha256_hex('0123456789abcdef0123456789abcdef01234567')) >= 0,
    'persist only the hashed run ID and never the raw identifier');
my $published_text = JSON::PP->new->canonical(1)->encode($second_rate_snapshot);
ok(index($published_text, '0123456789abcdef0123456789abcdef01234567') < 0
    && index($published_text, sha256_hex('0123456789abcdef0123456789abcdef01234567')) < 0,
    'keep process identifiers and continuity tokens out of the WHM snapshot');
ok(Orm::Broker::PodmanMetricsCollector::_write_snapshot($snapshot_path, $second_rate_snapshot, $uid, $gid),
    'write a validated continuity-window snapshot');
my $rate_readback = Orm::Broker::PodmanMetricsCollector->read_snapshot(
    $snapshot_path, expected_owner_uid => $uid, now => $rate_time + 1,
);
is($rate_readback->{counter_window}->{status}, 'measured', 'read back a measured version-two counter window');
$rate_values{run_id} = 'fedcba9876543210fedcba9876543210fedcba98';
$rate_time += 3600;
my $replacement_snapshot = $rate_collector->collect();
is($replacement_snapshot->{counter_window}->{status}, 'unknown', 'report unknown when the server process identity changes');
is($replacement_snapshot->{counter_window}->{reason}, 'process_set_changed', 'identify process replacement as a fixed unknown reason');
$rate_values{evicted_keys} = 1;
$rate_values{total_commands_processed} = 100;
$rate_values{acl_access_denied_auth} = 0;
$rate_time += 3600;
my $reset_snapshot = $rate_collector->collect();
is($reset_snapshot->{counter_window}->{status}, 'unknown', 'do not measure counters after a decrease');
is($reset_snapshot->{counter_window}->{reason}, 'counter_reset', 'identify a counter reset and reseed');
$rate_values{evicted_keys} += 2;
$rate_values{total_commands_processed} += 7200;
delete $rate_values{acl_access_denied_auth};
$rate_time += 3600;
my $optional_auth_snapshot = $rate_collector->collect();
is($optional_auth_snapshot->{counter_window}->{status}, 'measured', 'keep core counter rates when the optional auth counter disappears');
ok(!$optional_auth_snapshot->{counter_window}->{auth_available}
    && $optional_auth_snapshot->{counter_window}->{max_auth_failures_delta} == 0,
    'leave optional auth evidence unknown when either sample lacks its counter');
my $baseline_before_partial = do { local (@ARGV, $/) = ($rate_baseline_path); <> };
my $sampled_before_partial = JSON::PP->new->decode($baseline_before_partial)->{sampled_at};
{
    local $ENV{ORM_TEST_UNVERIFIED} = 1;
    my $partial_snapshot = $rate_collector->collect();
    is($partial_snapshot->{counter_window}->{reason}, 'incomplete_scan', 'keep counter rates unknown for incomplete account scans');
}
my $baseline_after_partial = do { local (@ARGV, $/) = ($rate_baseline_path); <> };
is(JSON::PP->new->decode($baseline_after_partial)->{sampled_at}, $sampled_before_partial,
    'do not replace a trusted baseline with a partial scan');
$rate_time -= 3600;
my $clock_reversal_snapshot = $rate_collector->collect();
is($clock_reversal_snapshot->{counter_window}->{reason}, 'non_monotonic_time', 'keep rates unknown after a backwards clock sample');
$rate_time += 7200;
my $clock_recovered_snapshot = $rate_collector->collect();
is($clock_recovered_snapshot->{counter_window}->{status}, 'measured', 'retain the last valid time anchor until the clock advances again');
is($clock_recovered_snapshot->{counter_window}->{window_seconds}, 3600, 'calculate the next interval from the preserved baseline');
$rate_values{total_commands_processed} += 1;
$rate_time += 2;
my $fractional_rate_snapshot = $rate_collector->collect();
is($fractional_rate_snapshot->{counter_window}->{max_operations_per_second}, 0,
    'round sub-one average operation rates down so integer thresholds do not overstate activity');

my $multi_baseline_path = "$state_dir/multi-process-baseline.json";
my @multi_samples = (
    { token => 'a' x 64, counters => { evicted_keys => 2, keyspace_hits => 10, keyspace_misses => 1, total_commands_processed => 100 } },
    { token => 'b' x 64, counters => { evicted_keys => 1, keyspace_hits => 20, keyspace_misses => 2, total_commands_processed => 200 } },
);
my $multi_first = Orm::Broker::PodmanMetricsCollector::_counter_window(
    $multi_baseline_path, $rate_time, \@multi_samples, 1, 2, $uid, $gid);
is($multi_first->{reason}, 'first_sample', 'seed a baseline with multiple verified process identities');
$multi_samples[0]->{counters}->{evicted_keys} += 8;
$multi_samples[0]->{counters}->{total_commands_processed} += 20;
$multi_samples[1]->{counters}->{evicted_keys} += 3;
$multi_samples[1]->{counters}->{total_commands_processed} += 50;
my $multi_window = Orm::Broker::PodmanMetricsCollector::_counter_window(
    $multi_baseline_path, $rate_time + 10, \@multi_samples, 1, 2, $uid, $gid);
is($multi_window->{max_evictions_delta}, 8, 'report the greatest per-process eviction delta');
is($multi_window->{max_operations_per_second}, 5, 'report the greatest per-process operation rate');
ok(!exists($multi_window->{process_tokens}) && !exists($multi_window->{entries}),
    'expose no process identity records in the aggregate counter window');
my $duplicate_window = Orm::Broker::PodmanMetricsCollector::_counter_window(
    "$state_dir/duplicate-baseline.json", $rate_time, [$multi_samples[0], $multi_samples[0]], 1, 2, $uid, $gid);
is($duplicate_window->{reason}, 'duplicate_identity', 'reject duplicate server identities in one scan');
my $stale_path = "$state_dir/stale-baseline.json";
my @stale_samples = ({ token => 'c' x 64,
    counters => { evicted_keys => 0, keyspace_hits => 0, keyspace_misses => 0, total_commands_processed => 0 } });
my $stale_first = Orm::Broker::PodmanMetricsCollector::_counter_window(
    $stale_path, $rate_time, \@stale_samples, 1, 1, $uid, $gid);
my $stale_second = Orm::Broker::PodmanMetricsCollector::_counter_window(
    $stale_path, $rate_time + 93601, \@stale_samples, 1, 1, $uid, $gid);
is($stale_second->{reason}, 'stale_baseline', 'do not measure a gap longer than 26 hours');

my $sentinel_path = "$state_dir/continuity-sentinel";
open(my $sentinel_handle, '>', $sentinel_path) or die 'could not create the continuity sentinel';
print {$sentinel_handle} 'preserve';
close($sentinel_handle) or die 'could not close the continuity sentinel';
chmod 0600, $sentinel_path;
my $unsafe_baseline_path = "$state_dir/unsafe-baseline.json";
symlink($sentinel_path, $unsafe_baseline_path) or die 'could not create the baseline symlink fixture';
my $unsafe_baseline_collector = Orm::Broker::PodmanMetricsCollector->new(
    account_root => $account_root, snapshot_path => $snapshot_path, baseline_path => $unsafe_baseline_path,
    resolver => $resolver, expected_owner_uid => $uid, expected_owner_gid => $gid,
    read_names => sub { return ('ormtest') }, lookup_home => sub { return $home },
    probe => sub { return { %rate_values } }, clock => sub { return $rate_time + 3600 },
);
my $unsafe_baseline_snapshot = $unsafe_baseline_collector->collect();
is($unsafe_baseline_snapshot->{counter_window}->{reason}, 'state_unavailable', 'reject a symlinked continuity baseline');
is(do { local (@ARGV, $/) = ($sentinel_path); <> }, 'preserve', 'do not follow an unsafe baseline path');
my $unsafe_lock_path = "$state_dir/unsafe-lock.json.lock";
symlink($sentinel_path, $unsafe_lock_path) or die 'could not create the baseline lock symlink fixture';
my $unsafe_lock_collector = Orm::Broker::PodmanMetricsCollector->new(
    account_root => $account_root, snapshot_path => $snapshot_path, baseline_path => "$state_dir/unsafe-lock.json",
    resolver => $resolver, expected_owner_uid => $uid, expected_owner_gid => $gid,
    read_names => sub { return ('ormtest') }, lookup_home => sub { return $home },
    probe => sub { return { %rate_values } }, clock => sub { return $rate_time + 3600 },
);
my $unsafe_lock_snapshot = $unsafe_lock_collector->collect();
is($unsafe_lock_snapshot->{counter_window}->{reason}, 'state_unavailable', 'reject a symlinked continuity lock');
is(do { local (@ARGV, $/) = ($sentinel_path); <> }, 'preserve', 'leave a lock symlink target unchanged');

my $capped = Orm::Broker::PodmanMetricsCollector->new(
    account_root => $account_root, snapshot_path => $snapshot_path, resolver => $resolver,
    expected_owner_uid => $uid, expected_owner_gid => $gid,
    read_names => sub { return ('ormtest') }, lookup_home => sub { return $home },
    probe => sub { return { %values } }, clock => sub { return 1_800_000_000 }, max_probes => 0,
);
my $capped_snapshot = $capped->collect();
is($capped_snapshot->{discovered_count}, 1, 'retain discovery count when probe budget is exhausted');
is($capped_snapshot->{sampled_count}, 0, 'do not exceed the configured probe budget');
is($capped_snapshot->{skipped_count}, 1, 'record a budget-skipped container as unknown');
ok($capped_snapshot->{partial}, 'mark capped collection as partial');

make_path("$podman_root/ea-redis62.ormtest.02", "$podman_root/ea-redis62.ormtest.03");
chmod 0700, "$podman_root/ea-redis62.ormtest.02", "$podman_root/ea-redis62.ormtest.03";
my $account_capped = Orm::Broker::PodmanMetricsCollector->new(
    account_root => $account_root, snapshot_path => $snapshot_path, resolver => $resolver,
    expected_owner_uid => $uid, expected_owner_gid => $gid,
    read_names => sub { return ('ormtest') }, lookup_home => sub { return $home },
    probe => sub { return { %values } }, clock => sub { return 1_800_000_000 },
    max_containers_per_account => 1,
);
my $account_capped_snapshot = $account_capped->collect();
is($account_capped_snapshot->{discovered_count}, 3, 'retain all valid discovery counts beyond a per-account cap');
is($account_capped_snapshot->{sampled_count}, 1, 'sample no more than the per-account container cap');
is($account_capped_snapshot->{skipped_count}, 2, 'report per-account capped containers as skipped');
is($account_capped_snapshot->{backend_counts}->{redis}, 3, 'preserve backend counts for capped containers');

my $unsupported = Orm::Broker::PodmanMetricsCollector->new(
    account_root => $account_root, snapshot_path => $snapshot_path, resolver => $resolver,
    expected_owner_uid => $uid, expected_owner_gid => $gid,
    read_names => sub { return ('ormtest') }, lookup_home => sub { return $home },
    probe => sub { return { connected_clients => 1 } }, clock => sub { return 1_800_000_000 },
);
my $unsupported_snapshot = $unsupported->collect();
is($unsupported_snapshot->{unmeasured_count}, 3, 'treat missing counters as unmeasured for each sampled container');
ok($unsupported_snapshot->{partial}, 'unsupported or incomplete counters remain unknown');

local $ENV{ORM_TEST_UNVERIFIED} = 1;
my $unverified = $collector->collect();
is($unverified->{unverified_account_count}, 1, 'count an unresolved account as unverified');
ok($unverified->{partial}, 'unresolved account makes the result partial');

done_testing();
