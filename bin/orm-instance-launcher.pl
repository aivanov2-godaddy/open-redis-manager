#!/usr/bin/perl
use strict;
use warnings;
use Fcntl qw(O_RDONLY O_NOFOLLOW :mode);
use JSON::PP ();

my $username = shift @ARGV;
die "invalid ORM instance\n" if @ARGV || !defined($username)
    || $username !~ /\A[a-zA-Z0-9_-]{1,16}\z/;

my @account = getpwnam($username);
die "invalid ORM instance\n" if !@account || $account[2] != $>
    || $) !~ /\A\Q$account[3]\E(?:\s|\z)/;
my $uid = 0 + $account[2];
my $gid = 0 + $account[3];
my $config_dir = "/etc/orm-instances/$username";
my $manifest_path = "$config_dir/manifest.json";
my $config_path = "$config_dir/redis.conf";
my $data_path = "/var/lib/orm-instances/$username";

_traversable_directory('/etc/orm-instances');
_traversable_directory('/var/lib/orm-instances');
_trusted_account_directory($config_dir, $gid);
my $manifest = _read_manifest($manifest_path, $gid);
die "invalid ORM instance\n" if ref($manifest) ne 'HASH';
my @keys = sort keys %{$manifest};
die "invalid ORM instance\n" if join(',', @keys) ne 'backend,config,data,gid,socket,uid,version';
die "invalid ORM instance\n" if ($manifest->{version} // 0) != 1
    || ($manifest->{uid} // -1) != $uid || ($manifest->{gid} // -1) != $gid
    || $manifest->{config} ne $config_path || $manifest->{data} ne $data_path
    || $manifest->{socket} ne "$data_path/redis.sock";

_trusted_config($config_path, $gid);
_trusted_data_directory($data_path, $uid, $gid);

my %binaries = (
    redis => [qw(/usr/bin/redis-server /usr/sbin/redis-server /usr/local/bin/redis-server /usr/local/sbin/redis-server)],
    valkey => [qw(/usr/bin/valkey-server /usr/sbin/valkey-server /usr/local/bin/valkey-server /usr/local/sbin/valkey-server)],
);
die "invalid ORM instance\n" if !defined($manifest->{backend}) || !exists($binaries{$manifest->{backend}});
my $binary;
for my $candidate (@{$binaries{$manifest->{backend}}}) {
    my @stat = lstat($candidate);
    next if !@stat || !S_ISREG($stat[2]) || $stat[4] != 0 || ($stat[2] & 0022) != 0 || !-x $candidate;
    $binary = $candidate;
    last;
}
die "backend unavailable\n" if !defined($binary);

exec {$binary} $binary, $config_path;
die "backend unavailable\n";

sub _traversable_directory {
    my ($path) = @_;
    my @stat = lstat($path);
    die "invalid ORM instance\n" if !@stat || !S_ISDIR($stat[2]) || $stat[4] != 0
        || ($stat[2] & 0022) != 0 || ($stat[2] & 0111) != 0111;
}

sub _trusted_account_directory {
    my ($path, $gid) = @_;
    my @stat = lstat($path);
    die "invalid ORM instance\n" if !@stat || !S_ISDIR($stat[2]) || $stat[4] != 0
        || $stat[5] != $gid || ($stat[2] & 0027) != 0;
}

sub _read_manifest {
    my ($path, $gid) = @_;
    return undef if !sysopen(my $handle, $path, O_RDONLY | O_NOFOLLOW);
    my @stat = stat($handle);
    if (!@stat || !S_ISREG($stat[2]) || $stat[4] != 0 || $stat[5] != $gid
        || $stat[3] != 1 || ($stat[2] & 0037) != 0 || $stat[7] > 4096) {
        close($handle);
        return undef;
    }
    my $json = '';
    my $read = read($handle, $json, 4097);
    my $closed = close($handle);
    return undef if !defined($read) || !$closed || length($json) > 4096;
    return eval { JSON::PP->new->decode($json) };
}

sub _trusted_config {
    my ($path, $gid) = @_;
    my $manifest = _read_manifest("$config_dir/manifest.json", $gid);
    die "invalid ORM instance\n" if !$manifest;
    my @stat = lstat($path);
    die "invalid ORM instance\n" if !@stat || !S_ISREG($stat[2]) || $stat[4] != 0
        || $stat[5] != $gid || $stat[3] != 1 || ($stat[2] & 0037) != 0 || $stat[7] > 16384;
}

sub _trusted_data_directory {
    my ($path, $uid, $gid) = @_;
    my @stat = lstat($path);
    die "invalid ORM instance\n" if !@stat || !S_ISDIR($stat[2]) || $stat[4] != $uid
        || $stat[5] != $gid || ($stat[2] & 0077) != 0;
}
