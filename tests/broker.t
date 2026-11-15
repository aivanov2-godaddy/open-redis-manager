use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use Fcntl qw(:mode);
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);
use lib 'src';
use Orm::Broker::AccountResolver;
use Orm::Broker::Handler;
use Orm::Broker::PeerCredentials;
use Orm::Broker::Protocol qw(parse_request encode_response max_frame_bytes);

my $request = '{"operation":"identity","version":1}' . "\n";
is(parse_request($request)->{operation}, 'identity', 'accept the one canonical identity request');
for my $invalid (
    '', '{}', $request . "\n", '{"version":1,"operation":"identity"}' . "\n",
    '{"operation":"identity","version":2}' . "\n", ('x' x (max_frame_bytes() + 1)),
) {
    ok(!parse_request($invalid), 'reject a non-canonical or oversized request');
}
like(encode_response({ success => JSON::PP::true, version => 1 }), qr/\n\z/, 'responses end in one line feed');
ok(!encode_response([]), 'response encoder rejects non-object payloads');

my $tmp = tempdir(CLEANUP => 1);
my $account_root = "$tmp/accounts";
make_path($account_root);
chmod(0755, $account_root) or die "chmod account root: $!";
my $account_file = "$account_root/ormtest";
open(my $file, '>', $account_file) or die "create account fixture: $!";
print {$file} "SHELL=/bin/bash\n";
close($file) or die "close account fixture: $!";
chmod(0644, $account_file) or die "chmod account fixture: $!";

my $resolver = Orm::Broker::AccountResolver->new(
    account_root => $account_root,
    expected_owner_uid => $<,
    lookup => sub { return { name => 'ormtest', uid => $_[0] }; },
);
is($resolver->resolve_uid(43210), 'ormtest', 'resolve a mapped UID through a trusted account record');
ok(!defined($resolver->resolve_uid(0)), 'reject root identity');
ok(!defined($resolver->resolve_uid(undef)), 'reject missing UID');

chmod(0666, $account_file) or die "make writable account fixture: $!";
ok(!defined($resolver->resolve_uid(43210)), 'reject group/world-writable account file');
chmod(0644, $account_file) or die "restore account fixture mode: $!";
unlink($account_file) or die "remove account fixture: $!";
symlink("$tmp/outside", $account_file) or die "create symlink fixture: $!";
ok(!defined($resolver->resolve_uid(43210)), 'reject a symlink account file');
unlink($account_file) or die "remove symlink fixture: $!";
open($file, '>', $account_file) or die "recreate account fixture: $!";
print {$file} ('x' x 1_048_577);
close($file) or die "close oversized fixture: $!";
chmod(0644, $account_file) or die "chmod oversized fixture: $!";
ok(!defined($resolver->resolve_uid(43210)), 'reject oversized account file');

my $unsafe_resolver = Orm::Broker::AccountResolver->new(
    account_root => $account_root,
    expected_owner_uid => $<,
    lookup => sub { return { name => '../root', uid => $_[0] }; },
);
ok(!defined($unsafe_resolver->resolve_uid(43210)), 'reject unsafe mapped account names');

my $denied = Orm::Broker::Handler->handle_frame($request, 0, $resolver);
like($denied, qr/"success":false/, 'handler denies root peer identity');
my $invalid = Orm::Broker::Handler->handle_frame('{}' . "\n", 43210, $resolver);
like($invalid, qr/"error":"invalid_request"/, 'handler returns a generic invalid-request response');

socketpair(my $left, my $right, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die "socketpair: $!";
is(Orm::Broker::PeerCredentials->uid_from_socket($left), $<, 'read peer UID from Linux socket credentials');
close($left);
close($right);

done_testing();
