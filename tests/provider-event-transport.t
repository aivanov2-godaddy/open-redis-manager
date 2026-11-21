use strict;
use warnings;
use Test::More;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);
use lib 'src';
use Orm::Broker::ProviderEvents qw(build_envelope sign_envelope);
use Orm::Broker::ProviderEventTransport qw(deliver_event);

my ($event, $error) = build_envelope('instance.started', { backend => 'redis' },
    event_id => '0123456789abcdef0123456789abcdef', now => time());
is($error, undef, 'builds a valid event envelope');
my $key = 't' x 32;
my $signature = sign_envelope($event, $key);

sub mocked_delivery {
    my ($response) = @_;
    my ($client, $server);
    socketpair($client, $server, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die 'socketpair failed';
    binmode($client);
    binmode($server);
    syswrite($server, $response) or die 'mock response write failed';
    my $called = 0;
    my $result = deliver_event('https://hooks.example.net/orm', $event, $signature, $key,
        resolved_addresses => ['8.8.8.8'],
        socket_factory => sub {
            my ($hostname, $ip) = @_;
            is($hostname, 'hooks.example.net', 'TLS identity hostname is separate from pinned IP');
            is($ip, '8.8.8.8', 'transport receives only the validated pinned IP');
            $called++;
            return $client;
        });
    my $request = '';
    sysread($server, $request, 32768);
    close($server);
    is($called, 1, 'opens one pinned connection');
    return ($result, $request);
}

my ($accepted, $request) = mocked_delivery("HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n");
is_deeply($accepted, { outcome => 'delivered', code => 'accepted', http_status => 204 }, 'classifies 2xx as accepted');
like($request, qr/\APOST \/orm HTTP\/1\.1\r\n/, 'posts only to the configured fixed path');
like($request, qr/\r\nConnection: close\r\n/, 'disables keep-alive');
like($request, qr/\r\nX-ORM-Signature: \Q$signature\E\r\n/, 'sends the envelope signature in the fixed header');
unlike($request, qr/(?:password|redis_key|connection_string)/i, 'request contains no sensitive metadata fields');

my ($redirect) = mocked_delivery("HTTP/1.1 302 Found\r\nLocation: https://other.example/\r\nContent-Length: 0\r\n\r\n");
is_deeply($redirect, { outcome => 'permanent', code => 'redirect_rejected', http_status => 302 }, 'rejects redirects without following them');
my ($temporary) = mocked_delivery("HTTP/1.1 503 Busy\r\nContent-Length: 0\r\n\r\n");
is_deeply($temporary, { outcome => 'retryable', code => 'remote_temporary_failure', http_status => 503 }, 'classifies server failure as retryable');
my ($rejected) = mocked_delivery("HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n");
is_deeply($rejected, { outcome => 'permanent', code => 'remote_rejected', http_status => 401 }, 'classifies receiver rejection as permanent');

my ($delayed_event) = build_envelope('instance.started', { backend => 'redis' },
    event_id => '1123456789abcdef0123456789abcdef', now => time() - 1800);
my $delayed_signature = sign_envelope($delayed_event, $key);
my $delayed_calls = 0;
my $delayed = deliver_event('https://hooks.example.net/orm', $delayed_event, $delayed_signature, $key,
    resolved_addresses => ['8.8.8.8'], socket_factory => sub { $delayed_calls++; return undef; });
is_deeply($delayed, { outcome => 'retryable', code => 'connect_failed' }, 'accepts an event during the bounded retry window');
is($delayed_calls, 1, 'retry-window event reaches the pinned transport');

my $factory_calls = 0;
my $unsafe = deliver_event('https://hooks.example.net/orm', $event, $signature, $key,
    resolved_addresses => ['8.8.8.8', '127.0.0.1'],
    socket_factory => sub { $factory_calls++; return undef; });
is_deeply($unsafe, { outcome => 'permanent', code => 'unsafe_address' }, 'fails closed on any unsafe DNS answer');
is($factory_calls, 0, 'does not connect when DNS contains a private answer');

done_testing();
