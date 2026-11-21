package Orm::Broker::InstanceManifest;
use strict;
use warnings;
use Exporter qw(import);
use File::Spec::Unix;

our @EXPORT_OK = qw(validate_instance_manifest);

my %PRESETS = map { $_ => 1 } qw(generic wordpress laravel magento session);

sub validate_instance_manifest {
    my ($manifest, $username, $uid, $gid, $etc_root, $data_root) = @_;
    return 0 if ref($manifest) ne 'HASH'
        || !defined($username) || $username !~ /\A[a-zA-Z0-9_-]{1,16}\z/
        || !_is_integer($uid) || !_is_integer($gid);

    $etc_root //= '/etc/orm-instances';
    $data_root //= '/var/lib/orm-instances';
    my $config_dir = File::Spec::Unix->catdir($etc_root, $username);
    my $data_dir = File::Spec::Unix->catdir($data_root, $username);
    my $version = $manifest->{version};
    return 0 if !_is_integer($version);

    my @keys = sort keys %{$manifest};
    if ($version == 1) {
        return 0 if join(',', @keys) ne 'backend,config,data,gid,socket,uid,version';
    } elsif ($version == 2) {
        return 0 if join(',', @keys) ne 'backend,config,data,gid,preset,socket,uid,version'
            || !_valid_preset($manifest->{preset});
    } elsif ($version == 3) {
        return 0 if join(',', @keys) ne 'backend,config,data,gid,preset,provisioned_defaults,socket,uid,version'
            || !_valid_preset($manifest->{preset})
            || !_valid_provisioned_defaults($manifest->{provisioned_defaults});
    } else {
        return 0;
    }

    return 0 if !_is_integer($manifest->{uid}) || $manifest->{uid} != $uid
        || !_is_integer($manifest->{gid}) || $manifest->{gid} != $gid
        || !defined($manifest->{backend}) || ref($manifest->{backend})
        || $manifest->{backend} !~ /\A(?:redis|valkey)\z/
        || !defined($manifest->{config}) || ref($manifest->{config})
        || $manifest->{config} ne File::Spec::Unix->catfile($config_dir, 'redis.conf')
        || !defined($manifest->{data}) || ref($manifest->{data}) || $manifest->{data} ne $data_dir
        || !defined($manifest->{socket}) || ref($manifest->{socket})
        || $manifest->{socket} ne File::Spec::Unix->catfile($data_dir, 'redis.sock');

    return 1;
}

sub _valid_preset {
    my ($preset) = @_;
    return defined($preset) && !ref($preset) && exists($PRESETS{$preset});
}

sub _valid_provisioned_defaults {
    my ($defaults) = @_;
    return 0 if ref($defaults) ne 'HASH'
        || join(',', sort keys %{$defaults}) ne 'backup_retention,databases,metrics_history_retention_days'
        || !_is_integer($defaults->{backup_retention}) || $defaults->{backup_retention} < 2 || $defaults->{backup_retention} > 3
        || !_is_integer($defaults->{databases}) || $defaults->{databases} < 1 || $defaults->{databases} > 16
        || !_is_integer($defaults->{metrics_history_retention_days})
        || $defaults->{metrics_history_retention_days} < 7 || $defaults->{metrics_history_retention_days} > 90;
    return 1;
}

sub _is_integer {
    my ($value) = @_;
    return defined($value) && !ref($value) && $value =~ /\A(?:0|[1-9][0-9]*)\z/;
}

1;
