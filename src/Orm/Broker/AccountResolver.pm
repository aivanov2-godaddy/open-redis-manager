package Orm::Broker::AccountResolver;
use strict;
use warnings;
use Fcntl qw(O_RDONLY O_NOFOLLOW :mode);
use File::Spec;

my $MAX_ACCOUNT_FILE_BYTES = 1_048_576;

sub new {
    my ($class, %args) = @_;
    return bless {
        account_root => $args{account_root} // '/var/cpanel/users',
        expected_owner_uid => defined($args{expected_owner_uid}) ? $args{expected_owner_uid} : 0,
        lookup => $args{lookup} // sub {
            my @entry = getpwuid($_[0]);
            return undef if !@entry || !defined($entry[0]) || !defined($entry[2]);
            return { name => $entry[0], uid => $entry[2], gid => $entry[3] };
        },
    }, $class;
}

sub resolve_uid {
    my ($self, $uid) = @_;
    my $account = $self->resolve_account($uid);
    return defined($account) ? $account->{name} : undef;
}

sub resolve_account {
    my ($self, $uid) = @_;
    return undef if !defined($uid) || ref($uid) || $uid !~ /\A[0-9]+\z/ || $uid == 0;

    my $entry = eval { $self->{lookup}->($uid) };
    return undef if ref($entry) ne 'HASH';
    return undef if !defined($entry->{uid}) || $entry->{uid} != $uid;
    return undef if !defined($entry->{gid}) || $entry->{gid} !~ /\A[0-9]+\z/;
    my $username = $entry->{name};
    return undef if !defined($username) || $username !~ /\A[a-zA-Z0-9_-]{1,16}\z/;

    my @root_stat = lstat($self->{account_root});
    return undef if !@root_stat || !S_ISDIR($root_stat[2]);
    return undef if $root_stat[4] != $self->{expected_owner_uid};
    return undef if ($root_stat[2] & 0022) != 0;

    my $account_file = File::Spec->catfile($self->{account_root}, $username);
    my $flags = O_RDONLY | O_NOFOLLOW;
    return undef if !sysopen(my $handle, $account_file, $flags);

    my @file_stat = stat($handle);
    if (!@file_stat || !S_ISREG($file_stat[2])
        || $file_stat[4] != $self->{expected_owner_uid}
        || $file_stat[3] != 1
        || ($file_stat[2] & 0022) != 0
        || $file_stat[7] > $MAX_ACCOUNT_FILE_BYTES) {
        close($handle);
        return undef;
    }

    close($handle) or return undef;
    return { name => $username, uid => 0 + $uid, gid => 0 + $entry->{gid} };
}

1;
