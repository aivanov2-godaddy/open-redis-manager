package Orm::Broker::Handler;
use strict;
use warnings;
use JSON::PP ();
use Orm::Broker::Protocol qw(parse_request encode_response);

sub handle_frame {
    my ($class, $frame, $peer_uid, $resolver) = @_;
    my $request = parse_request($frame);
    my $response;
    if (!$request) {
        $response = { error => 'invalid_request', success => JSON::PP::false, version => 1 };
    } else {
        my $username = defined($resolver) ? eval { $resolver->resolve_uid($peer_uid) } : undef;
        if (defined($username)) {
            $response = { success => JSON::PP::true, username => $username, version => 1 };
        } else {
            $response = { error => 'not_authorized', success => JSON::PP::false, version => 1 };
        }
    }

    return encode_response($response);
}

1;
