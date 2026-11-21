package Orm::Broker::ProviderEventEndpoint;
use strict;
use warnings;
use Exporter qw(import);
use Socket qw(AF_UNSPEC AF_INET AF_INET6 SOCK_STREAM IPPROTO_TCP inet_pton inet_ntop getaddrinfo unpack_sockaddr_in unpack_sockaddr_in6);

our @EXPORT_OK = qw(parse_destination validate_destination is_public_address);

sub is_public_address {
    my ($address) = @_;
    return 0 if !defined($address) || ref($address);
    my $v4 = inet_pton(AF_INET, $address);
    if (defined($v4)) {
        my @o = unpack('C4', $v4);
        return 0 if $o[0] == 0 || $o[0] == 10 || $o[0] == 127 || $o[0] >= 224
            || ($o[0] == 100 && $o[1] >= 64 && $o[1] <= 127)
            || ($o[0] == 169 && $o[1] == 254)
            || ($o[0] == 172 && $o[1] >= 16 && $o[1] <= 31)
            || ($o[0] == 192 && ($o[1] == 168 || ($o[1] == 0 && ($o[2] == 0 || $o[2] == 2))
                || ($o[1] == 88 && $o[2] == 99)))
            || ($o[0] == 198 && (($o[1] == 18 || $o[1] == 19)
                || ($o[1] == 51 && $o[2] == 100)))
            || ($o[0] == 203 && $o[1] == 0 && $o[2] == 113);
        return 1;
    }
    my $v6 = inet_pton(AF_INET6, $address);
    return 0 if !defined($v6);
    my @b = unpack('C16', $v6);
    return 0 if ($b[0] & 0xe0) != 0x20; # only global-unicast 2000::/3
    return 0 if $b[0] == 0x20 && $b[1] == 0x01 && $b[2] == 0 && $b[3] < 0x80; # 2001::/23 special-use
    return 0 if $b[0] == 0x20 && $b[1] == 0x01 && $b[2] == 0x0d && $b[3] == 0xb8; # documentation
    return 0 if $b[0] == 0x20 && $b[1] == 0x02; # deprecated 6to4 relay path
    return 0 if $b[0] == 0x3f && $b[1] == 0xff && ($b[2] & 0xf0) == 0x00; # documentation 3fff::/20
    return 1;
}

sub _resolve {
    my ($host) = @_;
    my ($error, @results);
    my $resolved = eval {
        local $SIG{ALRM} = sub { die "dns_timeout\n" };
        alarm(3);
        ($error, @results) = getaddrinfo($host, '443', {
            family => AF_UNSPEC,
            socktype => SOCK_STREAM,
            protocol => IPPROTO_TCP,
        });
        alarm(0);
        1;
    };
    alarm(0);
    return (undef, 'dns_failed') if !$resolved;
    my @addresses;
    for my $result (@results) {
        next if ref($result) ne 'HASH';
        my $ip;
        if ($result->{family} == AF_INET) {
            my (undef, $packed) = unpack_sockaddr_in($result->{addr});
            $ip = inet_ntop(AF_INET, $packed) if defined($packed);
        } elsif ($result->{family} == AF_INET6) {
            my (undef, $packed) = unpack_sockaddr_in6($result->{addr});
            $ip = inet_ntop(AF_INET6, $packed) if defined($packed);
        }
        push @addresses, $ip if defined($ip);
    }
    return (undef, 'dns_failed') if $error || !@addresses;
    return (\@addresses, undef);
}

sub parse_destination {
    my ($url, $resolved) = @_;
    return (undef, 'invalid_destination') if !defined($url) || ref($url) || length($url) > 2048
        || $url !~ m{\Ahttps://([a-z0-9](?:[a-z0-9.-]{0,251}[a-z0-9])?)(?::443)?(/[A-Za-z0-9/._~!\$&'()*+,;=:@%-]*)?\z}i;
    my ($host, $path) = (lc($1), defined($2) ? $2 : '/');
    my @labels = split /\./, $host, -1;
    return (undef, 'invalid_destination') if length($host) > 253 || @labels < 2
        || $host =~ /\A[0-9.]+\z/
        || (grep { length($_) < 1 || length($_) > 63 || $_ !~ /\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/ } @labels)
        || $path =~ /%(?:0[0-9a-f]|1[0-9a-f]|7f)/i;
    return ({ host => $host, path => $path, port => 443 }, undef);
}

sub validate_destination {
    my ($url, $resolved) = @_;
    my ($endpoint, $syntax_error) = parse_destination($url);
    return (undef, $syntax_error) if !defined($endpoint);
    if (!defined($resolved)) {
        ($resolved) = _resolve($endpoint->{host});
        return (undef, 'dns_failed') if ref($resolved) ne 'ARRAY';
    }
    return (undef, 'dns_failed') if ref($resolved) ne 'ARRAY' || !@$resolved;
    my %unique;
    for my $address (@$resolved) {
        return (undef, 'unsafe_address') if !is_public_address($address);
        $unique{$address} = 1;
        return (undef, 'too_many_addresses') if keys(%unique) > 16;
    }
    return ({ %$endpoint, addresses => [sort keys %unique] }, undef);
}

1;
