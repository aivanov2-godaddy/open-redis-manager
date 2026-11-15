package Orm::Broker::FleetInventory;
use strict;
use warnings;
use Fcntl qw(:mode);
use JSON::PP ();

# Status checks use systemctl with a five-second timeout; four checks stay below the 35-second WHM client timeout.
my $PAGE_SIZE = 4;
my $MAX_METADATA_ENTRIES = 10_000;

sub new {
    my ($class, %args) = @_;
    return bless {
        instance_root => $args{instance_root} // '/etc/orm-instances',
        expected_owner_uid => defined($args{expected_owner_uid}) ? $args{expected_owner_uid} : 0,
        resolver => $args{resolver},
        instance_manager => $args{instance_manager},
        lookup_name => $args{lookup_name} // sub {
            my @entry = getpwnam($_[0]);
            return undef if !@entry || !defined($entry[2]);
            return { uid => 0 + $entry[2] };
        },
        read_names => $args{read_names},
    }, $class;
}

sub page {
    my ($self, $offset) = @_;
    return _failure('invalid_request') if !defined($offset) || ref($offset)
        || $offset !~ /\A(?:0|[1-9][0-9]{0,5})\z/;
    return _failure('operation_failed') if !eval { $self->{resolver}->can('resolve_account') }
        || !eval { $self->{instance_manager}->can('status') };

    my @root_stat = lstat($self->{instance_root});
    return _failure('operation_failed') if !@root_stat || !S_ISDIR($root_stat[2])
        || $root_stat[4] != $self->{expected_owner_uid} || ($root_stat[2] & 0022) != 0;

    my @names;
    if (ref($self->{read_names}) eq 'CODE') {
        @names = eval { $self->{read_names}->($self->{instance_root}) };
        return _failure('operation_failed') if $@;
    } else {
        opendir(my $directory, $self->{instance_root}) or return _failure('operation_failed');
        while (my $name = readdir($directory)) {
            next if $name eq '.' || $name eq '..';
            push @names, $name;
            if (@names > $MAX_METADATA_ENTRIES) {
                closedir($directory);
                return _failure('operation_failed');
            }
        }
        closedir($directory) or return _failure('operation_failed');
    }
    return _failure('operation_failed') if @names > $MAX_METADATA_ENTRIES;

    my @accounts;
    for my $name (@names) {
        next if !defined($name) || ref($name) || $name !~ /\A[a-zA-Z0-9_-]{1,16}\z/;
        my @directory_stat = lstat("$self->{instance_root}/$name");
        next if !@directory_stat || !S_ISDIR($directory_stat[2])
            || $directory_stat[4] != $self->{expected_owner_uid} || ($directory_stat[2] & 0027) != 0;

        my $identity = eval { $self->{lookup_name}->($name) };
        next if ref($identity) ne 'HASH' || !defined($identity->{uid})
            || ref($identity->{uid}) || $identity->{uid} !~ /\A[1-9][0-9]*\z/;
        my $account = eval { $self->{resolver}->resolve_account($identity->{uid}) };
        next if ref($account) ne 'HASH' || $account->{name} ne $name || $account->{uid} != $identity->{uid};

        push @accounts, { account => $account, username => $name };
    }

    @accounts = sort { $a->{username} cmp $b->{username} } @accounts;
    my $total = scalar @accounts;
    return _failure('invalid_request') if $offset > $total;
    my $end = $offset + $PAGE_SIZE;
    $end = $total if $end > $total;
    my @page;
    if ($offset < $end) {
        for my $candidate (@accounts[$offset .. $end - 1]) {
            my $status = eval { $self->{instance_manager}->status($candidate->{account}) };
            my $state = ref($status) eq 'HASH' && $status->{success}
                ? $status->{state} : 'unhealthy';
            $state = 'unhealthy' if !defined($state)
                || $state !~ /\A(?:stopped|starting|running|stopping|failed)\z/;
            push @page, { username => $candidate->{username}, state => $state };
        }
    }
    return {
        entries => \@page,
        offset => 0 + $offset,
        success => JSON::PP::true,
        total => $total,
        version => 1,
    };
}

sub _failure {
    return { error => $_[0], success => JSON::PP::false, version => 1 };
}

1;
