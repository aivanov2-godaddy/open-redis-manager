use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use lib 'src';
use Orm::Broker::FleetInventory;
use Orm::Broker::Handler;
use Orm::Broker::Protocol qw(parse_request);

plan skip_all => 'fleet inventory filesystem permission tests require Linux mode semantics' if $^O ne 'linux';

{
    package Local::FleetResolver;
    sub new { return bless {}, $_[0]; }
    sub resolve_account {
        my ($self, $uid) = @_;
        return undef if !defined($uid) || $uid < 10001 || $uid > 10036;
        return { name => sprintf('acct%02d', $uid - 10000), uid => $uid, gid => 1000 };
    }

    package Local::FleetManager;
    our @STATUS_CALLS;
    sub new { return bless {}, $_[0]; }
    sub status {
        my ($self, $account) = @_;
        push @STATUS_CALLS, $account->{name};
        return { success => 0, error => 'instance_unavailable' } if $account->{name} eq 'acct31';
        return { success => 1, state => 'not_configured' } if $account->{name} eq 'acct32';
        return { success => 1, state => 'running' } if $account->{name} eq 'acct01';
        return { success => 1, state => 'stopped' };
    }
}

my $tmp = tempdir(CLEANUP => 1);
my $instance_root = "$tmp/instances";
make_path($instance_root);
chmod(0755, $instance_root) or die "chmod instance root: $!";
for my $number (1 .. 35) {
    my $name = sprintf('acct%02d', $number);
    make_path("$instance_root/$name");
    chmod(0750, "$instance_root/$name") or die "chmod account directory: $!";
}
make_path("$instance_root/invalid!");
chmod(0750, "$instance_root/invalid!") or die "chmod invalid account directory: $!";
my $has_symlink = symlink("$tmp/missing", "$instance_root/acct36");

my $inventory = Orm::Broker::FleetInventory->new(
    instance_root => $instance_root,
    expected_owner_uid => $<,
    resolver => Local::FleetResolver->new(),
    instance_manager => Local::FleetManager->new(),
    lookup_name => sub {
        my ($name) = @_;
        return undef if $name !~ /\Aacct([0-9]{2})\z/;
        return { uid => 10000 + $1 };
    },
);

my $first = $inventory->page(0);
ok($first->{success}, 'return a successful fleet page');
is(scalar @Local::FleetManager::STATUS_CALLS, 4, 'query service state only for the bounded page');
SKIP: {
    skip 'filesystem does not allow symlink fixtures', 1 if !$has_symlink;
    ok(-l "$instance_root/acct36", 'create an account metadata symlink fixture');
}
is($first->{total}, 35, 'skip malformed account directories but include configured account directories');
is(scalar @{$first->{entries}}, 4, 'bound fleet responses to a four-account page');
is($first->{entries}[0]->{username}, 'acct01', 'sort fleet entries by account name');
is($first->{entries}[0]->{state}, 'running', 'report normalized running state');
is($first->{entries}[3]->{username}, 'acct04', 'first page ends at the fixed page size');
is($first->{entries}[4], undef, 'do not include entries beyond the response page');

my $second = $inventory->page(4);
is($second->{total}, 35, 'report the same total on later pages');
is(scalar @{$second->{entries}}, 4, 'return a full intermediate page');
is($second->{entries}[0]->{username}, 'acct05', 'sort entries consistently across pages');
my $unhealthy = $inventory->page(28);
is($unhealthy->{entries}[2]->{username}, 'acct31', 'include unhealthy account metadata');
is($unhealthy->{entries}[2]->{state}, 'unhealthy', 'normalize unverifiable service state');
is($unhealthy->{entries}[3]->{username}, 'acct32', 'include incomplete account directories for repair visibility');
is($unhealthy->{entries}[3]->{state}, 'unhealthy', 'mark incomplete metadata unhealthy');
my $last = $inventory->page(32);
is(scalar @{$last->{entries}}, 3, 'return only remaining entries on the last page');
is($last->{entries}[1]->{username}, 'acct34', 'retain sorted account names on the final page');
is($last->{entries}[1]->{state}, 'stopped', 'retain a verifiable stopped service state');
ok(!$inventory->page(35)->{success}, 'reject out-of-range page offsets');
ok(!$inventory->page(-1)->{success}, 'reject negative page offsets');
my $request = '{"offset":0,"operation":"fleet.list","version":1}' . "\n";
is(parse_request($request)->{operation}, 'fleet.list', 'accept the fixed fleet-list request');
ok(!parse_request('{"offset":0,"operation":"fleet.list","scope":"all","version":1}' . "\n"),
    'reject fleet requests with extra scope or identity fields');
my $root_response = Orm::Broker::Handler->handle_frame($request, 0, undef, undef, $inventory);
like($root_response, qr/"success":true/, 'allow root peers to read the scoped fleet inventory');
my $account_response = Orm::Broker::Handler->handle_frame($request, 10001, undef, undef, $inventory);
like($account_response, qr/"error":"not_authorized"/, 'deny non-root peers from reading the fleet inventory');

chmod(0777, $instance_root) or die "weaken instance root: $!";
ok(!$inventory->page(0)->{success}, 'fail closed when the metadata root is writable by others');

done_testing();
