package Orm::Broker::ProviderPolicy;
use strict;
use warnings;
use Errno qw(ENOENT);
use Fcntl qw(O_RDONLY O_NOFOLLOW :mode);
use JSON::PP ();
use MIME::Base64 qw(decode_base64 encode_base64);
use Sys::Syslog qw(:standard :macros);

my $MAX_POLICY_BYTES = 262144;
my $MAX_LOGO_BYTES = 32768;
my %MAXMEMORY_POLICIES = map { $_ => 1 } qw(
    allkeys-lru allkeys-lfu allkeys-random volatile-lru volatile-lfu volatile-random volatile-ttl noeviction
);
my $DEFAULT_POLICY = {
    version => 5,
    mode => 'report-only',
    exposure => 'simple',
    default => {
        enabled => JSON::PP::true, max_memory_mib => 64, backup_retention => 3,
        max_clients => 100, max_databases => 16,
    },
    instance_defaults => {
        memory_mib => 64,
        maxmemory_policy => 'allkeys-lru',
        databases => 16,
        metrics_history_retention_days => 30,
    },
    packages => {},
    resellers => {},
    branding => {
        product_name => 'Open Redis Manager',
        logo_png_base64 => '',
        support_url => '',
        preset => 'orm',
        primary_color => '#C92319',
        secondary_color => '#A91F18',
        surface_color => '#FFFFFF',
        text_color => '#172536',
        footer_visible => JSON::PP::true,
    },
};

