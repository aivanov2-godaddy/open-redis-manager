package Orm::Broker::ProviderEventConfig;
use strict;
use warnings;
use Fcntl qw(O_CREAT O_EXCL O_RDONLY O_WRONLY O_NOFOLLOW :mode);
use Errno qw(ENOENT);
use IO::Handle;
use JSON::PP ();
use Orm::Broker::ProviderEventEndpoint qw(parse_destination);

my $JSON = JSON::PP->new->canonical(1)->utf8(1)->allow_nonref(0);
my $MAX_BYTES = 4096;

sub new {
    my ($class, %args) = @_;
    return bless {
        path => $args{path} // '/etc/orm-provider-events.json',
        owner_uid => defined($args{owner_uid}) ? $args{owner_uid} : 0,
        current_uid => defined($args{current_uid}) ? $args{current_uid} : $>,
    }, $class;
}

sub defaults { return { version => 1, enabled => JSON::PP::false, destination => '', signing_key => '' }; }

sub _authorized {
    my ($self) = @_;
    return $self->{current_uid} == $self->{owner_uid};
}

sub _safe_parent {
    my ($self) = @_;
    my $parent = $self->{path};
    $parent =~ s{/[^/]+\z}{};
    my @st = lstat($parent);
    return 0 if !@st || !S_ISDIR($st[2]) || S_ISLNK($st[2]) || $st[4] != $self->{owner_uid}
        || ($st[2] & 0022) != 0;
    return 1;
}

sub _normalize {
    my ($config) = @_;
    return if ref($config) ne 'HASH';
    my $enabled;
    if (JSON::PP::is_bool($config->{enabled})) {
        $enabled = $config->{enabled} ? 1 : 0;
    } else {
        return if ref($config->{enabled}) || !defined($config->{enabled})
            || ($config->{enabled} ne '0' && $config->{enabled} ne '1');
        $enabled = $config->{enabled} eq '1' ? 1 : 0;
    }
    my @keys = sort keys %$config;
    return if join(',', @keys) ne 'destination,enabled,signing_key,version'
        || ($config->{version} // 0) != 1
        || ref($config->{destination}) || length($config->{destination}) > 2048
        || ref($config->{signing_key}) || ($config->{signing_key} ne '' && $config->{signing_key} !~ /\A[a-f0-9]{64}\z/);
    return if $enabled && ($config->{destination} eq '' || length($config->{signing_key}) != 64);
    if ($config->{destination} ne '') {
        my ($endpoint) = parse_destination($config->{destination});
        return if !defined($endpoint);
    }
    return {
        version => 1,
        enabled => $enabled ? JSON::PP::true : JSON::PP::false,
        destination => $config->{destination},
        signing_key => $config->{signing_key},
    };
}

sub load {
    my ($self) = @_;
    return (undef, 'not_authorized') if !$self->_authorized();
    return (undef, 'unsafe_path') if !$self->_safe_parent();
    my @st = lstat($self->{path});
    return (defaults(), 'ok') if !@st && $! == ENOENT;
    return (undef, 'unsafe_config') if !@st || !S_ISREG($st[2]) || $st[4] != $self->{owner_uid}
        || $st[3] != 1 || ($st[2] & 07777) != 0600 || $st[7] > $MAX_BYTES;
    sysopen(my $fh, $self->{path}, O_RDONLY | O_NOFOLLOW) or return (undef, 'read_failed');
    my @opened = stat($fh);
    local $/;
    my $raw = <$fh>;
    close($fh);
    return (undef, 'unsafe_config') if !@opened || $opened[0] != $st[0] || $opened[1] != $st[1]
        || !defined($raw) || length($raw) > $MAX_BYTES;
    my $decoded = eval { $JSON->decode($raw) };
    my $normalized = _normalize($decoded);
    return (undef, 'invalid_config') if !defined($normalized);
    return ($normalized, 'ok');
}

sub save {
    my ($self, $destination, $enabled, $rotate_key) = @_;
    return (undef, 'not_authorized') if !$self->_authorized();
    return (undef, 'unsafe_path') if !$self->_safe_parent();
    return (undef, 'invalid_config') if !defined($destination) || ref($destination) || length($destination) > 2048
        || !defined($enabled) || ref($enabled) || ($enabled ne '0' && $enabled ne '1')
        || !defined($rotate_key) || ref($rotate_key) || ($rotate_key ne '0' && $rotate_key ne '1');
    if ($destination ne '') {
        my ($endpoint, $error) = parse_destination($destination);
        return (undef, $error // 'invalid_destination') if !defined($endpoint);
    }
    my ($current) = $self->load();
    return (undef, 'unsafe_config') if !defined($current);
    my $key = $current->{signing_key};
    if ($rotate_key eq '1' || $key eq '') {
        my $random;
        my $source;
        if (!open($source, '<:raw', '/dev/urandom')) { return (undef, 'random_unavailable'); }
        my $read = read($source, $random, 32);
        close($source);
        return (undef, 'random_unavailable') if !defined($read) || $read != 32;
        $key = unpack('H*', $random);
    }
    return (undef, 'invalid_destination') if $enabled eq '1' && ($destination eq '' || length($key) != 64);
    my $config = {
        version => 1,
        enabled => $enabled eq '1' ? JSON::PP::true : JSON::PP::false,
        destination => $destination,
        signing_key => $key,
    };
    my $raw = eval { $JSON->encode($config) . "\n" };
    return (undef, 'invalid_config') if !defined($raw) || length($raw) > $MAX_BYTES;
    my $temporary = $self->{path} . '.' . $$ . '.' . int(rand(1_000_000)) . '.tmp';
    sysopen(my $fh, $temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600)
        or return (undef, 'write_failed');
    binmode($fh);
    my $ok = print {$fh} $raw;
    $ok &&= $fh->flush();
    $ok &&= $fh->sync();
    my @written = stat($fh);
    close($fh) or $ok = 0;
    if (!$ok || !@written || $written[4] != $self->{owner_uid} || !rename($temporary, $self->{path})) {
        unlink($temporary);
        return (undef, 'write_failed');
    }
    return ({ enabled => $config->{enabled}, destination => $destination,
        key_rotated => ($rotate_key eq '1' || $current->{signing_key} ne $key) ? 1 : 0 }, 'ok');
}

sub public_view {
    my ($self, $config) = @_;
    return if ref($config) ne 'HASH';
    return {
        enabled => $config->{enabled} ? JSON::PP::true : JSON::PP::false,
        destination => $config->{destination},
        key_configured => length($config->{signing_key} // '') == 64 ? JSON::PP::true : JSON::PP::false,
    };
}

1;
