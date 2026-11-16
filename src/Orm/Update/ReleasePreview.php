<?php
declare(strict_types=1);

namespace Orm\Update;

use Orm\Security\SessionRequestGuard;

/** Runs the fixed, read-only signed-release preview for the WHM root operator. */
final class ReleasePreview
{
    private const PACKAGE_ROOT = '/usr/local/cpanel/3rdparty/orm';
    private const STAGED_ROOT = '/var/cpanel/orm/updates/staged';
    private const TRUSTED_KEY_ROOT = '/etc/orm/release-keys';
    private const OUTPUT_LIMIT = 1048576;

    /**
     * @param array<string, mixed> $server
     * @param null|callable(list<string>, array<string, string>): array{exit_code:int,stdout:string} $runner
     * @return array<string, mixed>
     */
    public static function run(string $authenticatedUser, array $server, ?callable $runner = null): array
    {
        if ($authenticatedUser !== 'root' || !SessionRequestGuard::allowsMutation($server)) {
            return ['ok' => false, 'message' => 'Only root may request a signed update preview through the WHM session.'];
        }

        $script = self::PACKAGE_ROOT . '/packaging/preview-release.sh';
        $manifest = self::PACKAGE_ROOT . '/install-manifest';
        $versionFile = self::PACKAGE_ROOT . '/VERSION';
        $installMap = self::PACKAGE_ROOT . '/packaging/release-install-map.txt';
        foreach ([$script, $manifest, $versionFile, $installMap] as $path) {
            if (!self::isProtectedRegularFile($path)) {
                return ['ok' => false, 'message' => 'The installed signed-update verifier is incomplete or has unsafe permissions.'];
            }
        }
        if (!is_file('/usr/bin/bash') || !is_executable('/usr/bin/bash')
            || !is_file('/usr/bin/timeout') || !is_executable('/usr/bin/timeout')
            || !function_exists('proc_open')) {
            return ['ok' => false, 'message' => 'This host cannot safely run the fixed signed-update verifier.'];
        }

        $version = file_get_contents($versionFile);
        if (!is_string($version) || strlen($version) > 128 || !preg_match(
            '/\A(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-(?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*))*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?\n?\z/D',
            $version
        )) {
            return ['ok' => false, 'message' => 'The installed ORM version could not be verified.'];
        }
        $version = rtrim($version, "\r\n");
        $allowedTargets = self::readInstalledTargets($installMap);
        if ($allowedTargets === null) {
            return ['ok' => false, 'message' => 'The installed signed-update allowlist could not be verified.'];
        }

        $argv = [
            '/usr/bin/timeout', '--signal=KILL', '30s', '/usr/bin/bash', $script,
            self::STAGED_ROOT . '/release.metadata',
            self::STAGED_ROOT . '/release.sig',
            self::STAGED_ROOT . '/release.tar.gz',
            self::TRUSTED_KEY_ROOT,
            $version,
            $manifest,
        ];
        $environment = [
            'HOME' => '/root',
            'LANG' => 'C',
            'LC_ALL' => 'C',
            'PATH' => '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
        ];
        $result = $runner === null ? self::execute($argv, $environment) : $runner($argv, $environment);
        if (!is_array($result) || !isset($result['exit_code'], $result['stdout'])
            || !is_int($result['exit_code']) || !is_string($result['stdout'])
            || strlen($result['stdout']) > self::OUTPUT_LIMIT) {
            return ['ok' => false, 'message' => 'The signed-update verifier returned an invalid or oversized response.'];
        }
        if ($result['exit_code'] !== 0) {
            return ['ok' => false, 'message' => 'No verified preview is available. Check that a valid signed release is staged and its public key is trusted.'];
        }

        return self::validate($result['stdout'], $version, $allowedTargets);
    }

