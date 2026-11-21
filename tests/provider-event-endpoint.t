use strict;
use warnings;
use Test::More;
use lib 'src';
use Orm::Broker::ProviderEventEndpoint qw(parse_destination validate_destination is_public_address);

ok(is_public_address('8.8.8.8'), 'accepts a global IPv4 address');
ok(!is_public_address('10.0.0.1'), 'rejects private IPv4');
ok(!is_public_address('100.64.0.1'), 'rejects shared carrier-grade NAT IPv4');
ok(!is_public_address('169.254.1.1'), 'rejects link-local IPv4');
ok(!is_public_address('192.0.2.1'), 'rejects documentation IPv4');
ok(!is_public_address('198.51.100.2'), 'rejects second documentation IPv4 block');
ok(!is_public_address('203.0.113.3'), 'rejects third documentation IPv4 block');
ok(!is_public_address('192.0.0.1'), 'rejects IPv4 protocol-assignment space');
ok(!is_public_address('192.88.99.1'), 'rejects deprecated IPv4 relay space');
ok(!is_public_address('198.19.0.1'), 'rejects benchmarking IPv4 space');
ok(!is_public_address('224.0.0.1'), 'rejects multicast IPv4');
ok(is_public_address('2606:4700:4700::1111'), 'accepts global IPv6 unicast');
ok(!is_public_address('::1'), 'rejects IPv6 loopback');
ok(!is_public_address('fd00::1'), 'rejects IPv6 unique-local');
ok(!is_public_address('fe80::1'), 'rejects IPv6 link-local');
ok(!is_public_address('2001:db8::1'), 'rejects IPv6 documentation range');
ok(!is_public_address('100::1'), 'rejects discard-only IPv6 space');
ok(!is_public_address('2001:2::1'), 'rejects IPv6 benchmarking space');
ok(!is_public_address('2002::1'), 'rejects deprecated 6to4 space');
ok(!is_public_address('5f00::1'), 'rejects IPv6 segment-routing space');
ok(!is_public_address('::ffff:8.8.8.8'), 'rejects IPv4-mapped IPv6');

my ($endpoint, $error) = validate_destination('https://hooks.example.net/orm/events', ['8.8.8.8', '2606:4700:4700::1111']);
is($error, undef, 'accepts a hostname with exclusively global DNS answers');
is_deeply($endpoint, {
    host => 'hooks.example.net', path => '/orm/events', port => 443,
    addresses => ['2606:4700:4700::1111', '8.8.8.8'],
}, 'returns normalized host, fixed port, path, and addresses for connection pinning');
my ($syntax_only, $syntax_error) = parse_destination('https://hooks.example.net/orm/events');
is($syntax_error, undef, 'validates HTTPS destination syntax without DNS from the isolated broker');
is_deeply($syntax_only, { host => 'hooks.example.net', path => '/orm/events', port => 443 },
    'returns a normalized host, fixed TLS port, and path before worker-side DNS validation');
my @many_addresses = map { "8.8.8.$_" } 1 .. 17;
is((validate_destination('https://hooks.example.net/', \@many_addresses))[1], 'too_many_addresses',
    'bounds the number of pinned DNS addresses');
is((validate_destination('http://hooks.example.net/', ['8.8.8.8']))[1], 'invalid_destination', 'requires HTTPS');
is((validate_destination('https://user:pass@hooks.example.net/', ['8.8.8.8']))[1], 'invalid_destination', 'rejects URL credentials');
is((validate_destination('https://hooks.example.net:8443/', ['8.8.8.8']))[1], 'invalid_destination', 'rejects nonstandard ports');
is((validate_destination('https://127.0.0.1/', ['8.8.8.8']))[1], 'invalid_destination', 'rejects IP literal destinations');
is((validate_destination('https://hooks.example.net/path?secret=x', ['8.8.8.8']))[1], 'invalid_destination', 'rejects query strings');
is((validate_destination('https://hooks.example.net/%0d%0aheader', ['8.8.8.8']))[1], 'invalid_destination', 'rejects encoded control bytes');
is((validate_destination('https://hooks.example.net/', ['8.8.8.8', '127.0.0.1']))[1], 'unsafe_address', 'rejects the entire answer set if any answer is unsafe');
is((validate_destination('https://hooks.example.net/', []))[1], 'dns_failed', 'rejects an empty DNS answer set');
is((validate_destination('https://bad-.example.net/', ['8.8.8.8']))[1], 'invalid_destination', 'rejects malformed DNS labels');

done_testing();
