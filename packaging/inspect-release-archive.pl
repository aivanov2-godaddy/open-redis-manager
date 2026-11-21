#!/usr/bin/env perl
use strict;
use warnings;
use Archive::Tar;
use Digest::SHA qw(sha256_hex);
use FindBin;
use IO::Uncompress::Gunzip qw($GunzipError);
use JSON::PP;

my ($archive, $version, $output_mode) = @ARGV;
defined($archive) && defined($version) && (@ARGV == 2 || @ARGV == 3)
    or die "Usage: perl inspect-release-archive.pl ARCHIVE VERSION [--json]\n";
($output_mode //= q{}) eq q{} || $output_mode eq '--json'
    or die "ORM release archive: unsupported output mode.\n";
$version =~ /\A(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-(?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*))*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?\z/
    or die "ORM release archive: invalid release version.\n";
-f $archive && !-l $archive
    or die "ORM release archive: archive is missing or unsafe.\n";

my $prefix = "orm-$version";
my $max_archive_bytes = 134_217_728;
my $max_uncompressed_archive_bytes = 671_088_640;
my $max_members = 10_000;
my $max_file_bytes = 67_108_864;
my $max_total_bytes = 536_870_912;
my $archive_bytes = -s $archive;
defined($archive_bytes) && $archive_bytes > 0 && $archive_bytes <= $max_archive_bytes
    or die "ORM release archive: compressed archive size exceeds the limit.\n";

my $gunzip = IO::Uncompress::Gunzip->new($archive)
    or die "ORM release archive: gzip stream is invalid.\n";
my ($uncompressed_bytes, $buffer) = (0, q{});
while (1) {
    my $read_bytes = $gunzip->read($buffer, 65_536);
    defined($read_bytes)
        or die "ORM release archive: gzip stream is invalid.\n";
    last if $read_bytes == 0;
    $uncompressed_bytes += $read_bytes;
    $uncompressed_bytes <= $max_uncompressed_archive_bytes
        or die "ORM release archive: expanded archive size exceeds the limit.\n";
}
$gunzip->close
    or die "ORM release archive: gzip stream checksum is invalid.\n";

$Archive::Tar::MAX_FILE_SIZE = $max_file_bytes;
my $required_manifest = "$FindBin::Bin/release-required-files.txt";
open my $required_handle, '<', $required_manifest
    or die "ORM release archive: required-file manifest is unavailable.\n";
my %required;
while (my $required_path = <$required_handle>) {
    $required_path =~ s/\n\z//;
    $required_path =~ /\A[A-Za-z0-9._\/@-]+\z/
        or die "ORM release archive: required-file manifest is invalid.\n";
    my @parts = split m{/}, $required_path, -1;
    @parts && !grep { $_ eq q{} || $_ eq q{.} || $_ eq q{..} } @parts
        or die "ORM release archive: required-file manifest contains an unsafe path.\n";
    exists($required{$required_path})
        and die "ORM release archive: required-file manifest repeats a path.\n";
    $required{$required_path} = 0;
}
close $required_handle
    or die "ORM release archive: could not finish reading required-file manifest.\n";
scalar(keys %required) >= 40
    or die "ORM release archive: required-file manifest is incomplete.\n";
for my $core_file (qw(VERSION README.md packaging/lib.sh packaging/install.sh packaging/upgrade.sh packaging/release-lib.sh packaging/inspect-release-archive.pl packaging/preview-release.sh packaging/apply-release.sh packaging/adopt-install-manifest.sh packaging/release-install-map.txt packaging/compare-release-preview.pl packaging/release-required-files.txt bin/orm-update-worker.pl src/Orm/Update/ReleaseApplyJob.php)) {
    exists($required{$core_file})
        or die "ORM release archive: required-file manifest omits a core package file.\n";
}

my $next = eval { Archive::Tar->iter($archive, 1) };
ref($next) eq 'CODE'
    or die "ORM release archive: could not read archive structure.\n";

my (%seen, %path_types);
my @inventory;
my $install_map_contents;
my ($members, $expanded_bytes, $root_seen) = (0, 0, 0);
my ($version_contents, $warning) = (undef, 0);
local $SIG{__WARN__} = sub { $warning = 1 };
while (1) {
    my $member = eval { $next->() };
    $@ and die "ORM release archive: archive structure is invalid.\n";
    $warning and die "ORM release archive: archive parser reported malformed data.\n";
    last unless $member;
    $members++;
    $members <= $max_members
        or die "ORM release archive: member count exceeds the limit.\n";

    my $is_file = $member->is_file;
    my $is_dir = $member->is_dir;
    ($is_file || $is_dir)
        or die "ORM release archive: links and special file types are not allowed.\n";
    my $name = $member->full_path;
    defined($name) && length($name) <= 1024
        && $name =~ /\A[A-Za-z0-9._\/@-]+\z/ && $name !~ /\\/
        or die "ORM release archive: member path contains unsupported characters.\n";
    $name =~ s{/$}{} if $is_dir;
    ($name eq $prefix || index($name, "$prefix/") == 0)
        or die "ORM release archive: member escapes the expected release root.\n";
    my $relative = $name eq $prefix ? q{} : substr($name, length($prefix) + 1);
    if (length($relative)) {
        my @parts = split m{/}, $relative, -1;
        @parts && !grep { $_ eq q{} || $_ eq q{.} || $_ eq q{..} || length($_) > 255 } @parts
            or die "ORM release archive: member path contains an unsafe component.\n";
    } elsif (!$is_dir) {
        die "ORM release archive: release root is not a directory.\n";
    }
    exists($seen{$name})
        and die "ORM release archive: duplicate member path.\n";
    $seen{$name} = 1;
    my @relative_parts = length($relative) ? split(m{/}, $relative, -1) : ();
    my $ancestor = $prefix;
    for my $index (0 .. $#relative_parts - 1) {
        $ancestor .= "/$relative_parts[$index]";
        $path_types{$ancestor} && $path_types{$ancestor} eq 'file'
            and die "ORM release archive: a regular file is also used as a parent directory.\n";
        $path_types{$ancestor} = 'dir';
    }
    my $member_type = $is_dir ? 'dir' : 'file';
    defined($path_types{$name}) && $path_types{$name} ne $member_type
        and die "ORM release archive: file and directory members conflict.\n";
    $path_types{$name} = $member_type;
    if ($name eq $prefix) {
        $is_dir or die "ORM release archive: release root is not a directory.\n";
        $root_seen++;
        $root_seen == 1 or die "ORM release archive: duplicate release root.\n";
    }

    my $mode = $member->mode & 07777;
    if ($is_dir) {
        ($mode == 0755 || $mode == 0775)
            or die "ORM release archive: directory permissions are not canonical.\n";
        my $expected_directory = grep { index($_, "$relative/") == 0 } keys %required;
        $expected_directory || !length($relative)
            or die "ORM release archive: unexpected directory is present.\n";
    } else {
        ($mode == 0644 || $mode == 0664 || $mode == 0755 || $mode == 0775)
            or die "ORM release archive: file permissions are not canonical.\n";
        exists($required{$relative})
            or die "ORM release archive: unexpected file is present.\n";
        my $size = $member->size;
        defined($size) && $size >= 0 && $size <= $max_file_bytes
            or die "ORM release archive: file size exceeds the limit.\n";
        $expanded_bytes += $size;
        $expanded_bytes <= $max_total_bytes
            or die "ORM release archive: expanded size exceeds the limit.\n";
        $required{$relative} = 1 if exists $required{$relative};
        my $content = $member->get_content;
        defined($content)
            or die "ORM release archive: file content could not be read.\n";
        if ($relative eq 'VERSION') {
            $version_contents = $content;
        }
        if ($relative eq 'packaging/release-install-map.txt') {
            $install_map_contents = $content;
        }
        push @inventory, {
            path => $relative,
            size => 0 + $size,
            mode => sprintf('%04o', $mode),
            sha256 => sha256_hex($content),
        };
    }
}
$root_seen == 1
    or die "ORM release archive: expected release root directory is missing.\n";
for my $path (keys %required) {
    $required{$path}
        or die "ORM release archive: required release file is missing.\n";
}
defined($version_contents) && $version_contents eq "$version\n"
    or die "ORM release archive: packaged version does not match signed metadata.\n";
defined($install_map_contents)
    or die "ORM release archive: signed install target map is missing.\n";

my (%inventory_by_path, %install_keys, %install_sources, %install_targets);
my %allowed_install_targets = map { $_ => 1 } qw(
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
    /usr/local/cpanel/3rdparty/orm/bin/orm-podman-metrics-collect.pl
    /usr/local/cpanel/3rdparty/orm/lib/Orm/Broker/AccountResolver.pm
    /usr/local/cpanel/3rdparty/orm/lib/Orm/Broker/BackendPolicy.pm
    /usr/local/cpanel/3rdparty/orm/lib/Orm/Broker/Handler.pm
    /usr/local/cpanel/3rdparty/orm/lib/Orm/Broker/InstanceManager.pm
    /usr/local/cpanel/3rdparty/orm/lib/Orm/Broker/FleetInventory.pm
    /usr/local/cpanel/3rdparty/orm/lib/Orm/Broker/PeerCredentials.pm
    /usr/local/cpanel/3rdparty/orm/lib/Orm/Broker/Protocol.pm
    /usr/local/cpanel/3rdparty/orm/lib/Orm/Broker/Server.pm
    /usr/local/cpanel/3rdparty/orm/lib/Orm/Broker/ProviderEventConfig.pm
    /usr/local/cpanel/3rdparty/orm/lib/Orm/Broker/ProviderEventEndpoint.pm
    /usr/local/cpanel/3rdparty/orm/lib/Orm/Broker/ProviderEventEmitter.pm
    /usr/local/cpanel/3rdparty/orm/lib/Orm/Broker/ProviderEventQueue.pm
    /usr/local/cpanel/3rdparty/orm/lib/Orm/Broker/ProviderEventTransport.pm
    /usr/local/cpanel/3rdparty/orm/lib/Orm/Broker/ProviderEvents.pm
    /usr/local/cpanel/3rdparty/orm/lib/Orm/Broker/PodmanMetricsCollector.pm
    /usr/local/cpanel/3rdparty/orm/bin/orm-provider-events-worker.pl
    /etc/systemd/system/orm-broker.service
    /etc/systemd/system/orm-provider-events.service
    /etc/systemd/system/orm-provider-events.timer
    /etc/systemd/system/orm-instance@.service
    /etc/systemd/system/orm-metrics-collect@.service
    /etc/systemd/system/orm-metrics-collect@.timer
    /etc/systemd/system/orm-podman-metrics.service
    /etc/systemd/system/orm-podman-metrics.timer
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
for my $file (@inventory) {
    $inventory_by_path{$file->{path}} = $file;
}
my @install_map;
$install_map_contents =~ /\A(?:[\x20-\x7E]+\n)+\z/
    or die "ORM release archive: install target map format is invalid.\n";
for my $line (split /\n/, $install_map_contents) {
    next if $line eq q{};
    my ($key, $source, $target, $mode, $extra) = split /\|/, $line, -1;
    defined($key) && !defined($extra)
        or die "ORM release archive: install target map row is invalid.\n";
    $key =~ /\A[a-z_]+\z/ && !$install_keys{$key}++
        or die "ORM release archive: install target map repeats or invalidates a key.\n";
    $source =~ /\A[A-Za-z0-9._\/@-]+\z/ && !$install_sources{$source}++
        or die "ORM release archive: install target map repeats or invalidates a source.\n";
    $target =~ m{\A/(?:[A-Za-z0-9._@-]+/)*[A-Za-z0-9._@-]+\z}
        or die "ORM release archive: install target path is invalid.\n";
    my @target_parts = split m{/}, substr($target, 1), -1;
    @target_parts && !grep { $_ eq q{} || $_ eq q{.} || $_ eq q{..} } @target_parts
        or die "ORM release archive: install target path contains an unsafe component.\n";
    my $allowed_target = exists $allowed_install_targets{$target};
    $allowed_target
        or die "ORM release archive: install target is outside ORM-owned paths.\n";
    $mode =~ /\A(?:600|644|755)\z/
        or die "ORM release archive: install target mode is invalid.\n";
    !$install_targets{$target}++
        or die "ORM release archive: install target map repeats a destination.\n";
    exists($inventory_by_path{$source}) && exists($required{$source})
        or die "ORM release archive: install target map references an absent package file.\n";
    push @install_map, { key => $key, source => $source, target => $target, mode => $mode };
}
scalar(@install_map) >= 30
    or die "ORM release archive: install target map is incomplete.\n";

if ($output_mode eq '--json') {
    print JSON::PP->new->canonical->encode({
        version => $version,
        members => 0 + $members,
        totalBytes => 0 + $expanded_bytes,
        files => \@inventory,
        installMap => \@install_map,
    }), "\n";
} else {
    print "$members|$expanded_bytes\n";
}
