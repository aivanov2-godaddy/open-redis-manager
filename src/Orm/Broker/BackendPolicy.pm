package Orm::Broker::BackendPolicy;
use strict;
use warnings;
use Fcntl qw(O_RDONLY O_NOFOLLOW :mode);
use JSON::PP ();

sub new {
    my ($class, %args) = @_;
    return bless {
        path => $args{path} // '/etc/orm-backend-policy.json',
        expected_owner_uid => defined($args{expected_owner_uid}) ? $args{expected_owner_uid} : 0,
    }, $class;
}

sub selected_backend {
    my ($self) = @_;
    my $path = $self->{path};
    my $directory = $path;
    $directory =~ s{/[^/]+\z}{};
    my @directory_stat = lstat($directory);
    return undef if !@directory_stat || !S_ISDIR($directory_stat[2])
        || $directory_stat[4] != $self->{expected_owner_uid}
        || ($directory_stat[2] & 0022) != 0;

    return undef if !sysopen(my $handle, $path, O_RDONLY | O_NOFOLLOW);
    my @file_stat = stat($handle);
    if (!@file_stat || !S_ISREG($file_stat[2])
        || $file_stat[4] != $self->{expected_owner_uid}
        || $file_stat[3] != 1 || ($file_stat[2] & 0022) != 0
        || $file_stat[7] > 4096) {
        close($handle);
        return undef;
    }

    my $content = '';
    my $read = read($handle, $content, 4097);
    my $closed = close($handle);
    return undef if !defined($read) || !$closed || length($content) > 4096;

    my $policy = eval { JSON::PP->new->decode($content) };
    return undef if ref($policy) ne 'HASH';
    my @keys = sort keys %{$policy};
    return undef if join(',', @keys) ne 'backend,version';
    return undef if ($policy->{version} // 0) != 1;
    return undef if !defined($policy->{backend}) || $policy->{backend} !~ /\A(?:redis|valkey)\z/;
    return $policy->{backend};
}

1;
