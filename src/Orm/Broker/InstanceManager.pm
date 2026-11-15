package Orm::Broker::InstanceManager;
use strict;
use warnings;
use Fcntl qw(O_RDONLY O_WRONLY O_CREAT O_EXCL O_NOFOLLOW :mode);
use File::Spec;
use JSON::PP ();
use Orm::Broker::BackendPolicy;

my %SERVER_BINARIES = (
    redis => [qw(/usr/bin/redis-server /usr/sbin/redis-server /usr/local/bin/redis-server /usr/local/sbin/redis-server)],
    valkey => [qw(/usr/bin/valkey-server /usr/sbin/valkey-server /usr/local/bin/valkey-server /usr/local/sbin/valkey-server)],
);
my $MAX_MEMORY_BYTES = 64 * 1024 * 1024;

sub new {
    my ($class, %args) = @_;
    return bless {
        etc_root => $args{etc_root} // '/etc/orm-instances',
        data_root => $args{data_root} // '/var/lib/orm-instances',
        policy => $args{policy} // Orm::Broker::BackendPolicy->new(),
        expected_owner_uid => defined($args{expected_owner_uid}) ? $args{expected_owner_uid} : 0,
        systemctl => $args{systemctl} // '/usr/bin/systemctl',
        systemctl_call => $args{systemctl_call},
        binary_paths => $args{binary_paths} // \%SERVER_BINARIES,
        binary_probe => $args{binary_probe},
    }, $class;
}

sub dispatch {
    my ($self, $operation, $account) = @_;
    return _failure('not_authorized') if ref($account) ne 'HASH';
    return _failure('invalid_request') if !_valid_account($account);

    return $self->status($account) if $operation eq 'instance.status';
    return $self->provision($account) if $operation eq 'instance.provision';
    return $self->start($account) if $operation eq 'instance.start';
    return $self->stop($account) if $operation eq 'instance.stop';
    return _failure('invalid_request');
}

sub status {
    my ($self, $account) = @_;
    my $manifest = $self->_read_manifest($account);
    if (!-e $self->_manifest_path($account->{name}) && !-l $self->_manifest_path($account->{name})) {
        return _state('not_configured') if !-e $self->_account_config_dir($account->{name})
            && !-l $self->_account_config_dir($account->{name})
            && !-e $self->_account_data_dir($account->{name})
            && !-l $self->_account_data_dir($account->{name});
        return _failure('instance_unavailable');
    }
    return _failure('instance_unavailable') if !$manifest;
    my ($ok, $state) = $self->_systemctl('is-active', $self->_unit_name($account->{name}));
    return _failure('instance_unavailable') if !$ok && $state ne 'inactive' && $state ne 'failed';
    return _state('running') if $state eq 'active';
    return _state('starting') if $state eq 'activating' || $state eq 'reloading';
    return _state('stopping') if $state eq 'deactivating';
    return _state('failed') if $state eq 'failed';
    return _state('stopped') if $state eq 'inactive';
    return _failure('instance_unavailable');
}

