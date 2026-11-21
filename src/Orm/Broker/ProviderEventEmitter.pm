package Orm::Broker::ProviderEventEmitter;
use strict;
use warnings;
use Orm::Broker::ProviderEvents qw(build_envelope sign_envelope);

sub new {
    my ($class, %args) = @_;
    return bless {
        config_store => $args{config_store},
        queue => $args{queue},
        event_id_generator => $args{event_id_generator},
    }, $class;
}

sub emit {
    my ($self, $type, $metadata, $now) = @_;
    return (0, 'unavailable') if !ref($self->{config_store}) || !ref($self->{queue})
        || !eval { $self->{config_store}->can('load') }
        || !eval { $self->{queue}->can('enqueue') };
    my ($queued, $state);
    eval {
        my ($config) = $self->{config_store}->load();
        if (ref($config) ne 'HASH' || !$config->{enabled}) {
            ($queued, $state) = (0, 'disabled');
        } else {
            my $key = pack('H*', $config->{signing_key});
            my %options = defined($now) ? (now => $now) : ();
            if (ref($self->{event_id_generator}) eq 'CODE') {
                $options{event_id} = eval { $self->{event_id_generator}->() };
            }
            my ($event, $error) = build_envelope($type, $metadata, %options);
            if (!defined($event)) {
                ($queued, $state) = (0, $error // 'invalid_event');
            } else {
                my $signature = sign_envelope($event, $key);
                if (!defined($signature)) {
                    ($queued, $state) = (0, 'sign_failed');
                } else {
                    ($queued, $state) = $self->{queue}->enqueue($event, $signature, $key, $now);
                }
            }
        }
    };
    return (0, 'emit_failed') if $@;
    return ($queued ? 1 : 0, $state // 'emit_failed');
}

1;
