package Orm::Broker::ProviderPolicy;
use strict;
use warnings;
use Errno qw(ENOENT);
use Fcntl qw(O_RDONLY O_NOFOLLOW :mode);
use JSON::PP ();
use Sys::Syslog qw(:standard :macros);

my $MAX_POLICY_BYTES = 32768;
my $DEFAULT_POLICY = {
    version => 1,
    mode => 'report-only',
    default => { enabled => JSON::PP::true, max_memory_mib => 64, backup_retention => 3 },
    packages => {},
};

sub new {
    my ($class, %args) = @_;
    return bless {
        path => $args{path} // '/etc/orm-provider-policy.json',
        expected_owner_uid => defined($args{expected_owner_uid}) ? $args{expected_owner_uid} : 0,
        audit => $args{audit},
    }, $class;
}

sub effective_for {
    my ($self, $account) = @_;
    return undef if ref($account) ne 'HASH';
    my $policy = $self->_read_policy();
    return undef if !defined($policy);
    my $package = $account->{plan};
    $package = 'default' if !defined($package) || ref($package)
        || $package !~ /\A[a-zA-Z0-9_.-]{1,64}\z/;
    my $limits = $policy->{packages}->{$package} // $policy->{default};
    return {
        enabled => $limits->{enabled},
        max_memory_mib => 0 + $limits->{max_memory_mib},
        backup_retention => 0 + $limits->{backup_retention},
        mode => $policy->{mode},
    };
}

sub provision_decision {
    my ($self, $account, $memory_mib) = @_;
    return undef if !defined($memory_mib) || ref($memory_mib) || $memory_mib !~ /\A[0-9]+\z/;
    my $effective = $self->effective_for($account);
    return undef if ref($effective) ne 'HASH';
    my @violations;
    push @violations, 'package_disabled' if !$effective->{enabled};
    push @violations, 'memory_limit_exceeded' if $memory_mib > $effective->{max_memory_mib};
    return $self->_decision($effective, \@violations);
}

sub memory_decision {
    my ($self, $account, $memory_mib) = @_;
    return undef if !defined($memory_mib) || ref($memory_mib) || $memory_mib !~ /\A[0-9]+\z/;
    my $effective = $self->effective_for($account);
    return undef if ref($effective) ne 'HASH';
    my @violations;
    push @violations, 'memory_limit_exceeded' if $memory_mib > $effective->{max_memory_mib};
    return $self->_decision($effective, \@violations);
}

sub _decision {
    my ($self, $effective, $violations) = @_;
    if (@{$violations}) {
        my $message = 'ORM provider policy ' . $effective->{mode} . ' violation: ' . join(',', @{$violations});
        if (ref($self->{audit}) eq 'CODE') {
            eval { $self->{audit}->($message) };
        } else {
            syslog(LOG_NOTICE, '%s', $message);
        }
    }
    return {
        allowed => $effective->{mode} eq 'report-only' || !@{$violations} ? 1 : 0,
        mode => $effective->{mode},
        max_memory_mib => $effective->{max_memory_mib},
        backup_retention => $effective->{backup_retention},
        violations => [@{$violations}],
    };
}

sub _read_policy {
    my ($self) = @_;
    my $path = $self->{path};
    my $directory = $path;
    $directory =~ s{/[^/]+\z}{};
    my @directory_stat = lstat($directory);
    return undef if !@directory_stat || !S_ISDIR($directory_stat[2])
        || $directory_stat[4] != $self->{expected_owner_uid}
        || ($directory_stat[2] & 0022) != 0;

    my @path_stat = lstat($path);
    if (!@path_stat) {
        return { %{$DEFAULT_POLICY}, default => { %{$DEFAULT_POLICY->{default}} }, packages => {} }
            if $! == ENOENT;
        return undef;
    }
    return undef if !sysopen(my $handle, $path, O_RDONLY | O_NOFOLLOW);
    my @file_stat = stat($handle);
    if (!@file_stat || !S_ISREG($file_stat[2])
        || $file_stat[4] != $self->{expected_owner_uid} || $file_stat[3] != 1
        || ($file_stat[2] & 0777) != 0600 || $file_stat[7] > $MAX_POLICY_BYTES) {
        close($handle);
        return undef;
    }

    my $content = '';
    my $read = read($handle, $content, $MAX_POLICY_BYTES + 1);
    my $closed = close($handle);
    return undef if !defined($read) || !$closed || length($content) > $MAX_POLICY_BYTES;
    my $policy = eval { JSON::PP->new->decode($content) };
    return undef if !_valid_policy($policy);
    return $policy;
}

sub _valid_policy {
    my ($policy) = @_;
    return 0 if ref($policy) ne 'HASH' || join(',', sort keys %{$policy}) ne 'default,mode,packages,version'
        || !_is_integer($policy->{version}) || $policy->{version} != 1
        || !defined($policy->{mode}) || ref($policy->{mode})
        || $policy->{mode} !~ /\A(?:report-only|enforce)\z/
        || !_valid_limits($policy->{default}) || ref($policy->{packages}) ne 'HASH'
        || scalar(keys %{$policy->{packages}}) > 1000;
    for my $name (keys %{$policy->{packages}}) {
        return 0 if !defined($name) || $name !~ /\A[a-zA-Z0-9_.-]{1,64}\z/
            || $name eq 'default' || !_valid_limits($policy->{packages}->{$name});
    }
    return 1;
}

sub _valid_limits {
    my ($limits) = @_;
    return 0 if ref($limits) ne 'HASH'
        || join(',', sort keys %{$limits}) ne 'backup_retention,enabled,max_memory_mib'
        || !JSON::PP::is_bool($limits->{enabled})
        || !_is_integer($limits->{max_memory_mib}) || $limits->{max_memory_mib} < 8 || $limits->{max_memory_mib} > 64
        || !_is_integer($limits->{backup_retention}) || $limits->{backup_retention} < 2 || $limits->{backup_retention} > 3;
    return 1;
}

sub _is_integer {
    my ($value) = @_;
    return defined($value) && !ref($value) && $value =~ /\A(?:0|[1-9][0-9]*)\z/;
}

1;
