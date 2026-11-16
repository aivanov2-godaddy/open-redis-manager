#!/usr/bin/perl
use strict;
use warnings;
use Fcntl qw(:DEFAULT :flock :mode);
use JSON::PP qw(decode_json encode_json);
use IO::Handle;
use POSIX qw(strftime);

my $job_id = shift @ARGV;
@ARGV == 0 && defined $job_id && $job_id =~ /\A[a-f0-9]{32}\z/
    or die "ORM update worker: invalid job identifier.\n";
$> == 0 or die "ORM update worker: root is required.\n";

my $state_root = '/var/cpanel/orm/updates';
my $jobs_root = "$state_root/jobs";
my $record_path = "$jobs_root/$job_id.json";
my $lock_path = "$jobs_root/queue.lock";
my $record_limit = 8192;

sub die_safe { die "ORM update worker: $_[0]\n"; }

sub safe_directory {
    my ($path, $mode) = @_;
    my @info = lstat($path);
    @info && S_ISDIR($info[2]) && !S_ISLNK($info[2])
        && $info[4] == 0 && ($info[2] & 07777) == $mode
        or return 0;
    return 1;
}

sub safe_parent_chain {
    my ($path) = @_;
    my @parts = grep { length } split m{/}, $path;
    my $current = '';
    for my $part (@parts) {
        $current .= "/$part";
        my @info = lstat($current);
        @info && S_ISDIR($info[2]) && !S_ISLNK($info[2]) && $info[4] == 0
            && ((($info[2] & 0022) == 0) || (($info[2] & 01000) != 0))
            or return 0;
    }
    return 1;
}

safe_parent_chain($jobs_root)
    or die_safe('the update job parent chain is unsafe.');
safe_directory($state_root, 0700) && safe_directory($jobs_root, 0700)
    or die_safe('the protected job directory is missing or unsafe.');

sub open_lock {
    sysopen(my $lock, $lock_path, O_RDWR | O_CREAT | O_NOFOLLOW, 0600)
        or die_safe('could not open the protected queue lock.');
    my @info = stat($lock);
    @info && S_ISREG($info[2]) && $info[4] == 0 && $info[3] == 1
        && ($info[2] & 07777) == 0600
        or die_safe('the protected queue lock is unsafe.');
    flock($lock, LOCK_EX) or die_safe('could not lock the update queue.');
    return $lock;
}

sub read_record {
    sysopen(my $file, $record_path, O_RDONLY | O_NOFOLLOW)
        or die_safe('the update job record is unavailable.');
    my @info = stat($file);
    @info && S_ISREG($info[2]) && $info[4] == 0 && $info[3] == 1
        && ($info[2] & 07777) == 0600 && $info[7] <= $record_limit
        or die_safe('the update job record is unsafe.');
    local $/;
    my $content = <$file>;
    close $file;
    defined $content && length($content) <= $record_limit
        or die_safe('the update job record is oversized.');
    my $record = eval { decode_json($content) };
    ref($record) eq 'HASH' or die_safe('the update job record is invalid.');
    my %allowed = map { $_ => 1 } qw(schema id state createdAt startedAt finishedAt installedVersion candidateVersion artifactSha256);
    my $unexpected = grep { !$allowed{$_} } keys %{$record};
    !$unexpected && defined $record->{createdAt}
        && $record->{createdAt} =~ /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/
        && (!defined $record->{startedAt} || $record->{startedAt} =~ /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/)
        && (!defined $record->{finishedAt} || $record->{finishedAt} =~ /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/)
        or die_safe('the update job record has unexpected fields.');
    ($record->{id} // '') eq $job_id
        && ($record->{schema} // '') eq 'orm-update-job-v1'
        && ($record->{state} // '') =~ /\A(?:queued|running|succeeded|failed|recovery_required|interrupted)\z/
        && ($record->{installedVersion} // '') =~ /\A(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?\z/
        && ($record->{candidateVersion} // '') =~ /\A(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?\z/
        && ($record->{artifactSha256} // '') =~ /\A[a-f0-9]{64}\z/
        or die_safe('the update job identity failed validation.');
    return $record;
}

sub write_record {
    my ($record) = @_;
    my $temporary = "$jobs_root/.$job_id." . unpack('H*', pack('N3', $$, time, int(rand(0x7fffffff)))) . '.tmp';
    sysopen(my $file, $temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600)
        or die_safe('could not create an atomic job state file.');
    my $content = encode_json($record) . "\n";
    my $written = syswrite($file, $content);
    $written == length($content) && $file->sync()
        or die_safe('could not persist the update job state.');
    close $file or die_safe('could not close the update job state.');
    chmod 0600, $temporary or die_safe('could not secure the update job state.');
    rename $temporary, $record_path or die_safe('could not publish the update job state.');
}

my $lock = open_lock();
my $record = read_record();
$record->{state} eq 'queued' or die_safe('the update job is no longer queued.');
$record->{state} = 'running';
$record->{startedAt} = strftime('%Y-%m-%dT%H:%M:%SZ', gmtime());
write_record($record);
flock($lock, LOCK_UN);
close $lock;

my $apply = '/usr/local/cpanel/3rdparty/orm/packaging/apply-release.sh';
my $manifest = '/usr/local/cpanel/3rdparty/orm/install-manifest';
my $staged = '/var/cpanel/orm/updates/staged';
my $keys = '/etc/orm/release-keys';
-f $apply && !-l $apply && -f $manifest && !-l $manifest
    or die_safe('the installed signed update toolchain is incomplete.');
%ENV = (
    HOME => '/root', LANG => 'C', LC_ALL => 'C',
    PATH => '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
);
system('/usr/bin/bash', $apply,
    "$staged/release.metadata", "$staged/release.sig", "$staged/release.tar.gz",
    $keys, $record->{installedVersion}, $manifest, '',
    $record->{candidateVersion}, $record->{artifactSha256});
my $status = $?;
my $success = $status == 0;
my @transactions = glob "$state_root/transaction.*";
my $recovery_required = !$success && @transactions > 0;

$lock = open_lock();
$record = read_record();
if ($record->{state} eq 'running') {
    $record->{state} = $success ? 'succeeded' : ($recovery_required ? 'recovery_required' : 'failed');
    $record->{finishedAt} = strftime('%Y-%m-%dT%H:%M:%SZ', gmtime());
    write_record($record);
}
flock($lock, LOCK_UN);
close $lock;
exit($success ? 0 : 1);
