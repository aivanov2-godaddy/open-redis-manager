use strict;
use warnings;
use Test::More;
use Orm::Broker::InstanceManifest qw(validate_instance_manifest);

my ($name, $uid, $gid) = ('ormfixture', 1001, 1002);
my %base = (
    backend => 'redis',
    config => "/etc/orm-instances/$name/redis.conf",
    data => "/var/lib/orm-instances/$name",
    gid => $gid,
    socket => "/var/lib/orm-instances/$name/redis.sock",
    uid => $uid,
);

my $v1 = { %base, version => 1 };
ok(validate_instance_manifest($v1, $name, $uid, $gid), 'accept the original version-one manifest');

my $v2 = { %base, preset => 'generic', version => 2 };
ok(validate_instance_manifest($v2, $name, $uid, $gid), 'accept version-two preset manifests');

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
ok(validate_instance_manifest($v3, $name, $uid, $gid), 'accept current version-three manifests');

my $invalid = { %{$v3}, extra => 'unexpected' };
ok(!validate_instance_manifest($invalid, $name, $uid, $gid), 'reject unexpected manifest fields');
$invalid = { %{$v3}, preset => 'unknown' };
ok(!validate_instance_manifest($invalid, $name, $uid, $gid), 'reject unknown setup presets');
$invalid = { %{$v3}, provisioned_defaults => { %{$v3->{provisioned_defaults}}, databases => 0 } };
ok(!validate_instance_manifest($invalid, $name, $uid, $gid), 'reject invalid provisioned defaults');
$invalid = { %{$v3}, backend => 'other' };
ok(!validate_instance_manifest($invalid, $name, $uid, $gid), 'reject unsupported backends');
$invalid = { %{$v3}, socket => '/tmp/redis.sock' };
ok(!validate_instance_manifest($invalid, $name, $uid, $gid), 'reject paths outside the account instance');
ok(!validate_instance_manifest($v3, 'invalid/name', $uid, $gid), 'reject unsafe account names');

done_testing();
