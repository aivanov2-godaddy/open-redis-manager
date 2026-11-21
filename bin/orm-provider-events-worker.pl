#!/usr/bin/perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Sys::Syslog qw(:standard :macros);
use Orm::Broker::ProviderEventConfig;
use Orm::Broker::ProviderEventQueue;
use Orm::Broker::ProviderEventTransport qw(deliver_event);

exit 77 if $> != 0;
openlog('orm-provider-events', 'pid', 'authpriv');
my $config_store = Orm::Broker::ProviderEventConfig->new();
my ($config, $config_state) = $config_store->load();
if (!defined($config)) {
    syslog(LOG_ERR, 'provider_event_worker state=config_error');
    closelog();
    exit 1;
}
if (!$config->{enabled}) {
    closelog();
    exit 0;
}

my $queue = Orm::Broker::ProviderEventQueue->new();
my $key = pack('H*', $config->{signing_key});
for my $iteration (1 .. 16) {
    my ($claim, $claim_state) = $queue->claim_due();
    if (!defined($claim)) {
        if ($claim_state eq 'empty') {
            closelog();
            exit 0;
        }
        syslog(LOG_ERR, 'provider_event_worker state=queue_error');
        closelog();
        exit 1;
    }
    my $delivery = deliver_event($config->{destination}, $claim->{event}, $claim->{signature}, $key);
    if (ref($delivery) ne 'HASH' || !defined($delivery->{outcome})
        || $delivery->{outcome} !~ /\A(?:delivered|retryable|permanent)\z/) {
        $delivery = { outcome => 'retryable' };
    }
    my ($finished, $finish_state) = $queue->finish_attempt(
        $claim->{id}, $delivery->{outcome}, $delivery->{http_status});
    if (!$finished) {
        syslog(LOG_ERR, 'provider_event_worker state=record_error');
        closelog();
        exit 1;
    }
    my $http_status = defined($delivery->{http_status}) ? $delivery->{http_status} : 0;
    syslog(LOG_INFO, 'provider_event_delivery state=%s code=%s http_status=%d',
        $finish_state =~ /\A(?:pending|sending|delivered|failed|expired)\z/ ? $finish_state : 'failed',
        defined($delivery->{code}) && $delivery->{code} =~ /\A[a-z_]{1,40}\z/ ? $delivery->{code} : 'unknown',
        $http_status);
}
closelog();
exit 0;
