#!/usr/bin/env perl
use strict;
use warnings;
use Digest::SHA ();
use Fcntl qw(:mode);
use File::Basename qw(dirname);
use File::Spec;
use JSON::PP;

my ($manifest_path, $expected_version, $metadata_path, $test_target_root) = @ARGV;
defined($manifest_path) && defined($expected_version) && defined($metadata_path) && (@ARGV == 3 || @ARGV == 4)
    or die "Usage: perl compare-release-preview.pl INSTALL_MANIFEST VERSION VERIFIED_METADATA [TEST_TARGET_ROOT]\n";
$expected_version =~ /\A(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-(?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*))*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?\z/
    or die "ORM update preview: installed version is invalid.\n";
$> == 0 or die "ORM update preview: comparison must run as root.\n";

sub fail { die "ORM update preview: $_[0]\n"; }

sub mode_of {
    my ($mode) = @_;
    return $mode & 07777;
}

sub allowed_target {
    my ($path) = @_;
    $path =~ m{\A/(?:[A-Za-z0-9._@-]+/)*[A-Za-z0-9._@-]+\z}
        or return 0;
    my @parts = split m{/}, substr($path, 1), -1;
    @parts && !grep { $_ eq q{} || $_ eq q{.} || $_ eq q{..} } @parts
        or return 0;
    my %allowed = map { $_ => 1 } qw(
        /usr/local/cpanel/base/frontend/jupiter/orm/index.live.php
        /usr/local/cpanel/whostmgr/docroot/cgi/addon_open_redis_manager.php
        /usr/local/cpanel/whostmgr/docroot/addon_plugins/orm-whm.png
        /usr/local/cpanel/3rdparty/orm/src/Orm/Backend/BackendDiscovery.php
        /usr/local/cpanel/3rdparty/orm/src/Orm/Security/WhmAcl.php
        /usr/local/cpanel/3rdparty/orm/src/Orm/Security/SessionRequestGuard.php
        /usr/local/cpanel/3rdparty/orm/src/Orm/Security/WhmAuditLog.php
        /usr/local/cpanel/3rdparty/orm/src/Orm/Security/WhmAuditEventWriter.php
        /usr/local/cpanel/3rdparty/orm/src/Orm/Security/WhmSecurityReport.php
        /usr/local/cpanel/3rdparty/orm/src/Orm/Security/WhmSecurityReportPolicyStore.php
        /usr/local/cpanel/3rdparty/orm/src/Orm/Cpanel/AuthenticatedAccountContext.php
        /usr/local/cpanel/3rdparty/orm/src/Orm/Cpanel/BrokerIdentityVerifier.php
        /usr/local/cpanel/3rdparty/orm/src/Orm/Cpanel/BrokerClient.php
        /usr/local/cpanel/3rdparty/orm/src/Orm/Cpanel/ConnectionDetails.php
        /usr/local/cpanel/3rdparty/orm/src/Orm/Cpanel/DiagnosticReport.php
        /usr/local/cpanel/3rdparty/orm/src/Orm/Cpanel/HealthGuidance.php
        /usr/local/cpanel/3rdparty/orm/src/Orm/Cpanel/PodmanCacheDiscovery.php
        /usr/local/cpanel/3rdparty/orm/src/Orm/Cpanel/PodmanLifecycleManager.php
        /usr/local/cpanel/3rdparty/orm/src/Orm/Cpanel/ApplicationDiscovery.php
        /usr/local/cpanel/3rdparty/orm/src/Orm/Backend/BackendPolicyStore.php
        /usr/local/cpanel/3rdparty/orm/bin/orm-broker.pl
        /usr/local/cpanel/3rdparty/orm/bin/orm-instance-launcher
        /usr/local/cpanel/3rdparty/orm/bin/orm-metrics-collect.pl
        /usr/local/cpanel/3rdparty/orm/lib/Orm/Broker/AccountResolver.pm
        /usr/local/cpanel/3rdparty/orm/lib/Orm/Broker/BackendPolicy.pm
        /usr/local/cpanel/3rdparty/orm/lib/Orm/Broker/Handler.pm
        /usr/local/cpanel/3rdparty/orm/lib/Orm/Broker/InstanceManager.pm
        /usr/local/cpanel/3rdparty/orm/lib/Orm/Broker/FleetInventory.pm
        /usr/local/cpanel/3rdparty/orm/lib/Orm/Broker/PeerCredentials.pm
        /usr/local/cpanel/3rdparty/orm/lib/Orm/Broker/Protocol.pm
        /usr/local/cpanel/3rdparty/orm/lib/Orm/Broker/Server.pm
        /etc/systemd/system/orm-broker.service
        /etc/systemd/system/orm-instance@.service
        /etc/systemd/system/orm-metrics-collect@.service
        /etc/systemd/system/orm-metrics-collect@.timer
        /usr/local/cpanel/3rdparty/orm/src/Orm/Backend/ProviderPolicyStore.php
        /usr/local/cpanel/3rdparty/orm/lib/Orm/Broker/ProviderPolicy.pm
        /usr/local/cpanel/3rdparty/orm/VERSION
        /usr/local/cpanel/3rdparty/orm/packaging/preview-release.sh
        /usr/local/cpanel/3rdparty/orm/packaging/apply-release.sh
        /usr/local/cpanel/3rdparty/orm/packaging/recover-release.sh
        /usr/local/cpanel/3rdparty/orm/bin/orm-update-worker.pl
        /usr/local/cpanel/3rdparty/orm/packaging/lib.sh
        /usr/local/cpanel/3rdparty/orm/packaging/release-lib.sh
        /usr/local/cpanel/3rdparty/orm/packaging/inspect-release-archive.pl
        /usr/local/cpanel/3rdparty/orm/packaging/compare-release-preview.pl
        /usr/local/cpanel/3rdparty/orm/packaging/release-install-map.txt
        /usr/local/cpanel/3rdparty/orm/packaging/release-required-files.txt
        /usr/local/cpanel/3rdparty/orm/src/Orm/Update/ReleasePreview.php
        /usr/local/cpanel/3rdparty/orm/src/Orm/Update/ReleaseApplyJob.php
        /var/cpanel/apps/open_redis_manager.conf
    );
    return exists $allowed{$path};
}

