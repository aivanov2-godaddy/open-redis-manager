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
    sub resolve_name {
        my ($self, $name) = @_;
        return undef if !defined($name) || $name !~ /\Aacct([0-9]{2})\z/ || $1 > 35;
        return { name => $name, uid => 10000 + $1, gid => 1000 };
    }

    package Local::FleetManager;
    our @STATUS_CALLS;
    our @CONTROL_CALLS;
    our %CONTROL_STATES;
    sub new { return bless {}, $_[0]; }
    sub status {
        my ($self, $account) = @_;
        push @STATUS_CALLS, $account->{name};
        return { success => 1, state => $CONTROL_STATES{$account->{name}} }
            if exists $CONTROL_STATES{$account->{name}};
        return { success => 0, error => 'instance_unavailable' } if $account->{name} eq 'acct31';
        return { success => 1, state => 'not_configured' } if $account->{name} eq 'acct32';
        return { success => 1, state => 'running' } if $account->{name} eq 'acct01';
        return { success => 1, state => 'stopped' };
    }
    sub start { return _control($_[0], $_[1], 'start', 'running'); }
    sub stop { return _control($_[0], $_[1], 'stop', 'stopped'); }
    sub restart { return _control($_[0], $_[1], 'restart', 'starting'); }
    sub _control {
        my ($self, $account, $action, $state) = @_;
        push @CONTROL_CALLS, [$action, $account->{name}];
        $CONTROL_STATES{$account->{name}} = $state;
        return { success => 1, state => $state };
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

my @audit;
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
    audit => sub { push @audit, [@_]; },
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
ok(!$inventory->page(36)->{success}, 'reject out-of-range page offsets');
ok(!$inventory->page(-1)->{success}, 'reject negative page offsets');
my $request = '{"offset":0,"operation":"fleet.list","version":1}' . "\n";
is(parse_request($request)->{operation}, 'fleet.list', 'accept the fixed fleet-list request');
ok(!parse_request('{"offset":0,"operation":"fleet.list","scope":"all","version":1}' . "\n"),
    'reject fleet requests with extra scope or identity fields');
my $root_response = Orm::Broker::Handler->handle_frame($request, 0, undef, undef, $inventory);
like($root_response, qr/"success":true/, 'allow root peers to read the scoped fleet inventory');
my $account_response = Orm::Broker::Handler->handle_frame($request, 10001, undef, undef, $inventory);
like($account_response, qr/"error":"not_authorized"/, 'deny non-root peers from reading the fleet inventory');

my $controlRequest = '{"action":"start","operation":"fleet.control","username":"acct01","version":1}' . "\n";
is(parse_request($controlRequest)->{operation}, 'fleet.control', 'accept the fixed root fleet-control request');
ok(!parse_request('{"action":"start","operation":"fleet.control","unit":"other","username":"acct01","version":1}' . "\n"),
    'reject fleet control requests with an arbitrary unit field');
my $controlResponse = $inventory->control('acct01', 'stop');
ok($controlResponse->{success} && $controlResponse->{username} eq 'acct01'
    && $controlResponse->{action} eq 'stop' && $controlResponse->{state} eq 'stopped',
    'control only the validated target account through a fixed action method');
is_deeply($Local::FleetManager::CONTROL_CALLS[-1], ['stop', 'acct01'], 'never pass a caller-selected unit to the manager');
is_deeply($audit[-1], [0, 'acct01', 'stop', 'success', 'stopped'], 'audit actor, account, action, result, and state without secrets');
is($inventory->control('acct32', 'start')->{error}, 'not_configured', 'do not start an account without an ORM manifest');
is($inventory->control('acct99', 'start')->{error}, 'account_unavailable', 'reject accounts absent from trusted system lookup');
is($inventory->control('../root', 'start')->{error}, 'invalid_request', 'reject malformed account names before lookup');
is($inventory->control('acct01', 'status')->{error}, 'invalid_request', 'reject actions outside start, stop, and restart');
my $calls_before_denial = scalar @Local::FleetManager::CONTROL_CALLS;
my $nonRootControl = Orm::Broker::Handler->handle_frame($controlRequest, 10001, undef, undef, $inventory);
like($nonRootControl, qr/"error":"not_authorized"/, 'deny non-root peers before target lookup and control');
is_deeply($audit[-1], [10001, 'acct01', 'start', 'not_authorized', 'unavailable'],
    'audit denied control attempts using the kernel peer UID');
is(scalar @Local::FleetManager::CONTROL_CALLS, $calls_before_denial, 'non-root control never reaches service methods');
$Local::FleetManager::CONTROL_STATES{acct01} = 'stopped';
my $calls_before_stopped_restart = scalar @Local::FleetManager::CONTROL_CALLS;
is($inventory->control('acct01', 'restart')->{error}, 'instance_unavailable', 'reject restart for a stopped instance');
is(scalar @Local::FleetManager::CONTROL_CALLS, $calls_before_stopped_restart, 'do not invoke restart for a stopped instance');
$Local::FleetManager::CONTROL_STATES{acct01} = 'running';
my $rootControl = Orm::Broker::Handler->handle_frame($controlRequest, 0, undef, undef, $inventory);
like($rootControl, qr/"success":true/, 'allow root peers to use the fixed fleet-control operation');
like($rootControl, qr/"audit_logged":true/, 'report whether the action outcome was recorded');
my $noAuditInventory = Orm::Broker::FleetInventory->new(
    resolver => Local::FleetResolver->new(),
    instance_manager => Local::FleetManager->new(),
    audit => sub { die "audit unavailable"; },
);
my $noAuditControl = $noAuditInventory->control('acct01', 'restart');
ok($noAuditControl->{success} && !$noAuditControl->{audit_logged}
    && $noAuditControl->{state} eq 'starting',
    'report the service outcome separately when audit delivery cannot be confirmed');

chmod(0777, $instance_root) or die "weaken instance root: $!";
ok(!$inventory->page(0)->{success}, 'fail closed when the metadata root is writable by others');

done_testing();
