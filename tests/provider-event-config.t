use strict;
use warnings;
use Test::More;
use JSON::PP ();
use lib 'src';
use Orm::Broker::ProviderEventConfig;

my $disabled = Orm::Broker::ProviderEventConfig::_normalize({
    version => 1, enabled => JSON::PP::false, destination => '', signing_key => '',
});
is_deeply($disabled, Orm::Broker::ProviderEventConfig::defaults(), 'configuration defaults to disabled');

my $enabled = Orm::Broker::ProviderEventConfig::_normalize({
    version => 1, enabled => JSON::PP::true, destination => 'https://hooks.example.net/orm',
    signing_key => 'a' x 64,
});
ok($enabled, 'accepts an enabled configuration with a URL and 256-bit key');
my $view = Orm::Broker::ProviderEventConfig->new()->public_view($enabled);
is_deeply($view, { enabled => JSON::PP::true, destination => 'https://hooks.example.net/orm', key_configured => JSON::PP::true },
    'public view omits signing material');
ok(!exists($view->{signing_key}), 'never exposes the signing key in the public view');

ok(!Orm::Broker::ProviderEventConfig::_normalize({
    version => 1, enabled => JSON::PP::true, destination => '', signing_key => 'a' x 64,
}), 'rejects enablement without a destination');
ok(!Orm::Broker::ProviderEventConfig::_normalize({
    version => 1, enabled => JSON::PP::true, destination => 'https://hooks.example.net', signing_key => '',
}), 'rejects enablement without a key');
ok(!Orm::Broker::ProviderEventConfig::_normalize({
    version => 1, enabled => JSON::PP::false, destination => 'http://hooks.example.net', signing_key => '',
}), 'rejects non-HTTPS saved destinations');
ok(!Orm::Broker::ProviderEventConfig::_normalize({
    version => 1, enabled => JSON::PP::false, destination => '', signing_key => '', extra => 'data',
}), 'rejects unknown configuration properties');

done_testing();
