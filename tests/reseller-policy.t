use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use JSON::PP ();
use lib 'src';
use Orm::Broker::Handler;
use Orm::Broker::InstanceManager;
use Orm::Broker::ProviderPolicy;

plan skip_all => 'reseller quota filesystem security tests require Linux mode semantics' if $^O ne 'linux';

{
    package Local::ResellerTestResolver;
    sub resolve_name {
        my ($self, $name) = @_;
        return undef if !exists($self->{owners}->{$name});
        return {
            name => $name,
            uid => $self->{uid},
            gid => $self->{gid},
            plan => 'starter',
            owner => $self->{owners}->{$name},
        };
    }
    sub resolve_account {
        my ($self, $uid) = @_;
        return undef if !defined($uid) || $uid != $self->{uid};
        return $self->resolve_name('acct-one');
    }
}

my $tmp = tempdir(CLEANUP => 1);
my $etc_root = "$tmp/etc/orm-instances";
my $data_root = "$tmp/var/lib/orm-instances";
my $runtime_root = "$tmp/run/orm";
my $policy_root = "$tmp/etc/policy";
make_path($etc_root, $data_root, $runtime_root, $policy_root);
chmod(0750, $etc_root) or die "chmod instance config root: $!";
chmod(0700, $data_root) or die "chmod instance data root: $!";
chmod(0755, $runtime_root) or die "chmod runtime root: $!";
chmod(0755, $policy_root) or die "chmod policy root: $!";

