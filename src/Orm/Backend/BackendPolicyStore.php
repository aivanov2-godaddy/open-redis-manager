<?php
declare(strict_types=1);

namespace Orm\Backend;


/** Root-owned selector for the backend used by future ORM instances. */
final class BackendPolicyStore
{
    private const PATH = '/etc/orm-backend-policy.json';
    private const MAX_BYTES = 4096;

    public function selectedBackend(): ?string
    {
        if (!function_exists('posix_geteuid') || posix_geteuid() !== 0) {
            return null;
        }
        $directory = dirname(self::PATH);
        $directoryStat = @lstat($directory);
        if (!is_array($directoryStat) || (($directoryStat['mode'] & 0170000) !== 0040000)
            || $directoryStat['uid'] !== 0 || ($directoryStat['mode'] & 0022) !== 0) {
            return null;
        }
        $stat = @lstat(self::PATH);
        if (!is_array($stat) || (($stat['mode'] & 0170000) !== 0100000)
            || $stat['uid'] !== 0 || $stat['nlink'] !== 1 || ($stat['mode'] & 0022) !== 0
            || $stat['size'] > self::MAX_BYTES) {
            return null;
        }
        $handle = @fopen(self::PATH, 'rb');
        if (!is_resource($handle)) {
            return null;
        }
        $content = stream_get_contents($handle, self::MAX_BYTES + 1);
        fclose($handle);
        if (!is_string($content) || strlen($content) > self::MAX_BYTES) {
            return null;
        }
        try {
            $decoded = json_decode($content, true, 4, JSON_THROW_ON_ERROR);
        } catch (\Throwable) {
            return null;
        }
        if (!is_array($decoded) || array_keys($decoded) !== ['backend', 'version']
            || ($decoded['version'] ?? null) !== 1
            || !in_array($decoded['backend'] ?? null, ['redis', 'valkey'], true)) {
            return null;
        }
        return $decoded['backend'];
    }

    public function select(string $backend): bool
    {
        if (!function_exists('posix_geteuid') || posix_geteuid() !== 0
            || !in_array($backend, ['redis', 'valkey'], true)) {
            return false;
        }
        $directory = dirname(self::PATH);
        $directoryStat = @lstat($directory);
        if (!is_array($directoryStat) || (($directoryStat['mode'] & 0170000) !== 0040000)
            || $directoryStat['uid'] !== 0 || ($directoryStat['mode'] & 0022) !== 0) {
            return false;
        }
        $existing = @lstat(self::PATH);
        if (is_array($existing) && ((($existing['mode'] & 0170000) !== 0100000)
            || $existing['uid'] !== 0 || $existing['nlink'] !== 1 || ($existing['mode'] & 0022) !== 0)) {
            return false;
        }

        try {
            $temporary = $directory . '/.backend-policy-' . bin2hex(random_bytes(12));
            $handle = @fopen($temporary, 'xb');
            if (!is_resource($handle)) {
                return false;
            }
            $content = json_encode(['backend' => $backend, 'version' => 1], JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR) . "\n";
            $written = fwrite($handle, $content);
            $flushed = fflush($handle);
            $synced = function_exists('fsync') ? fsync($handle) : true;
            fclose($handle);
            if ($written !== strlen($content) || !$flushed || !$synced
                || !@chmod($temporary, 0600) || !@chown($temporary, 0) || !@chgrp($temporary, 0)) {
                @unlink($temporary);
                return false;
            }
            if (!@rename($temporary, self::PATH)) {
                @unlink($temporary);
                return false;
            }
            return true;
        } catch (\Throwable) {
            return false;
        }
    }
}
