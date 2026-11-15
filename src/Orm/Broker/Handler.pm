package Orm::Broker::Handler;
use strict;
use warnings;
use JSON::PP ();
use Orm::Broker::Protocol qw(parse_request encode_response);

sub handle_frame {
    my ($class, $frame, $peer_uid, $resolver, $instance_manager) = @_;
    my $request = parse_request($frame);
    my $response;
    if (!$request) {
        $response = { error => 'invalid_request', success => JSON::PP::false, version => 1 };
    } else {
        my $account = defined($resolver) ? eval { $resolver->resolve_account($peer_uid) } : undef;
        if (ref($account) eq 'HASH' && $request->{operation} eq 'identity') {
            $response = { success => JSON::PP::true, username => $account->{name}, version => 1 };
        } elsif (ref($account) eq 'HASH' && defined($instance_manager)) {
            $response = eval { $instance_manager->dispatch($request->{operation}, $account) };
            $response = { error => 'operation_failed', success => JSON::PP::false, version => 1 }
                if ref($response) ne 'HASH';
        } else {
            $response = { error => 'not_authorized', success => JSON::PP::false, version => 1 };
        }
    }

    return encode_response($response);
}

1;