    /** @param list<string> $allowedTargets @return array<string, mixed> */
    public static function validate(string $output, string $installedVersion, array $allowedTargets): array
    {
        if (strlen($output) > self::OUTPUT_LIMIT) {
            return ['ok' => false, 'message' => 'The signed-update verifier returned an invalid or oversized response.'];
        }
        $preview = json_decode($output, true, 32, JSON_BIGINT_AS_STRING);
        if (!is_array($preview) || ($preview['schema'] ?? null) !== 'orm-update-preview-v2'
            || ($preview['verified'] ?? null) !== true
            || ($preview['signatureVerified'] ?? null) !== true
            || ($preview['mutationsApplied'] ?? null) !== false
            || ($preview['targetComparison'] ?? null) !== 'verified'
            || ($preview['installedVersion'] ?? null) !== $installedVersion
            || !is_string($preview['candidateVersion'] ?? null)
            || !preg_match('/\A(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-(?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*))*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?\z/D', $preview['candidateVersion'])
            || !is_array($preview['summary'] ?? null)
            || !is_array($preview['release'] ?? null)
            || !is_array($preview['fileActions'] ?? null)
            || count($preview['fileActions']) > 100) {
            return ['ok' => false, 'message' => 'The signed-update verifier response did not meet ORM’s preview contract.'];
        }

        foreach (['add', 'replace', 'unchanged', 'move', 'conflict', 'retire'] as $action) {
            if (!isset($preview['summary'][$action]) || !is_int($preview['summary'][$action])
                || $preview['summary'][$action] < 0) {
                return ['ok' => false, 'message' => 'The signed-update verifier returned an invalid file summary.'];
            }
        }
        $safeActions = [];
        foreach ($preview['fileActions'] as $entry) {
            if (!is_array($entry) || !is_string($entry['key'] ?? null)
                || !preg_match('/\A[a-z_]{1,64}\z/D', $entry['key'])
                || !in_array($entry['action'] ?? null, ['add', 'replace', 'unchanged', 'move', 'conflict', 'retire'], true)
                || !is_string($entry['target'] ?? null)
                || !self::isManagedTarget($entry['target'], $allowedTargets)) {
                return ['ok' => false, 'message' => 'The signed-update verifier returned an invalid file action.'];
            }
            $safeActions[] = [
                'key' => $entry['key'],
                'action' => $entry['action'],
                'target' => $entry['target'],
                'requiresReview' => ($entry['requiresReview'] ?? false) === true,
            ];
        }

        $release = $preview['release'];
        foreach (['channel', 'keyId', 'artifactSha256'] as $field) {
            if (!is_string($release[$field] ?? null)) {
                return ['ok' => false, 'message' => 'The signed-update verifier returned incomplete release metadata.'];
            }
        }
        if (strlen($release['channel']) > 32 || strlen($release['keyId']) > 64
            || !preg_match('/\A[a-f0-9]{64}\z/D', $release['artifactSha256'])) {
            return ['ok' => false, 'message' => 'The signed-update verifier returned an invalid artifact digest.'];
        }

        return [
            'ok' => true,
            'installedVersion' => $installedVersion,
            'candidateVersion' => $preview['candidateVersion'],
            'release' => [
                'channel' => $release['channel'],
                'keyId' => $release['keyId'],
                'artifactSha256' => $release['artifactSha256'],
            ],
            'summary' => $preview['summary'],
            'fileActions' => $safeActions,
        ];
    }

    /** @param list<string> $argv @param array<string, string> $environment @return array{exit_code:int,stdout:string} */
    private static function execute(array $argv, array $environment): array
    {
        $process = proc_open($argv, [
            0 => ['file', '/dev/null', 'r'],
            1 => ['pipe', 'w'],
            2 => ['file', '/dev/null', 'a'],
        ], $pipes, '/', $environment);
        if (!is_resource($process)) {
            return ['exit_code' => 1, 'stdout' => ''];
        }
        $stdout = stream_get_contents($pipes[1], self::OUTPUT_LIMIT + 1);
        fclose($pipes[1]);
        $status = proc_close($process);
        return ['exit_code' => is_int($status) ? $status : 1, 'stdout' => is_string($stdout) ? $stdout : ''];
    }

    private static function isProtectedRegularFile(string $path): bool
    {
        if (!is_file($path) || is_link($path)) {
            return false;
        }
        $owner = fileowner($path);
        $mode = fileperms($path);
        if ($owner !== 0 || $mode === false || ($mode & 0022) !== 0) {
            return false;
        }
        $directory = dirname($path);
        while (true) {
            if (!is_dir($directory) || is_link($directory)) {
                return false;
            }
            $directoryOwner = fileowner($directory);
            $directoryMode = fileperms($directory);
            if ($directoryOwner !== 0 || $directoryMode === false
                || (($directoryMode & 0022) !== 0 && ($directoryMode & 01000) === 0)) {
                return false;
            }
            if ($directory === '/') {
                break;
            }
            $directory = dirname($directory);
        }
        return true;
    }

    /** @return null|list<string> */
    private static function readInstalledTargets(string $path): ?array
    {
        $contents = file_get_contents($path);
        if (!is_string($contents) || strlen($contents) > 65536) {
            return null;
        }
        $targets = [];
        foreach (explode("\n", rtrim($contents, "\r\n")) as $line) {
            $fields = explode('|', $line);
            if (count($fields) !== 4 || !preg_match('/\A[a-z_]+\z/D', $fields[0])
                || !in_array($fields[3], ['600', '644', '755'], true)
                || !self::isSafeAbsolutePath($fields[2]) || in_array($fields[2], $targets, true)) {
                return null;
            }
            $targets[] = $fields[2];
        }
        return $targets === [] ? null : $targets;
    }

    /** @param list<string> $allowedTargets */
    private static function isManagedTarget(string $path, array $allowedTargets): bool
    {
        return self::isSafeAbsolutePath($path) && in_array($path, $allowedTargets, true);
    }

    private static function isSafeAbsolutePath(string $path): bool
    {
        if (strlen($path) > 512 || preg_match('/\A\/(?:[A-Za-z0-9._@-]+\/)*[A-Za-z0-9._@-]+\z/D', $path) !== 1) {
            return false;
        }
        foreach (explode('/', substr($path, 1)) as $component) {
            if ($component === '.' || $component === '..') {
                return false;
            }
        }
        return true;
    }
}