sub new {
    my ($class, %args) = @_;
    return bless {
        path => $args{path} // '/etc/orm-provider-policy.json',
        expected_owner_uid => defined($args{expected_owner_uid}) ? $args{expected_owner_uid} : 0,
        audit => $args{audit},
        event_emitter => $args{event_emitter},
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
    my $owner = $account->{owner};
    $owner = 'root' if !defined($owner) || ref($owner)
        || $owner !~ /\A[a-zA-Z0-9_-]{1,16}\z/;
    my $limits = $policy->{packages}->{$package} // $policy->{default};
    my $reseller = $policy->{resellers}->{$owner} // { max_instances => 0, max_memory_mib => 0 };
    return {
        enabled => $limits->{enabled},
        max_memory_mib => 0 + $limits->{max_memory_mib},
        backup_retention => 0 + $limits->{backup_retention},
        max_clients => 0 + $limits->{max_clients},
        max_databases => 0 + $limits->{max_databases},
        instance_defaults => { %{$policy->{instance_defaults}} },
        owner => $owner,
        reseller_max_instances => 0 + $reseller->{max_instances},
        reseller_max_memory_mib => 0 + $reseller->{max_memory_mib},
        mode => $policy->{mode},
    };
}

sub exposure_mode {
    my ($self) = @_;
    my $policy = $self->_read_policy();
    return undef if ref($policy) ne 'HASH';
    return $policy->{exposure};
}

sub reseller_rules {
    my ($self) = @_;
    my $policy = $self->_read_policy();
    return undef if ref($policy) ne 'HASH';
    return { map { $_ => { %{$policy->{resellers}->{$_}} } } keys %{$policy->{resellers}} };
}

sub branding_settings {
    my ($self) = @_;
    my $policy = $self->_read_policy();
    return undef if ref($policy) ne 'HASH' || ref($policy->{branding}) ne 'HASH';
    return { %{$policy->{branding}} };
}

sub provision_decision {
    my ($self, $account, $memory_mib, $usage_provider) = @_;
    return undef if !defined($memory_mib) || ref($memory_mib) || $memory_mib !~ /\A[0-9]+\z/;
    my $effective = $self->effective_for($account);
    return undef if ref($effective) ne 'HASH';
    $memory_mib = _minimum($memory_mib, $effective->{instance_defaults}->{memory_mib});
    my @violations;
    push @violations, 'package_disabled' if !$effective->{enabled};
    push @violations, 'memory_limit_exceeded' if $memory_mib > $effective->{max_memory_mib};
    if ($effective->{reseller_max_instances} > 0 || $effective->{reseller_max_memory_mib} > 0) {
        my $usage = ref($usage_provider) eq 'CODE' ? eval { $usage_provider->($effective->{owner}) } : undef;
        if (ref($usage) ne 'HASH' || !_is_integer($usage->{instances})
            || !_is_integer($usage->{memory_mib})) {
            push @violations, 'reseller_usage_unavailable';
        } else {
            push @violations, 'reseller_instance_quota_exceeded'
                if $effective->{reseller_max_instances} > 0
                && $usage->{instances} >= $effective->{reseller_max_instances};
            push @violations, 'reseller_memory_quota_exceeded'
                if $effective->{reseller_max_memory_mib} > 0
                && $usage->{memory_mib} + $memory_mib > $effective->{reseller_max_memory_mib};
        }
    }
    my $decision = $self->_decision($effective, \@violations, $account, 'instance.provision');
    $decision->{provision_memory_mib} = 0 + $memory_mib;
    $decision->{provision_max_clients} = _minimum(100, $effective->{max_clients});
    $decision->{provision_databases} = _minimum(
        $effective->{instance_defaults}->{databases}, $effective->{max_databases}
    );
    return $decision;
}

sub memory_decision {
    my ($self, $account, $memory_mib, $max_clients, $existing_max_clients) = @_;
    return undef if !defined($memory_mib) || ref($memory_mib) || $memory_mib !~ /\A[0-9]+\z/;
    my $effective = $self->effective_for($account);
    return undef if ref($effective) ne 'HASH';
    my @violations;
    push @violations, 'memory_limit_exceeded' if $memory_mib > $effective->{max_memory_mib};
    if (defined($max_clients)) {
        return undef if !_is_integer($max_clients) || $max_clients < 10 || $max_clients > 100;
        return undef if defined($existing_max_clients)
            && (!_is_integer($existing_max_clients) || $existing_max_clients < 10 || $existing_max_clients > 100);
        push @violations, 'client_limit_exceeded'
            if $max_clients > $effective->{max_clients}
            && (!defined($existing_max_clients) || $max_clients > $existing_max_clients);
    }
    return $self->_decision($effective, \@violations, $account, 'instance.configure');
}

sub _decision {
    my ($self, $effective, $violations, $account, $operation) = @_;
    my $allowed = $effective->{mode} ne 'enforce' || !@{$violations} ? 1 : 0;
    if (@{$violations}) {
        my $actor_uid = ref($account) eq 'HASH' && defined($account->{uid}) && !ref($account->{uid})
            && $account->{uid} =~ /\A[0-9]{1,10}\z/ ? $account->{uid} : 'unknown';
        my $account_name = ref($account) eq 'HASH' && defined($account->{name}) && !ref($account->{name})
            && $account->{name} =~ /\A[a-zA-Z0-9_-]{1,16}\z/ ? $account->{name} : 'invalid';
        my $message = 'provider_policy actor_uid=' . $actor_uid . ' account=' . $account_name
            . ' action=policy.violation result=' . $effective->{mode} . ' state=' . join(',', @{$violations});
        if (ref($self->{audit}) eq 'CODE') {
            eval { $self->{audit}->($message) };
        } else {
            eval {
                openlog('orm-broker', 'pid', 'authpriv');
                syslog(LOG_NOTICE, '%s', $message);
                closelog();
            };
        }
    }
    if (!$allowed && ref($self->{event_emitter}) && eval { $self->{event_emitter}->can('emit') }) {
        my %violations = map { $_ => 1 } @{$violations};
        my $reason = $violations{package_disabled} ? 'policy_disabled' : 'quota_exceeded';
        eval { $self->{event_emitter}->emit('policy.denied', {
            operation => $operation, reason_code => $reason,
        }); };
        eval { $self->{event_emitter}->emit('quota.reached', {
            quota_kind => $violations{reseller_instance_quota_exceeded} ? 'instances' : 'memory_mib',
        }); } if $violations{reseller_instance_quota_exceeded} || $violations{reseller_memory_quota_exceeded};
    }
    return {
        allowed => $allowed,
        mode => $effective->{mode},
        max_memory_mib => $effective->{max_memory_mib},
        backup_retention => $effective->{backup_retention},
        max_clients => $effective->{max_clients},
        max_databases => $effective->{max_databases},
        instance_defaults => { %{$effective->{instance_defaults}} },
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
        return { %{$DEFAULT_POLICY}, default => { %{$DEFAULT_POLICY->{default}} },
            instance_defaults => { %{$DEFAULT_POLICY->{instance_defaults}} }, packages => {}, resellers => {},
            branding => { %{$DEFAULT_POLICY->{branding}} } }
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
    return _upgrade_policy($policy);
}

sub _upgrade_policy {
    my ($policy) = @_;
    return $policy if $policy->{version} == 5;
    my $upgrade_limits = sub {
        my ($limits) = @_;
        return {
            %{$limits},
            max_clients => 100,
            max_databases => 16,
        };
    };
    my %packages = map { $_ => $upgrade_limits->($policy->{packages}->{$_}) } keys %{$policy->{packages}};
    return {
        version => 5,
        mode => $policy->{version} == 1 && $policy->{mode} eq 'report-only' ? 'warn' : $policy->{mode},
        exposure => $policy->{version} >= 2 ? $policy->{exposure} : 'simple',
        default => $upgrade_limits->($policy->{default}),
        instance_defaults => {
            %{$policy->{version} >= 4 ? $policy->{instance_defaults} : $DEFAULT_POLICY->{instance_defaults}}
        },
        packages => \%packages,
        resellers => $policy->{version} >= 2 ? $policy->{resellers} : {},
        branding => $policy->{version} >= 3 ? $policy->{branding} : { %{$DEFAULT_POLICY->{branding}} },
    };
}

sub _valid_policy {
    my ($policy) = @_;
    return 0 if ref($policy) ne 'HASH' || !_is_integer($policy->{version});
    if ($policy->{version} == 1) {
        return 0 if join(',', sort keys %{$policy}) ne 'default,mode,packages,version'
            || !defined($policy->{mode}) || ref($policy->{mode})
            || $policy->{mode} !~ /\A(?:report-only|enforce)\z/;
    } elsif ($policy->{version} == 2) {
        return 0 if join(',', sort keys %{$policy}) ne 'default,exposure,mode,packages,resellers,version'
            || !defined($policy->{mode}) || ref($policy->{mode})
            || $policy->{mode} !~ /\A(?:report-only|warn|enforce)\z/
            || !defined($policy->{exposure}) || ref($policy->{exposure})
            || $policy->{exposure} !~ /\A(?:simple|developer|advanced)\z/
            || ref($policy->{resellers}) ne 'HASH' || scalar(keys %{$policy->{resellers}}) > 1000;
    } elsif ($policy->{version} == 3) {
        return 0 if join(',', sort keys %{$policy}) ne 'branding,default,exposure,mode,packages,resellers,version'
            || !defined($policy->{mode}) || ref($policy->{mode})
            || $policy->{mode} !~ /\A(?:report-only|warn|enforce)\z/
            || !defined($policy->{exposure}) || ref($policy->{exposure})
            || $policy->{exposure} !~ /\A(?:simple|developer|advanced)\z/
            || ref($policy->{resellers}) ne 'HASH' || scalar(keys %{$policy->{resellers}}) > 1000
            || !_valid_branding($policy->{branding});
    } elsif ($policy->{version} == 4 || $policy->{version} == 5) {
        return 0 if join(',', sort keys %{$policy}) ne 'branding,default,exposure,instance_defaults,mode,packages,resellers,version'
            || !defined($policy->{mode}) || ref($policy->{mode})
            || $policy->{mode} !~ /\A(?:report-only|warn|enforce)\z/
            || !defined($policy->{exposure}) || ref($policy->{exposure})
            || $policy->{exposure} !~ /\A(?:simple|developer|advanced)\z/
            || ref($policy->{resellers}) ne 'HASH' || scalar(keys %{$policy->{resellers}}) > 1000
            || !_valid_branding($policy->{branding}) || !_valid_instance_defaults($policy->{instance_defaults});
    } else {
        return 0;
    }
    return 0 if !_valid_limits($policy->{default}, $policy->{version} == 5) || ref($policy->{packages}) ne 'HASH'
        || scalar(keys %{$policy->{packages}}) > 1000;
    for my $name (keys %{$policy->{packages}}) {
        return 0 if !defined($name) || $name !~ /\A[a-zA-Z0-9_.-]{1,64}\z/
            || $name eq 'default' || !_valid_limits($policy->{packages}->{$name}, $policy->{version} == 5);
    }
    if ($policy->{version} >= 2) {
        for my $owner (keys %{$policy->{resellers}}) {
            return 0 if !defined($owner) || $owner !~ /\A[a-zA-Z0-9_-]{1,16}\z/
                || !_valid_reseller_limits($policy->{resellers}->{$owner});
        }
    }
    return 1;
}

sub _valid_branding {
    my ($branding) = @_;
    return 0 if ref($branding) ne 'HASH'
        || join(',', sort keys %{$branding}) ne 'footer_visible,logo_png_base64,preset,primary_color,product_name,secondary_color,support_url,surface_color,text_color'
        || !defined($branding->{product_name}) || ref($branding->{product_name})
        || $branding->{product_name} !~ /\A[A-Za-z0-9][A-Za-z0-9 .&()+\/_-]{0,47}\z/
        || !defined($branding->{support_url}) || ref($branding->{support_url})
        || !_valid_support_url($branding->{support_url})
        || !defined($branding->{preset}) || ref($branding->{preset})
        || $branding->{preset} !~ /\A(?:custom|orm|underhost|redis|valkey)\z/
        || !_is_brand_hex_color($branding->{primary_color}) || !_is_brand_hex_color($branding->{secondary_color})
        || !_is_brand_hex_color($branding->{surface_color}) || !_is_brand_hex_color($branding->{text_color})
        || !_has_brand_contrast($branding->{primary_color}, '#FFFFFF')
        || !_has_brand_contrast($branding->{primary_color}, $branding->{surface_color})
        || !_has_brand_contrast($branding->{secondary_color}, $branding->{surface_color})
        || !_has_brand_contrast($branding->{text_color}, '#FFFFFF')
        || !_has_brand_contrast($branding->{text_color}, $branding->{surface_color})
        || !JSON::PP::is_bool($branding->{footer_visible})
        || !defined($branding->{logo_png_base64}) || ref($branding->{logo_png_base64});
    my $logo = $branding->{logo_png_base64};
    return 1 if $logo eq '';
    return 0 if length($logo) > int(($MAX_LOGO_BYTES * 4 / 3) + 4)
        || $logo !~ /\A(?:[A-Za-z0-9+\/]{4})*(?:[A-Za-z0-9+\/]{2}==|[A-Za-z0-9+\/]{3}=)?\z/;
    my $bytes = decode_base64($logo);
    return 0 if length($bytes) > $MAX_LOGO_BYTES || encode_base64($bytes, '') ne $logo;
    return _valid_logo_png($bytes);
}

sub _valid_logo_png {
    my ($bytes) = @_;
    return 0 if length($bytes) < 45 || substr($bytes, 0, 8) ne "\x89PNG\r\n\x1a\n";
    my $offset = 8;
    my ($width, $height, $color_type, $seen_header, $seen_palette, $seen_data, $data_bytes) = (0, 0, 0, 0, 0, 0, 0);
    while ($offset < length($bytes)) {
        return 0 if length($bytes) - $offset < 12;
        my $chunk_length = unpack('N', substr($bytes, $offset, 4));
        my $chunk_type = substr($bytes, $offset + 4, 4);
        return 0 if $chunk_type !~ /\A[A-Za-z]{4}\z/ || substr($chunk_type, 2, 1) !~ /\A[A-Z]\z/
            || $chunk_length > $MAX_LOGO_BYTES || $offset + 12 + $chunk_length > length($bytes);
        my $chunk_data = substr($bytes, $offset + 8, $chunk_length);
        my $chunk_crc = unpack('N', substr($bytes, $offset + 8 + $chunk_length, 4));
        return 0 if _png_crc32($chunk_type . $chunk_data) != $chunk_crc;
        if (!$seen_header) {
            return 0 if $chunk_type ne 'IHDR' || $chunk_length != 13;
            ($width, $height) = unpack('N2', substr($chunk_data, 0, 8));
            my $depth = unpack('C', substr($chunk_data, 8, 1));
            $color_type = unpack('C', substr($chunk_data, 9, 1));
            my ($method, $filter, $interlace) = unpack('C3', substr($chunk_data, 10, 3));
            my %valid_depths = (0 => [1, 2, 4, 8, 16], 2 => [8, 16], 3 => [1, 2, 4, 8], 4 => [8, 16], 6 => [8, 16]);
            my $valid_depth = exists($valid_depths{$color_type})
                ? scalar grep { $_ == $depth } @{$valid_depths{$color_type}}
                : 0;
            return 0 if $width < 16 || $width > 512 || $height < 16 || $height > 256
                || !$valid_depth
                || $method != 0 || $filter != 0 || $interlace > 1;
            $seen_header = 1;
        } elsif ($chunk_type eq 'IHDR') {
            return 0;
        }
        if ($chunk_type eq 'PLTE') {
            return 0 if $seen_palette || $seen_data || $chunk_length == 0 || $chunk_length > 768 || $chunk_length % 3 != 0;
            $seen_palette = 1;
        } elsif ($chunk_type eq 'IDAT') {
            return 0 if $color_type == 3 && !$seen_palette;
            $seen_data = 1;
            $data_bytes += $chunk_length;
        } elsif ($chunk_type eq 'IEND') {
            return $chunk_length == 0 && $seen_data && $data_bytes > 0 && $offset + 12 == length($bytes);
        } elsif ($chunk_type =~ /\A[A-Z]/ && $chunk_type ne 'IHDR') {
            return 0;
        }
        $offset += 12 + $chunk_length;
    }
    return 0;
}

sub _png_crc32 {
    my ($data) = @_;
    my $crc = 0xffffffff;
    for my $byte (unpack('C*', $data)) {
        $crc ^= $byte;
        for (1 .. 8) {
            $crc = ($crc >> 1) ^ (($crc & 1) ? 0xedb88320 : 0);
        }
    }
    return ($crc ^ 0xffffffff) & 0xffffffff;
}

sub _valid_support_url {
    my ($url) = @_;
    return 1 if defined($url) && !ref($url) && $url eq '';
    return 0 if !defined($url) || ref($url) || length($url) > 200
        || $url !~ m{\Ahttps://[^\s/?#@]+(?::[0-9]{1,5})?(?:/[A-Za-z0-9._~!\$&'()*+,;=:@%/-]*)?\z};
    my ($authority) = $url =~ m{\Ahttps://([^/]+)};
    return 0 if !defined($authority);
    my ($host, $port) = $authority =~ /\A([A-Za-z0-9.-]+)(?::([0-9]{1,5}))?\z/;
    return 0 if !defined($host) || length($host) > 253;
    for my $label (split /\./, $host) {
        return 0 if length($label) < 1 || length($label) > 63
            || $label !~ /\A[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\z/;
    }
    return 0 if defined($port) && ($port < 1 || $port > 65535);
    return 1;
}

sub _is_brand_hex_color {
    my ($color) = @_;
    return defined($color) && !ref($color) && $color =~ /\A#[A-Fa-f0-9]{6}\z/;
}

sub _has_brand_contrast {
    my ($foreground, $background) = @_;
    return 0 if !_is_brand_hex_color($foreground) || !_is_brand_hex_color($background);
    my $luminance = sub {
        my ($color) = @_;
        my @components = map { hex($_) / 255 } ($color =~ /\A#(..)(..)(..)\z/);
        my @linear = map { $_ <= 0.04045 ? $_ / 12.92 : (($_ + 0.055) / 1.055) ** 2.4 } @components;
        return 0.2126 * $linear[0] + 0.7152 * $linear[1] + 0.0722 * $linear[2];
    };
    my $first = $luminance->($foreground);
    my $second = $luminance->($background);
    my ($light, $dark) = $first >= $second ? ($first, $second) : ($second, $first);
    return ($light + 0.05) / ($dark + 0.05) >= 4.5;
}

sub _valid_limits {
    my ($limits, $with_resource_limits) = @_;
    my $expected_keys = $with_resource_limits
        ? 'backup_retention,enabled,max_clients,max_databases,max_memory_mib'
        : 'backup_retention,enabled,max_memory_mib';
    return 0 if ref($limits) ne 'HASH'
        || join(',', sort keys %{$limits}) ne $expected_keys
        || !JSON::PP::is_bool($limits->{enabled})
        || !_is_integer($limits->{max_memory_mib}) || $limits->{max_memory_mib} < 8 || $limits->{max_memory_mib} > 64
        || !_is_integer($limits->{backup_retention}) || $limits->{backup_retention} < 2 || $limits->{backup_retention} > 3
        || ($with_resource_limits && (!_is_integer($limits->{max_clients}) || $limits->{max_clients} < 10 || $limits->{max_clients} > 100
            || !_is_integer($limits->{max_databases}) || $limits->{max_databases} < 1 || $limits->{max_databases} > 16));
    return 1;
}

sub _valid_reseller_limits {
    my ($limits) = @_;
    return 0 if ref($limits) ne 'HASH'
        || join(',', sort keys %{$limits}) ne 'max_instances,max_memory_mib'
        || !_is_integer($limits->{max_instances}) || $limits->{max_instances} > 100000
        || !_is_integer($limits->{max_memory_mib}) || $limits->{max_memory_mib} > 1_000_000;
    return 1;
}

sub _valid_instance_defaults {
    my ($defaults) = @_;
    return 0 if ref($defaults) ne 'HASH'
        || join(',', sort keys %{$defaults}) ne 'databases,maxmemory_policy,memory_mib,metrics_history_retention_days'
        || !_is_integer($defaults->{memory_mib}) || $defaults->{memory_mib} < 8 || $defaults->{memory_mib} > 64
        || !_is_integer($defaults->{databases}) || $defaults->{databases} < 1 || $defaults->{databases} > 16
        || !_is_integer($defaults->{metrics_history_retention_days})
        || $defaults->{metrics_history_retention_days} < 7 || $defaults->{metrics_history_retention_days} > 90
        || !defined($defaults->{maxmemory_policy}) || ref($defaults->{maxmemory_policy})
        || !exists($MAXMEMORY_POLICIES{$defaults->{maxmemory_policy}});
    return 1;
}

sub _minimum { return $_[0] < $_[1] ? $_[0] : $_[1]; }

sub _is_integer {
    my ($value) = @_;
    return defined($value) && !ref($value) && $value =~ /\A(?:0|[1-9][0-9]*)\z/;
}

1;
