package Orm::Broker::FleetInventory;
use strict;
use warnings;
use Fcntl qw(:mode);
use JSON::PP ();
use Sys::Syslog qw(:standard :macros);

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
        audit => $args{audit},
    }, $class;
}

sub control {
    my ($self, $username, $action) = @_;
    return _failure('invalid_request') if !defined($username) || ref($username)
        || $username !~ /\A[a-zA-Z0-9_-]{1,16}\z/ || !defined($action) || ref($action)
        || $action !~ /\A(?:start|stop|restart)\z/;

    my $account = eval { $self->{resolver}->resolve_name($username) };
    if (ref($account) ne 'HASH' || $account->{name} ne $username) {
        my $audited = _audit_control($self, $username, $action, 'account_unavailable');
        return _failure('account_unavailable', $audited);
    }
    my $status = eval { $self->{instance_manager}->status($account) };
    if (ref($status) ne 'HASH' || !$status->{success}) {
        my $audited = _audit_control($self, $username, $action, 'instance_unavailable', 'unavailable');
        return _failure('instance_unavailable', $audited);
    }
    if ($status->{state} eq 'not_configured') {
        my $audited = _audit_control($self, $username, $action, 'not_configured', $status->{state});
        return _failure('not_configured', $audited);
    }
    if ($action eq 'restart' && $status->{state} ne 'running' && $status->{state} ne 'starting') {
        my $audited = _audit_control($self, $username, $action, 'instance_unavailable', $status->{state});
        return _failure('instance_unavailable', $audited);
    }

    my $result = eval { $self->{instance_manager}->$action($account) };
    if (ref($result) ne 'HASH' || !$result->{success}
        || !defined($result->{state}) || $result->{state} !~ /\A(?:stopped|starting|running|stopping|failed)\z/) {
        my $error = ref($result) eq 'HASH' && defined($result->{error})
            && $result->{error} =~ /\A(?:service_failed|instance_unavailable|not_configured)\z/
            ? $result->{error} : 'service_failed';
        my $audited = _audit_control($self, $username, $action, $error, 'unavailable');
        return _failure($error, $audited);
    }
    my $audited = _audit_control($self, $username, $action, 'success', $result->{state});
    return {
        action => $action,
        audit_logged => $audited ? JSON::PP::true : JSON::PP::false,
        state => $result->{state},
        success => JSON::PP::true,
        username => $username,
        version => 1,
    };
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
    my ($error, $audited) = @_;
    my $response = { error => $error, success => JSON::PP::false, version => 1 };
    $response->{audit_logged} = $audited ? JSON::PP::true : JSON::PP::false if defined($audited);
    return $response;
}

sub _audit_control {
    my ($self, $username, $action, $outcome, $state) = @_;
    $state = 'unavailable' if !defined($state) || $state !~ /\A(?:stopped|starting|running|stopping|failed|unavailable)\z/;
    if (ref($self->{audit}) eq 'CODE') {
        my $recorded = eval { $self->{audit}->(0, $username, $action, $outcome, $state) };
        return $recorded ? 1 : 0;
    }
    my $recorded = eval {
        openlog('orm-broker', 'pid', 'authpriv');
        syslog(LOG_NOTICE, 'fleet_control actor_uid=0 account=%s action=%s result=%s state=%s', $username, $action, $outcome, $state)
            or die "syslog write failed";
        closelog();
        1;
    };
    eval { closelog(); };
    return $recorded ? 1 : 0;
}

sub audit_denial {
    my ($self, $peer_uid, $username, $action) = @_;
    $peer_uid = 'unknown' if !defined($peer_uid) || ref($peer_uid) || $peer_uid !~ /\A[0-9]{1,10}\z/;
    $username = 'invalid' if !defined($username) || ref($username) || $username !~ /\A[a-zA-Z0-9_-]{1,16}\z/;
    $action = 'invalid' if !defined($action) || ref($action) || $action !~ /\A(?:start|stop|restart)\z/;
    if (ref($self->{audit}) eq 'CODE') {
        my $recorded = eval { $self->{audit}->($peer_uid, $username, $action, 'not_authorized', 'unavailable') };
        return $recorded ? 1 : 0;
    }
    my $recorded = eval {
        openlog('orm-broker', 'pid', 'authpriv');
        syslog(LOG_NOTICE, 'fleet_control actor_uid=%s account=%s action=%s result=not_authorized state=unavailable',
            $peer_uid, $username, $action) or die "syslog write failed";
        closelog();
        1;
    };
    eval { closelog(); };
    return $recorded ? 1 : 0;
}

1;