my @groups = split /\s+/, $);
my $gid = 0 + ($groups[0] // $<);
my %owners = (
    'acct-one' => 'reseller1',
    'acct-two' => 'reseller1',
    'acct-three' => 'reseller2',
);
my $resolver = bless { uid => 0 + $<, gid => $gid, owners => \%owners }, 'Local::ResellerTestResolver';
my $policy_path = "$policy_root/provider-policy.json";
my $provider_policy = Orm::Broker::ProviderPolicy->new(path => $policy_path, expected_owner_uid => $<);
my $policy = {
    version => 2,
    mode => 'enforce',
    exposure => 'advanced',
    default => { enabled => JSON::PP::true, max_memory_mib => 64, backup_retention => 3 },
    packages => {},
    resellers => {
        reseller1 => { max_instances => 2, max_memory_mib => 64 },
    },
};
open(my $policy_file, '>', $policy_path) or die "create policy fixture: $!";
print {$policy_file} JSON::PP->new->canonical(1)->encode($policy) . "\n";
close($policy_file) or die "close policy fixture: $!";
chmod(0600, $policy_path) or die "chmod policy fixture: $!";

my %states = ('acct-one' => 'active', 'acct-two' => 'inactive', 'acct-three' => 'failed');
my $manager = Orm::Broker::InstanceManager->new(
    etc_root => $etc_root,
    data_root => $data_root,
    quota_lock_path => "$runtime_root/reseller-quota.lock",
    resolver => $resolver,
    provider_policy => $provider_policy,
    expected_owner_uid => $<,
    binary_paths => { redis => ['/usr/bin/redis-server'], valkey => ['/usr/bin/valkey-server'] },
    binary_probe => sub { return $_[0] eq 'redis' && $_[1] eq '/usr/bin/redis-server'; },
    policy => bless({}, 'Local::ResellerTestBackendPolicy'),
    systemctl_call => sub {
        my (@args) = @_;
        my $unit = $args[-1] // '';
        my ($name) = $unit =~ /\Aorm-instance\@([a-zA-Z0-9_-]{1,16})[.]service\z/;
        if ($args[0] eq 'is-active') {
            my $state = $states{$name // ''} // 'inactive';
            return ($state eq 'active', $state);
        }
        if ($args[0] eq 'start') {
            $states{$name} = 'active';
            return (1, '');
        }
        if ($args[0] eq 'stop') {
            $states{$name} = 'inactive';
            return (1, '');
        }
        return (1, '');
    },
);

sub Local::ResellerTestBackendPolicy::selected_backend { return 'redis'; }

my %instances = (
    'acct-one' => { memory_mib => 16, owner => 'reseller1' },
    'acct-two' => { memory_mib => 32, owner => 'reseller1' },
    'acct-three' => { memory_mib => 8, owner => 'reseller2' },
);
for my $name (sort keys %instances) {
    my $account = $resolver->resolve_name($name);
    my $config_dir = "$etc_root/$name";
    my $data_dir = "$data_root/$name";
    make_path($config_dir, $data_dir);
    chmod(0750, $config_dir) or die "chmod account config directory: $!";
    chown($<, $gid, $config_dir) or die "chown account config directory: $!";
    chmod(0700, $data_dir) or die "chmod account data directory: $!";
    chown($<, $gid, $data_dir) or die "chown account data directory: $!";
    my $socket = "$data_dir/redis.sock";
    my $settings = {
        memory_mib => $instances{$name}->{memory_mib},
        maxmemory_policy => 'allkeys-lru',
        maxclients => 100,
        timeout => 0,
    };
    my $config_path = "$config_dir/redis.conf";
    open(my $config, '>', $config_path) or die "create Redis config fixture: $!";
    print {$config} Orm::Broker::InstanceManager::_redis_config($data_dir, $socket, $settings);
    close($config) or die "close Redis config fixture: $!";
    chmod(0640, $config_path) or die "chmod Redis config fixture: $!";
    chown($<, $gid, $config_path) or die "chown Redis config fixture: $!";
    my $manifest = {
        backend => 'redis', config => $config_path, data => $data_dir,
        gid => $gid, preset => 'generic', socket => $socket, uid => 0 + $<, version => 2,
    };
    open(my $metadata, '>', "$config_dir/manifest.json") or die "create manifest fixture: $!";
    print {$metadata} JSON::PP->new->canonical(1)->encode($manifest) . "\n";
    close($metadata) or die "close manifest fixture: $!";
    chmod(0640, "$config_dir/manifest.json") or die "chmod manifest fixture: $!";
    chown($<, $gid, "$config_dir/manifest.json") or die "chown manifest fixture: $!";
}

my $usage = $manager->reseller_usage('reseller1', 0);
is_deeply($usage, { reseller1 => { instances => 2, active_instances => 0, memory_mib => 48 } },
    'count configured instances and aggregate memory, including a stopped instance');
my $summary = $manager->reseller_summary();
ok($summary->{success} && @{$summary->{resellers}} == 2, 'summarize managed usage for each reseller in WHM');
is_deeply($summary->{resellers}->[0], {
    owner => 'reseller1', account_count => 2, active_instances => 1, memory_mib => 48,
    max_instances => 2, max_memory_mib => 64,
}, 'return only bounded reseller totals and configured quotas');
my $quota_denial = $manager->dispatch('instance.provision', {
    name => 'acct-new', uid => 0 + $<, gid => $gid, owner => 'reseller1', plan => 'starter',
});
is($quota_denial->{error}, 'provider_policy_denied', 'enforce reseller quotas on a new provision only');
ok(!-e "$etc_root/acct-new" && !-e "$data_root/acct-new", 'do not create files when a quota denies provisioning');
my @lock_stat = stat("$runtime_root/reseller-quota.lock");
ok(@lock_stat && $lock_stat[4] == $< && ($lock_stat[2] & 0777) == 0600,
    'serialize quota checks with a private owner-controlled lock file');

my $exposure_frame = '{"operation":"provider.exposure","version":1}' . "\n";
my $exposure = JSON::PP->new->decode(Orm::Broker::Handler->handle_frame(
    $exposure_frame, 0 + $<, $resolver, $manager,
));
is($exposure->{exposure}, 'advanced', 'return only a validated exposure tier to an authenticated cPanel account');
my $reseller_frame = '{"operation":"provider.resellers","version":1}' . "\n";
my $root_summary = JSON::PP->new->decode(Orm::Broker::Handler->handle_frame(
    $reseller_frame, 0, $resolver, $manager,
));
ok($root_summary->{success} && $root_summary->{resellers}->[0]->{owner} eq 'reseller1',
    'allow only the root peer to retrieve the reseller summary');

done_testing();
