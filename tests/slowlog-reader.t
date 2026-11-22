use strict;
use warnings;
use Test::More;
use lib 'src';
use Orm::Broker::InstanceManager;
use Orm::Broker::SlowLogReader;

sub resp_int { return ':' . $_[0] . "\r\n"; }
sub resp_bulk {
    my ($value) = @_;
    return '$' . length($value) . "\r\n" . $value . "\r\n";
}
sub resp_entry {
    my (%args) = @_;
    my @argv = @{$args{argv} // ['GET', 'secret-value']};
    my $fields = $args{redis_810} ? 7 : 6;
    my $reply = '*' . $fields . "\r\n"
        . resp_int($args{id} // 1)
        . resp_int($args{timestamp} // 1700000000)
        . resp_int($args{duration} // 1234)
        . '*' . scalar(@argv) . "\r\n"
        . join('', map { resp_bulk($_) } @argv)
        . resp_bulk($args{address} // '192.0.2.44:6390')
        . ($args{null_name} ? '$-1' . "\r\n" : resp_bulk($args{name} // 'app-private-name'));
    $reply .= resp_int($args{total_arguments} // scalar(@argv)) if $args{redis_810};
    return $reply;
}
sub parse_reply {
    my ($reply) = @_;
    open(my $handle, '<', \$reply) or die "cannot open fixture: $!";
    binmode($handle);
    return Orm::Broker::SlowLogReader->parse_handle($handle);
}

my $legacy = parse_reply('*1' . "\r\n" . resp_entry(argv => ['HGET', 'secret-key']));
is_deeply($legacy, {
    entries => [{ command => 'hget', duration_usec => 1234, timestamp => 1700000000 }],
    truncated => 0,
}, 'normalize a Redis 6.2 / Valkey 7.2 six-field entry');
my $newer = parse_reply('*1' . "\r\n" . resp_entry(
    redis_810 => 1, argv => ['MSET', 'private-key', 'private-value'], total_arguments => 3,
    null_name => 1,
));
is_deeply($newer, {
    entries => [{ command => 'mset', duration_usec => 1234, timestamp => 1700000000 }],
    truncated => 0,
}, 'normalize Redis 8.10 seven-field entries and a nullable client name');
my $encoded = do { require JSON::PP; JSON::PP->new->canonical->encode($legacy) };
unlike($encoded, qr/secret-key|private-key|private-value|192\.0\.2\.44|app-private-name/,
    'never return command arguments or client metadata');
my @replyCalls;
my $wireReply = '*1' . "\r\n" . resp_entry(argv => ['SET', 'private-key', 'private-value']);
my $manager = Orm::Broker::InstanceManager->new(slowlog_reply_call => sub {
    push @replyCalls, [@_];
    return $wireReply;
});
my $managerResult = $manager->_read_slowlog('redis', '/var/lib/orm-instances/testacct/redis.sock');
is_deeply($managerResult, {
    entries => [{ command => 'set', duration_usec => 1234, timestamp => 1700000000 }],
    truncated => 0,
}, 'wire the bounded parser into the fixed slow-log broker path');
is_deeply(\@replyCalls, [['redis', '/var/lib/orm-instances/testacct/redis.sock']],
    'use only the selected backend and trusted instance socket in the reader seam');
is(Orm::Broker::InstanceManager::_redis_resp_command('SLOWLOG', 'GET', '11'),
    "*3\r\n\$7\r\nSLOWLOG\r\n\$3\r\nGET\r\n\$2\r\n11\r\n",
    'send only the fixed bounded SLOWLOG GET request');
ok(!defined($manager->_read_slowlog('redis', '/tmp/other.sock'))
    && !defined($manager->_read_slowlog('custom', '/var/lib/orm-instances/testacct/redis.sock')),
    'reject sockets outside the managed instance root and unsupported backends');

my $unknown = parse_reply('*1' . "\r\n" . resp_entry(argv => ["\xff\x00secret", 'ignored']));
is($unknown->{entries}->[0]->{command}, 'other', 'replace non-token command bytes with a fixed label');
my $too_many = '*' . 11 . "\r\n" . join('', map { resp_entry(id => $_) } 1 .. 11);
my $limited = parse_reply($too_many);
is(scalar @{$limited->{entries}}, 10, 'return at most ten entries when eleven are fetched');
is($limited->{truncated}, 1, 'indicate when an additional recent entry may exist');

ok(!defined(parse_reply('*12' . "\r\n" . ('*0' . "\r\n") x 12)), 'reject more entries than the fixed fetch cap');
ok(!defined(parse_reply('*1' . "\r\n" . '*5' . "\r\n")), 'reject unexpected entry shape');
ok(!defined(parse_reply('*1' . "\r\n" . resp_entry(redis_810 => 1, total_arguments => 1))),
    'reject inconsistent Redis 8.10 total argument count');
ok(!defined(parse_reply('*1' . "\r\n" . '*6' . "\r\n" . ':1\n')),
    'reject malformed RESP line framing');
ok(!defined(parse_reply('*1' . "\r\n" . '*6' . "\r\n" . ':1' . "\r\n")),
    'reject truncated entry data');
ok(!defined(parse_reply('*1' . "\r\n" . resp_entry(argv => ['GET', ('x' x 65500)]))),
    'reject fields that cause the parsed reply to exceed the wire-byte bound');

my $ok_reply = '+OK' . "\r\n";
open(my $ack, '<', \$ok_reply) or die "cannot open ACK fixture: $!";
ok(Orm::Broker::SlowLogReader->expect_simple_ok($ack), 'accept only a simple RESP OK for AUTH');
my $error_reply = '-ERR invalid password' . "\r\n";
open(my $error, '<', \$error_reply) or die "cannot open error fixture: $!";
ok(!Orm::Broker::SlowLogReader->expect_simple_ok($error), 'reject Redis authentication errors');

done_testing();