sub physical_path {
    my ($logical) = @_;
    return $logical unless defined $test_target_root;
    return File::Spec->catfile($test_target_root, split m{/}, substr($logical, 1));
}

sub check_safe_directory_chain {
    my ($path, $allow_missing) = @_;
    $path =~ m{\A/} or fail('target path is not absolute');
    my $directory = dirname($path);
    while (1) {
        if (-e $directory || -l $directory) {
            my @info = lstat($directory);
            @info or fail('could not inspect an install target parent');
            S_ISDIR($info[2]) && !S_ISLNK($info[2])
                or fail('an install target parent is not a real directory');
            $info[4] == 0 or fail('an install target parent is not root-owned');
            my $mode = mode_of($info[2]);
            (($mode & 0022) == 0 || ($mode & 01000) != 0)
                or fail('an install target parent is writable by an untrusted user');
        } elsif (!$allow_missing) {
            fail('an installed target parent is missing');
        }
        last if $directory eq '/';
        $directory = dirname($directory);
    }
}

sub file_digest {
    my ($path) = @_;
    open my $handle, '<:raw', $path or fail('could not read an installed target');
    my $digest = Digest::SHA->new(256);
    $digest->addfile($handle);
    close $handle or fail('could not finish reading an installed target');
    return $digest->hexdigest;
}

if (defined $test_target_root) {
    $test_target_root =~ m{\A/} && -d $test_target_root && !-l $test_target_root
        or fail('test target root is invalid');
    my @root_info = lstat($test_target_root);
    @root_info && $root_info[4] == 0 && (mode_of($root_info[2]) & 0022) == 0
        or fail('test target root must be root-owned and private');
}

my @manifest_info = lstat($manifest_path);
@manifest_info && S_ISREG($manifest_info[2]) && !S_ISLNK($manifest_info[2])
    or fail('installed manifest is missing or unsafe');
$manifest_info[4] == 0 && mode_of($manifest_info[2]) == 0600
    or fail('installed manifest must be root-owned with mode 0600');
check_safe_directory_chain($manifest_path, 0);
$manifest_info[7] <= 1_048_576 or fail('installed manifest exceeds the size limit');
open my $manifest_handle, '<:raw', $manifest_path or fail('could not read installed manifest');
my @manifest_lines = <$manifest_handle>;
close $manifest_handle or fail('could not finish reading installed manifest');
@manifest_lines && @manifest_lines <= 10_002 or fail('installed manifest is empty or too large');
my $schema = shift @manifest_lines;
$schema =~ s/\n\z//;
my ($schema_version, $version);
if ($schema eq 'orm-install-manifest-v1') {
    fail('v1 installed manifests do not record file targets; a verified live preview requires a v3 manifest');
} elsif ($schema eq 'orm-install-manifest-v2') {
    fail('v2 installed manifests do not record file targets; a verified live preview requires a v3 manifest');
} elsif ($schema eq 'orm-install-manifest-v3') {
    $schema_version = 3;
    my $version_line = shift @manifest_lines // q{};
    $version_line =~ s/\n\z//;
    $version_line =~ /\Aversion\|(.+)\z/ or fail('installed manifest version record is malformed');
    $version = $1;
    $version =~ /\A(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-(?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*))*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?\z/
        or fail('installed manifest version is invalid');
    $version eq $expected_version or fail('installed version does not match the requested preview version');
} else {
    fail('installed manifest schema is unsupported');
}

