use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use IO::Socket::UNIX;
use Socket qw(SOCK_STREAM);
use POSIX ();
use lib 'src';
use Orm::Broker::PodmanMetricsCollector;

plan skip_all => 'root-socket fixtures require Linux and a non-root test account'
    if $^O ne 'linux' || $> == 0;

my $uid = $<;
my $gid = $(;
$gid =~ s/ .*//;
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
ok(!exists($readback->{username}) && !exists($readback->{container}) && !exists($readback->{socket_path}),
    'snapshot contains no account or container identifiers');
ok(!defined(Orm::Broker::PodmanMetricsCollector->read_snapshot(
    $snapshot_path, expected_owner_uid => $uid, now => 1_800_002_000,
)), 'reject an expired metrics snapshot');

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
