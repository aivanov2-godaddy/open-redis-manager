package Orm::Broker::Handler;
use strict;
use warnings;
use JSON::PP ();
use Orm::Broker::Protocol qw(parse_request encode_response);
use Orm::Broker::FleetInventory;

sub _not_authorized {
    return { error => 'not_authorized', success => JSON::PP::false, version => 1 };
}

sub _emit_operation_event {
    my ($emitter, $request, $response, $instance_manager, $account) = @_;
    return if !ref($emitter) || !eval { $emitter->can('emit') }
        || ref($request) ne 'HASH' || ref($response) ne 'HASH';
    my %events = (
        'instance.provision' => 'instance.provisioned',
        'instance.start' => 'instance.started',
        'instance.stop' => 'instance.stopped',
        'instance.restart' => 'instance.restarted',
    );
    my $operation = $request->{operation} // '';
    my $event = $events{$operation};
    return if !defined($event);
    if ($response->{success}) {
        my $backend = $response->{backend} // '';
        return if $backend !~ /\A(?:redis|valkey)\z/;
        eval { $emitter->emit($event, { backend => $backend }); };
        return;
    }
    return if ($response->{error} // '') ne 'service_failed';
    my $state = eval { $instance_manager->status($account) };
    return if ref($state) ne 'HASH' || ($state->{backend} // '') !~ /\A(?:redis|valkey)\z/;
    eval { $emitter->emit('instance.failed', {
        backend => $state->{backend}, operation => $operation, reason_code => 'service_failed',
    }); };
}

sub _provider_event_admin_response {
    my ($request, $config_store, $queue) = @_;
    return { error => 'operation_failed', success => JSON::PP::false, version => 1 }
        if !ref($config_store) || !ref($queue);
    if ($request->{operation} eq 'provider.events.status') {
        my ($config) = $config_store->load();
        return { error => 'operation_failed', success => JSON::PP::false, version => 1 }
            if ref($config) ne 'HASH';
        my $public = $config_store->public_view($config);
        return { %$public, success => JSON::PP::true, version => 1 } if ref($public) eq 'HASH';
    } elsif ($request->{operation} eq 'provider.events.queue.status') {
        my ($status) = $queue->status();
        return { %$status, success => JSON::PP::true, version => 1 } if ref($status) eq 'HASH';
    } elsif ($request->{operation} eq 'provider.events.configure') {
        my ($saved) = $config_store->save(
            $request->{destination}, $request->{enabled} ? '1' : '0', $request->{rotate_key} ? '1' : '0',
        );
        return { error => 'invalid_destination', success => JSON::PP::false, version => 1 }
            if ref($saved) ne 'HASH';
        my $public = $config_store->public_view($saved);
        return { %$public, key_rotated => $saved->{key_rotated} ? JSON::PP::true : JSON::PP::false,
            success => JSON::PP::true, version => 1 } if ref($public) eq 'HASH';
    }
    return { error => 'operation_failed', success => JSON::PP::false, version => 1 };
}

sub handle_frame {
    my ($class, $frame, $peer_uid, $resolver, $instance_manager, $fleet_inventory,
        $provider_event_config, $provider_event_queue, $event_emitter) = @_;
    my $request = parse_request($frame);
    my $response;
    if (!$request) {
        $response = { error => 'invalid_request', success => JSON::PP::false, version => 1 };
    } else {
        if ($request->{operation} eq 'provider.backend.selected') {
            if ($peer_uid != 0) {
                $response = _not_authorized();
            } else {
                my ($queued) = ref($event_emitter) && eval { $event_emitter->can('emit') }
                    ? eval { $event_emitter->emit('backend.selected', { backend => $request->{backend} }) }
                    : (0);
                $response = { queued => $queued ? JSON::PP::true : JSON::PP::false,
                    success => JSON::PP::true, version => 1 };
            }
        }
        if ($request->{operation} =~ /\Aprovider\.events\./) {
            $response = $peer_uid != 0 ? _not_authorized()
                : _provider_event_admin_response($request, $provider_event_config, $provider_event_queue);
        }
        if ($request->{operation} eq 'provider.resellers') {
            if ($peer_uid != 0) {
                $response = _not_authorized();
            } elsif (!defined($instance_manager)) {
                $response = { error => 'operation_failed', success => JSON::PP::false, version => 1 };
            } else {
                my $summary = eval { $instance_manager->reseller_summary() };
                $response = ref($summary) eq 'HASH' ? $summary
                    : { error => 'operation_failed', success => JSON::PP::false, version => 1 };
            }
        }
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
        if ($request->{operation} eq 'fleet.summary') {
            if ($peer_uid != 0) {
                $response = _not_authorized();
            } elsif (!defined($fleet_inventory)) {
                $response = { error => 'operation_failed', success => JSON::PP::false, version => 1 };
            } else {
                my $summary = eval { $fleet_inventory->summary() };
                $response = ref($summary) eq 'HASH' ? $summary
                    : { error => 'operation_failed', success => JSON::PP::false, version => 1 };
            }
        }
        if ($request->{operation} eq 'fleet.auto_provision') {
            if ($peer_uid != 0) {
                eval { $fleet_inventory->audit_denial($peer_uid, $request->{username}, 'auto_provision') }
                    if defined($fleet_inventory) && eval { $fleet_inventory->can('audit_denial') };
                $response = _not_authorized();
            } elsif (!defined($fleet_inventory)) {
                $response = { error => 'operation_failed', success => JSON::PP::false, version => 1 };
            } else {
                my $provision_response = eval { $fleet_inventory->auto_provision($request->{username}) };
                $response = ref($provision_response) eq 'HASH' ? $provision_response
                    : { error => 'operation_failed', success => JSON::PP::false, version => 1 };
            }
        }
        if ($request->{operation} eq 'fleet.diagnostics') {
            my $action = 'diagnostics.' . $request->{command_class};
            if ($peer_uid != 0) {
                eval { $fleet_inventory->audit_denial($peer_uid, $request->{username}, $action) }
                    if defined($fleet_inventory) && eval { $fleet_inventory->can('audit_denial') };
                $response = _not_authorized();
            } elsif (!defined($fleet_inventory)) {
                $response = { error => 'operation_failed', success => JSON::PP::false, version => 1 };
            } else {
                my $diagnostics_response = eval {
                    $fleet_inventory->diagnostics($request->{username}, $request->{command_class})
                };
                $response = ref($diagnostics_response) eq 'HASH' ? $diagnostics_response
                    : { error => 'operation_failed', success => JSON::PP::false, version => 1 };
            }
        }
        if ($request->{operation} eq 'fleet.recovery.scan'
            || $request->{operation} eq 'fleet.recovery.repair') {
            my $action = $request->{operation} eq 'fleet.recovery.scan' ? 'recovery.scan'
                : $request->{repair} eq 'config_rebuild' ? 'recovery.config_rebuild'
                : $request->{repair} eq 'config_reset' ? 'recovery.config_reset' : 'recovery.start';
            if ($peer_uid != 0) {
                eval { $fleet_inventory->audit_denial($peer_uid, $request->{username}, $action) }
                    if defined($fleet_inventory) && eval { $fleet_inventory->can('audit_denial') };
                $response = _not_authorized();
            } elsif (!defined($fleet_inventory)) {
                $response = { error => 'operation_failed', success => JSON::PP::false, version => 1 };
            } else {
                my $recovery_response = eval {
                    $request->{operation} eq 'fleet.recovery.scan'
                        ? $fleet_inventory->recovery_scan($request->{username})
                        : $fleet_inventory->recovery_repair($request->{username}, $request->{repair})
                };
                $response = ref($recovery_response) eq 'HASH' ? $recovery_response
                    : { error => 'operation_failed', success => JSON::PP::false, version => 1 };
            }
        }
        if ($request->{operation} eq 'fleet.auth.rotate') {
            if ($peer_uid != 0) {
                eval { $fleet_inventory->audit_denial($peer_uid, $request->{username}, 'auth.rotate') }
                    if defined($fleet_inventory) && eval { $fleet_inventory->can('audit_denial') };
                $response = _not_authorized();
            } elsif (!defined($fleet_inventory)) {
                $response = { error => 'operation_failed', success => JSON::PP::false, version => 1 };
            } else {
                my $rotation_response = eval { $fleet_inventory->rotate_auth($request->{username}) };
                $response = ref($rotation_response) eq 'HASH' ? $rotation_response
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
        if ($request->{operation} eq 'fleet.backup.batch.create' || $request->{operation} eq 'fleet.backup.batch.restore') {
            my $action = $request->{operation} eq 'fleet.backup.batch.create' ? 'create' : 'restore';
            if ($peer_uid != 0) {
                if (defined($fleet_inventory) && eval { $fleet_inventory->can('audit_denial') }) {
                    for my $target (@{$request->{targets}}) {
                        eval { $fleet_inventory->audit_denial($peer_uid, $target->{username}, 'backup.batch.' . $action) };
                    }
                }
                $response = _not_authorized();
            } elsif (!defined($fleet_inventory)) {
                $response = { error => 'operation_failed', success => JSON::PP::false, version => 1 };
            } else {
                my $batch_response = eval {
                    $fleet_inventory->backup_batch($action, $request->{targets}, $request->{rate_limited_targets})
                };
                $response = ref($batch_response) eq 'HASH' ? $batch_response
                    : { error => 'operation_failed', success => JSON::PP::false, version => 1 };
            }
        }
        if ($request->{operation} eq 'fleet.migrate') {
            if ($peer_uid != 0) {
                eval { $fleet_inventory->audit_denial($peer_uid, $request->{username}, 'migration.to-valkey') }
                    if defined($fleet_inventory) && eval { $fleet_inventory->can('audit_denial') };
                $response = _not_authorized();
            } elsif (!defined($fleet_inventory)) {
                $response = { error => 'operation_failed', success => JSON::PP::false, version => 1 };
            } else {
                my $migration_response = eval {
                    $fleet_inventory->migrate($request->{username}, $request->{target_backend}, $request->{writes_quiesced})
                };
                $response = ref($migration_response) eq 'HASH' ? $migration_response
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
            _emit_operation_event($event_emitter, $request, $response, $instance_manager, $account);
            eval {
                $instance_manager->audit_account_operation(
                    $peer_uid, $account, $request->{operation}, $response,
                ) if eval { $instance_manager->can('audit_account_operation') };
            };
        } else {
            $response = { error => 'not_authorized', success => JSON::PP::false, version => 1 };
        }
    }

    return encode_response($response);
}

1;