my %installed;
for my $line (@manifest_lines) {
    $line =~ s/\n\z//;
    my @fields = split /\|/, $line, -1;
    my ($key, $mode, $digest, $target, $extra) = @fields;
    defined($key) && defined($mode) && defined($digest) && !defined($extra)
        or fail('installed manifest contains a malformed row');
    $key =~ /\A[a-z_]+\z/ && !$installed{$key}
        or fail('installed manifest contains a duplicate or invalid file key');
    $mode =~ /\A(?:600|644|755)\z/ or fail('installed manifest contains an invalid file mode');
    $digest =~ /\A[a-f0-9]{64}\z/ or fail('installed manifest contains an invalid SHA-256 digest');
    defined($target) && allowed_target($target)
        or fail('installed manifest contains an invalid install target');
    $installed{$key} = { mode => $mode, sha256 => $digest, target => $target };
}
scalar(keys %installed) > 0 or fail('installed manifest has no file records');

my $inventory_text = do { local $/; <STDIN> };
defined($inventory_text) && length($inventory_text) <= 4_194_304
    or fail('verified release inventory is empty or too large');
my $inventory = eval { decode_json($inventory_text) };
$@ && fail('verified release inventory is not valid JSON');
ref($inventory) eq 'HASH' && ref($inventory->{files}) eq 'ARRAY' && ref($inventory->{installMap}) eq 'ARRAY'
    or fail('verified release inventory lacks files or install targets');

my @metadata_info = lstat($metadata_path);
@metadata_info && S_ISREG($metadata_info[2]) && !S_ISLNK($metadata_info[2])
    or fail('verified release metadata is missing or unsafe');
$metadata_info[4] == 0 && (mode_of($metadata_info[2]) & 0022) == 0
    or fail('verified release metadata is not root-owned and protected');
check_safe_directory_chain($metadata_path, 0);
$metadata_info[7] <= 8192 or fail('verified release metadata exceeds the size limit');
open my $metadata_handle, '<:raw', $metadata_path or fail('could not read verified release metadata');
my @metadata_lines = <$metadata_handle>;
close $metadata_handle or fail('could not finish reading verified release metadata');
@metadata_lines == 14 or fail('verified release metadata has an invalid field count');
my @metadata_keys = qw(product key_id version channel source_commit state_migrations artifact artifact_size artifact_sha256 min_from_version max_from_version created_at expires_at);
my %metadata;
shift(@metadata_lines) eq "orm-release-metadata-v2\n" or fail('verified release metadata header is invalid');
for my $index (0 .. $#metadata_keys) {
    my $line = $metadata_lines[$index];
    $line =~ s/\n\z//;
    my ($key, $value, $extra) = split /\|/, $line, -1;
    defined($key) && $key eq $metadata_keys[$index] && defined($value) && length($value) && !defined($extra)
        or fail('verified release metadata field order is invalid');
    $metadata{$key} = $value;
}
$metadata{version} eq $inventory->{version}
    or fail('verified metadata version differs from the inspected archive');
$metadata{state_migrations} eq 'none'
    or fail('release declares unsupported ORM state migrations');
$metadata{source_commit} =~ /\A(?:[a-f0-9]{40}|[a-f0-9]{64})\z/
    or fail('signed release source commit is invalid');

my (%candidate, %candidate_by_target, %archive_files);
for my $file (@{$inventory->{files}}) {
    ref($file) eq 'HASH' && defined($file->{path}) && defined($file->{mode}) && defined($file->{sha256})
        or fail('release inventory contains a malformed file record');
    $archive_files{$file->{path}} = $file;
}
for my $entry (@{$inventory->{installMap}}) {
    ref($entry) eq 'HASH' or fail('release install map contains a malformed row');
    my ($key, $source, $target, $mode) = @{$entry}{qw(key source target mode)};
    defined($key) && $key =~ /\A[a-z_]+\z/ && !exists($candidate{$key})
        or fail('release install map contains a duplicate or invalid key');
    defined($source) && exists($archive_files{$source})
        or fail('release install map references a missing archive file');
    defined($mode) && $mode =~ /\A(?:600|644|755)\z/
        or fail('release install map contains an invalid mode');
    defined($target) && allowed_target($target) && !exists($candidate_by_target{$target})
        or fail('release install map contains a duplicate or unsafe target');
    $candidate{$key} = { source => $source, target => $target, mode => $mode,
        sha256 => $archive_files{$source}{sha256} };
    $candidate_by_target{$target} = $key;
}
scalar(keys %candidate) > 0 or fail('release install map is empty');

