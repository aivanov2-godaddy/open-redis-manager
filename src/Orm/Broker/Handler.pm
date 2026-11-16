package Orm::Broker::Handler;
use strict;
use warnings;
use JSON::PP ();
use Orm::Broker::Protocol qw(parse_request encode_response);
use Orm::Broker::FleetInventory;

sub _not_authorized {
    return { error => 'not_authorized', success => JSON::PP::false, version => 1 };
}

sub handle_frame {
    my ($class, $frame, $peer_uid, $resolver, $instance_manager, $fleet_inventory) = @_;
    my $request = parse_request($frame);
    my $response;
    if (!$request) {
        $response = { error => 'invalid_request', success => JSON::PP::false, version => 1 };
    } else {
        if ($request->{operation} eq 'fleet.list') {
            if ($peer_uid != 0) {
                $response = _not_authorized();
            } elsif (!defined($fleet_inventory)) {
                $response = { error => 'operation_failed', success => JSON::PP::false, version => 1 };
            } else {
                my $fleet_response = eval { $fleet_inventory->page($request->{offset}) };
                $response = ref($fleet_response) eq 'HASH' ? $fleet_response
                    : { error => 'operation_failed', success => JSON::PP::false, version => 1 };
            }
        }
        if ($request->{operation} eq 'fleet.control') {
            if ($peer_uid != 0) {
                eval { $fleet_inventory->audit_denial($peer_uid, $request->{username}, $request->{action}) }
                    if defined($fleet_inventory) && eval { $fleet_inventory->can('audit_denial') };
                $response = _not_authorized();
            } elsif (!defined($fleet_inventory)) {
                $response = { error => 'operation_failed', success => JSON::PP::false, version => 1 };
            } else {
                my $control_response = eval {
                    $fleet_inventory->control($request->{username}, $request->{action})
                };
                $response = ref($control_response) eq 'HASH' ? $control_response
                    : { error => 'operation_failed', success => JSON::PP::false, version => 1 };
            }
        }
        if ($request->{operation} eq 'fleet.backup.create' || $request->{operation} eq 'fleet.backup.restore') {
            my $action = $request->{operation} eq 'fleet.backup.create' ? 'backup.create' : 'backup.restore';
            if ($peer_uid != 0) {
                eval { $fleet_inventory->audit_denial($peer_uid, $request->{username}, $action) }
                    if defined($fleet_inventory) && eval { $fleet_inventory->can('audit_denial') };
                $response = _not_authorized();
            } elsif (!defined($fleet_inventory)) {
                $response = { error => 'operation_failed', success => JSON::PP::false, version => 1 };
            } else {
                my $backup_response = eval {
                    $fleet_inventory->backup($request->{username}, $action, $request->{backup_id})
                };
                $response = ref($backup_response) eq 'HASH' ? $backup_response
                    : { error => 'operation_failed', success => JSON::PP::false, version => 1 };
            }
        }

        my $account = defined($resolver) ? eval { $resolver->resolve_account($peer_uid) } : undef;
        if (defined($response)) {
            # Root-only fleet operations are handled above and never fall through to account operations.
        } elsif (ref($account) eq 'HASH' && $request->{operation} eq 'identity') {
            $response = { success => JSON::PP::true, username => $account->{name}, version => 1 };
        } elsif (ref($account) eq 'HASH' && defined($instance_manager)) {
            $response = eval {
                $instance_manager->dispatch(
                    $request->{operation}, $account, $request->{preset},
                    $request->{operation} eq 'instance.configure' ? {
                        maxclients => $request->{maxclients},
                        maxmemory_policy => $request->{maxmemory_policy},
                        memory_mib => $request->{memory_mib},
                        timeout => $request->{timeout},
                    } : undef,
                    $request->{operation} eq 'backup.restore' ? $request->{backup_id} : undef,
                    $request->{operation} eq 'metrics.history' ? $request->{range} : undef,
                )
            };
            $response = { error => 'operation_failed', success => JSON::PP::false, version => 1 }
                if ref($response) ne 'HASH';
        } else {
            $response = { error => 'not_authorized', success => JSON::PP::false, version => 1 };
        }
    }

    return encode_response($response);
}

1;
