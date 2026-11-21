use strict;
use warnings;
use Test::More;
use File::Spec;
use Orm::Broker::InstanceManager ();

my ($name, $uid, $gid) = ('ormfixture', 1001, 1002);
my ($etc_root, $data_root) = ('test-etc', 'test-data');
my $config_dir = File::Spec->catdir($etc_root, $name);
my $data_dir = File::Spec->catdir($data_root, $name);
my %base = (
    backend => 'redis',
    config => File::Spec->catfile($config_dir, 'redis.conf'),
    data => $data_dir,
    gid => $gid,
    socket => File::Spec->catfile($data_dir, 'redis.sock'),
    uid => $uid,
);

my $validate = sub {
    return Orm::Broker::InstanceManager::validate_instance_manifest(
        $_[0], $name, $uid, $gid, $etc_root, $data_root,
    );
};

my $v1 = { %base, version => 1 };
ok($validate->($v1), 'accept the original version-one manifest');

my $v2 = { %base, preset => 'generic', version => 2 };
ok($validate->($v2), 'accept version-two preset manifests');

my $v3 = {
    %base,
    preset => 'generic',
    provisioned_defaults => {
        backup_retention => 3,
        databases => 16,
        metrics_history_retention_days => 30,
    },
    version => 3,
};
ok($validate->($v3), 'accept current version-three manifests');

my $invalid = { %{$v3}, extra => 'unexpected' };
ok(!$validate->($invalid), 'reject unexpected manifest fields');
$invalid = { %{$v3}, preset => 'unknown' };
ok(!$validate->($invalid), 'reject unknown setup presets');
$invalid = { %{$v3}, provisioned_defaults => { %{$v3->{provisioned_defaults}}, databases => 0 } };
ok(!$validate->($invalid), 'reject invalid provisioned defaults');
$invalid = { %{$v3}, backend => 'other' };
ok(!$validate->($invalid), 'reject unsupported backends');
$invalid = { %{$v3}, socket => File::Spec->catfile('tmp', 'redis.sock') };
ok(!$validate->($invalid), 'reject paths outside the account instance');
ok(!Orm::Broker::InstanceManager::validate_instance_manifest($v3, 'invalid/name', $uid, $gid, $etc_root, $data_root),
    'reject unsafe account names');

done_testing();