my %installed_by_target;
for my $key (sort keys %installed) {
    my $entry = $installed{$key};
    defined($entry->{target}) && allowed_target($entry->{target})
        or fail('installed manifest target is invalid');
    !$installed_by_target{$entry->{target}}
        or fail('installed manifest maps multiple files to one target');
    $installed_by_target{$entry->{target}} = $key;
    my $physical = physical_path($entry->{target});
    check_safe_directory_chain($physical, 1);
    my @file_info = lstat($physical);
    if (!@file_info) {
        $entry->{integrityConflict} = { reason => 'target_missing' };
        next;
    }
    S_ISREG($file_info[2]) && !S_ISLNK($file_info[2])
        or fail('an installed manifest target is a symlink or special file');
    if ($file_info[4] != 0) {
        $entry->{integrityConflict} = { reason => 'ownership_changed' };
        next;
    }
    my $actual_mode = sprintf('%o', mode_of($file_info[2]));
    if ($actual_mode ne $entry->{mode}) {
        $entry->{integrityConflict} = { reason => 'mode_changed', observedMode => $actual_mode };
        if ((mode_of($file_info[2]) & 0022) == 0) {
            $entry->{integrityConflict}{observedSha256} = file_digest($physical);
        }
        next;
    }
    my $actual_digest = file_digest($physical);
    if ($actual_digest ne $entry->{sha256}) {
        $entry->{integrityConflict} = { reason => 'digest_changed', observedSha256 => $actual_digest };
    }
}

my @actions;
my %action_counts = map { $_ => 0 } qw(add replace unchanged move conflict retire);
for my $key (sort keys %candidate) {
    my $next = $candidate{$key};
    my $before = $installed{$key};
    my $destination = physical_path($next->{target});
    check_safe_directory_chain($destination, 1);
    my $action;
    if ($before) {
        if ($before->{integrityConflict}) {
            $action = 'conflict';
        } elsif ($before->{target} ne $next->{target}) {
            my $destination_owner = $installed_by_target{$next->{target}};
            $action = ((-e $destination || -l $destination) && (!defined($destination_owner) || $destination_owner ne $key))
                ? 'conflict' : 'move';
        } else {
            $action = ($before->{mode} eq $next->{mode} && $before->{sha256} eq $next->{sha256})
                ? 'unchanged' : 'replace';
        }
    } else {
        $action = (-e $destination || -l $destination) ? 'conflict' : 'add';
    }
    $action_counts{$action}++;
    push @actions, {
        key => $key,
        action => $action,
        source => $next->{source},
        target => $next->{target},
        mode => $next->{mode},
        sha256 => $next->{sha256},
        requiresReview => $action eq 'conflict' ? JSON::PP::true : JSON::PP::false,
    };
    if ($before && $before->{integrityConflict}) {
        $actions[-1]{conflictReason} = $before->{integrityConflict}{reason};
        $actions[-1]{observedMode} = $before->{integrityConflict}{observedMode}
            if defined $before->{integrityConflict}{observedMode};
        $actions[-1]{observedSha256} = $before->{integrityConflict}{observedSha256}
            if defined $before->{integrityConflict}{observedSha256};
    }
}
for my $key (sort keys %installed) {
    next if exists $candidate{$key};
    my $action = $installed{$key}{integrityConflict} ? 'conflict' : 'retire';
    $action_counts{$action}++;
    push @actions, {
        key => $key,
        action => $action,
        source => undef,
        target => $installed{$key}{target},
        mode => $installed{$key}{mode},
        sha256 => $installed{$key}{sha256},
        requiresReview => JSON::PP::true,
        note => 'No removal will be performed by preview or assumed by the updater.',
        (defined($installed{$key}{integrityConflict})
            ? (conflictReason => $installed{$key}{integrityConflict}{reason})
            : ()),
    };
}

print JSON::PP->new->canonical->encode({
    schema => 'orm-update-preview-v2',
    installedVersion => $expected_version,
    candidateVersion => $inventory->{version},
    verified => JSON::PP::false,
    mutationsApplied => JSON::PP::false,
    manifestSchema => $schema_version,
    attestationStatus => 'unverified-by-comparator',
    targetComparison => defined($test_target_root) ? 'test-fixture-computed' : 'computed',
    release => {
        keyId => $metadata{key_id},
        channel => $metadata{channel},
        sourceCommit => $metadata{source_commit},
        stateMigrations => $metadata{state_migrations},
        artifact => $metadata{artifact},
        artifactSize => 0 + $metadata{artifact_size},
        artifactSha256 => $metadata{artifact_sha256},
        minimumFromVersion => $metadata{min_from_version},
        maximumFromVersion => $metadata{max_from_version},
        createdAt => $metadata{created_at},
        expiresAt => $metadata{expires_at},
    },
    summary => \%action_counts,
    fileActions => \@actions,
    migrationActions => [],
    migrationPlanAvailable => JSON::PP::false,
    archiveInventory => {
        members => $inventory->{members},
        totalBytes => $inventory->{totalBytes},
    },
}), "\n";