sub provision {
    my ($self, $account) = @_;
    return _failure('instance_exists') if -e $self->_manifest_path($account->{name})
        || -l $self->_manifest_path($account->{name})
        || -e $self->_account_config_dir($account->{name})
        || -l $self->_account_config_dir($account->{name})
        || -e $self->_account_data_dir($account->{name})
        || -l $self->_account_data_dir($account->{name});
    return _failure('storage_unavailable') if !$self->_trusted_directory($self->{etc_root})
        || !$self->_trusted_directory($self->{data_root});

    my $backend = $self->{policy}->selected_backend();
    return _failure('backend_policy_required') if !defined($backend);
    my $binary = $self->_available_binary($backend);
    return _failure('backend_unavailable') if !defined($binary);

    my $config_dir = $self->_account_config_dir($account->{name});
    my $data_dir = $self->_account_data_dir($account->{name});
    my $made_config_dir = mkdir($config_dir, 0750);
    return _failure('storage_unavailable') if !$made_config_dir;
    chmod(0750, $config_dir) or return $self->_rollback_provision($account, $config_dir, $data_dir, 0, 'storage_unavailable');
    chown($self->{expected_owner_uid}, $account->{gid}, $config_dir)
        or return $self->_rollback_provision($account, $config_dir, $data_dir, 0, 'storage_unavailable');

    my $made_data_dir = mkdir($data_dir, 0700);
    return $self->_rollback_provision($account, $config_dir, $data_dir, 0, 'storage_unavailable')
        if !$made_data_dir;
    chmod(0700, $data_dir) or return $self->_rollback_provision($account, $config_dir, $data_dir, 1, 'storage_unavailable');
    chown($account->{uid}, $account->{gid}, $data_dir)
        or return $self->_rollback_provision($account, $config_dir, $data_dir, 1, 'storage_unavailable');

    my $socket = File::Spec->catfile($data_dir, 'redis.sock');
    my $manifest = {
        backend => $backend,
        config => File::Spec->catfile($config_dir, 'redis.conf'),
        data => $data_dir,
        gid => 0 + $account->{gid},
        socket => $socket,
        uid => 0 + $account->{uid},
        version => 1,
    };
    my $manifest_json = JSON::PP->new->canonical(1)->encode($manifest) . "\n";
    my $config = _redis_config($data_dir, $socket);
    if (!$self->_atomic_write(File::Spec->catfile($config_dir, 'redis.conf'), $config, 0640, $self->{expected_owner_uid}, $account->{gid})) {
        return $self->_rollback_provision($account, $config_dir, $data_dir, 1, 'storage_unavailable');
    }
    if (!$self->_atomic_write($self->_manifest_path($account->{name}), $manifest_json, 0640, $self->{expected_owner_uid}, $account->{gid})) {
        return $self->_rollback_provision($account, $config_dir, $data_dir, 1, 'storage_unavailable');
    }

    my $unit = $self->_unit_name($account->{name});
    my ($enabled) = $self->_systemctl('enable', $unit);
    if (!$enabled) {
        return $self->_rollback_provision($account, $config_dir, $data_dir, 1, 'service_failed');
    }
    my ($started) = $self->_systemctl('start', '--no-block', $unit);
    if (!$started) {
        $self->_systemctl('disable', $unit);
        return $self->_rollback_provision($account, $config_dir, $data_dir, 1, 'service_failed');
    }

    my $current = $self->status($account);
    return $current if $current->{success} && ($current->{state} eq 'running' || $current->{state} eq 'starting');
    $self->_systemctl('stop', '--no-block', $unit);
    $self->_systemctl('disable', $unit);
    return $self->_rollback_provision($account, $config_dir, $data_dir, 1, 'service_failed');
}

sub start {
    my ($self, $account) = @_;
    my $manifest = $self->_read_manifest($account);
    return _failure('not_configured') if !$manifest;
    my ($ok) = $self->_systemctl('start', '--no-block', $self->_unit_name($account->{name}));
    return _failure('service_failed') if !$ok;
    my $current = $self->status($account);
    return $current if $current->{success} && ($current->{state} eq 'running' || $current->{state} eq 'starting');
    return _failure('service_failed');
}

sub stop {
    my ($self, $account) = @_;
    my $manifest = $self->_read_manifest($account);
    return _failure('not_configured') if !$manifest;
    my ($ok) = $self->_systemctl('stop', '--no-block', $self->_unit_name($account->{name}));
    return _failure('service_failed') if !$ok;
    my $current = $self->status($account);
    return $current if $current->{success} && ($current->{state} eq 'stopped' || $current->{state} eq 'stopping');
    return _failure('service_failed');
}

sub _read_manifest {
    my ($self, $account) = @_;
    return undef if !$self->_trusted_directory($self->{etc_root});
    my $directory = $self->_account_config_dir($account->{name});
    my @dir_stat = lstat($directory);
    return undef if !@dir_stat || !S_ISDIR($dir_stat[2])
        || $dir_stat[4] != $self->{expected_owner_uid}
        || $dir_stat[5] != $account->{gid} || ($dir_stat[2] & 0027) != 0;

    my $path = $self->_manifest_path($account->{name});
    return undef if !sysopen(my $handle, $path, O_RDONLY | O_NOFOLLOW);
    my @stat = stat($handle);
    if (!@stat || !S_ISREG($stat[2]) || $stat[4] != $self->{expected_owner_uid}
        || $stat[5] != $account->{gid} || $stat[3] != 1
        || ($stat[2] & 0037) != 0 || $stat[7] > 4096) {
        close($handle);
        return undef;
    }
    my $json = '';
    my $read = read($handle, $json, 4097);
    my $closed = close($handle);
    return undef if !defined($read) || !$closed || length($json) > 4096;
    my $manifest = eval { JSON::PP->new->decode($json) };
    return undef if ref($manifest) ne 'HASH';
    my @keys = sort keys %{$manifest};
    return undef if join(',', @keys) ne 'backend,config,data,gid,socket,uid,version';
    return undef if ($manifest->{version} // 0) != 1
        || ($manifest->{uid} // -1) != $account->{uid}
        || ($manifest->{gid} // -1) != $account->{gid};
    return undef if !defined($manifest->{backend}) || $manifest->{backend} !~ /\A(?:redis|valkey)\z/;
    my $expected_data = $self->_account_data_dir($account->{name});
    my $expected_config = File::Spec->catfile($self->_account_config_dir($account->{name}), 'redis.conf');
    my $expected_socket = File::Spec->catfile($expected_data, 'redis.sock');
    return undef if $manifest->{data} ne $expected_data
        || $manifest->{config} ne $expected_config || $manifest->{socket} ne $expected_socket;
    return undef if !defined($self->_available_binary($manifest->{backend}));
    return undef if !$self->_valid_config($account, $manifest);
    return $manifest;
}

sub _valid_config {
    my ($self, $account, $manifest) = @_;
    my $path = $manifest->{config};
    return 0 if !sysopen(my $handle, $path, O_RDONLY | O_NOFOLLOW);
    my @stat = stat($handle);
    if (!@stat || !S_ISREG($stat[2]) || $stat[4] != $self->{expected_owner_uid}
        || $stat[5] != $account->{gid} || $stat[3] != 1 || ($stat[2] & 0037) != 0
        || $stat[7] > 16384) {
        close($handle);
        return 0;
    }
    close($handle) or return 0;
    my @data_stat = lstat($manifest->{data});
    return 0 if !@data_stat || !S_ISDIR($data_stat[2])
        || $data_stat[4] != $account->{uid} || $data_stat[5] != $account->{gid}
        || ($data_stat[2] & 0077) != 0;
    return 1;
}

sub _available_binary {
    my ($self, $backend) = @_;
    return undef if !defined($backend) || !exists($self->{binary_paths}->{$backend});
    for my $path (@{$self->{binary_paths}->{$backend}}) {
        next if !defined($path) || $path !~ m{\A/usr/(?:local/)?(?:s?bin)/(?:redis|valkey)-server\z};
        my $available;
        if (ref($self->{binary_probe}) eq 'CODE') {
            $available = eval { $self->{binary_probe}->($backend, $path) };
        } else {
            my @stat = lstat($path);
            $available = @stat && S_ISREG($stat[2]) && $stat[4] == 0
                && ($stat[2] & 0022) == 0 && -x $path;
        }
        return $path if $available;
    }
    return undef;
}

sub _systemctl {
    my ($self, @args) = @_;
    return $self->{systemctl_call}->(@args) if ref($self->{systemctl_call}) eq 'CODE';
    return (0, 'unavailable') if $self->{systemctl} ne '/usr/bin/systemctl';
    return (0, 'unavailable') if grep { !defined($_) || ref($_) || $_ =~ /[\r\n\0]/ } @args;
    my ($output, $ok) = ('', 0);
    my $opened = eval {
        local $SIG{ALRM} = sub { die "command timeout\n" };
        alarm(5);
        if (open(my $pipe, '-|', $self->{systemctl}, '--no-pager', @args)) {
            my $read = read($pipe, $output, 129);
            $output = '' if !defined($read) || $read > 128;
            $ok = close($pipe) ? 1 : 0;
        }
        alarm(0);
        1;
    };
    alarm(0);
    return (0, 'unavailable') if !$opened;
    $output =~ s/[\r\n]+\z//;
    return ($ok, $output);
}

sub _atomic_write {
    my ($self, $path, $content, $mode, $uid, $gid) = @_;
    my $temporary = $path . '.tmp-' . $$ . '-' . int(rand(1_000_000));
    return 0 if !sysopen(my $handle, $temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    my $ok = print {$handle} $content;
    $ok = 0 if !$ok || !close($handle);
    if ($ok) {
        $ok = chmod($mode, $temporary) && chown($uid, $gid, $temporary);
    }
    if ($ok) {
        $ok = rename($temporary, $path);
    }
    unlink($temporary) if -e $temporary || -l $temporary;
    return $ok ? 1 : 0;
}

sub _rollback_provision {
    my ($self, $account, $config_dir, $data_dir, $remove_data, $error) = @_;
    unlink($self->_manifest_path($account->{name}));
    unlink(File::Spec->catfile($config_dir, 'redis.conf'));
    rmdir($config_dir);
    if ($remove_data) {
        my @entries = _read_dir($data_dir);
        rmdir($data_dir) if @entries == 0;
    }
    return _failure($error);
}

sub _read_dir {
    my ($path) = @_;
    opendir(my $dir, $path) or return ('.', '..');
    my @entries = grep { $_ ne '.' && $_ ne '..' } readdir($dir);
    closedir($dir);
    return @entries;
}

sub _trusted_directory {
    my ($self, $path) = @_;
    my @stat = lstat($path);
    return 0 if !@stat || !S_ISDIR($stat[2]) || $stat[4] != $self->{expected_owner_uid}
        || ($stat[2] & 0022) != 0;
    return 1;
}

sub _unit_name { return 'orm-instance@' . $_[1] . '.service'; }
sub _manifest_path { return File::Spec->catfile($_[0]->{etc_root}, $_[1], 'manifest.json'); }
sub _account_config_dir { return File::Spec->catdir($_[0]->{etc_root}, $_[1]); }
sub _account_data_dir { return File::Spec->catdir($_[0]->{data_root}, $_[1]); }

sub _redis_config {
    my ($data, $socket) = @_;
    return join("\n",
        'daemonize no',
        'supervised no',
        'port 0',
        'protected-mode yes',
        'unixsocket ' . $socket,
        'unixsocketperm 700',
        'pidfile ' . File::Spec->catfile($data, 'redis.pid'),
        'dir ' . $data,
        'dbfilename dump.rdb',
        'save ""',
        'appendonly no',
        'maxmemory ' . $MAX_MEMORY_BYTES,
        'maxmemory-policy allkeys-lru',
        'databases 16',
        'timeout 0',
        'maxclients 100',
        'logfile ""',
        ''
    );
}

sub _valid_account {
    my ($account) = @_;
    return 0 if !defined($account->{name}) || $account->{name} !~ /\A[a-zA-Z0-9_-]{1,16}\z/;
    return 0 if !defined($account->{uid}) || $account->{uid} !~ /\A[0-9]+\z/ || $account->{uid} == 0;
    return 0 if !defined($account->{gid}) || $account->{gid} !~ /\A[0-9]+\z/;
    return 1;
}

sub _state { return { success => JSON::PP::true, state => $_[0], version => 1 }; }
sub _failure { return { error => $_[0], success => JSON::PP::false, version => 1 }; }

1;
