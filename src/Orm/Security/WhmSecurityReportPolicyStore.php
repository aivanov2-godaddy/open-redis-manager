<?php
declare(strict_types=1);

namespace Orm\Security;

/** Root-owned advisory thresholds for WHM security reports. These never trigger enforcement. */
final class WhmSecurityReportPolicyStore
{
    private const PATH = '/etc/orm-security-report-policy.json';
    private const MAX_BYTES = 4096;
    private const MAX_THRESHOLD = 9_000_000_000_000_000;

    public function __construct(
        private readonly string $path = self::PATH,
        private readonly ?int $expectedOwnerUid = null,
    ) {
    }

    /** @return array{version:int,thresholds:array{evictions_per_window:int,operations_per_second:int,auth_failures_per_window:int}}|null */
    public function load(): ?array
    {
        if (!$this->authorized()) {
            return null;
        }
        $directory = dirname($this->path);
        $owner = $this->ownerUid();
        $directoryStat = @lstat($directory);
        $directoryReal = @realpath($directory);
        if (!is_array($directoryStat) || (($directoryStat['mode'] & 0170000) !== 0040000)
            || $directoryStat['uid'] !== $owner || ($directoryStat['mode'] & 0022) !== 0
            || !is_string($directoryReal) || $directoryReal !== $directory) {
            return null;
        }
        $stat = @lstat($this->path);
        if ($stat === false && !file_exists($this->path) && !is_link($this->path)) {
            return self::defaults();
        }
        if (!is_array($stat) || (($stat['mode'] & 0170000) !== 0100000)
            || $stat['uid'] !== $owner || $stat['nlink'] !== 1 || ($stat['mode'] & 0777) !== 0600
            || $stat['size'] > self::MAX_BYTES) {
            return null;
        }
        $handle = @fopen($this->path, 'rb');
        if (!is_resource($handle)) {
            return null;
        }
        $openedStat = fstat($handle);
        $content = stream_get_contents($handle, self::MAX_BYTES + 1);
        fclose($handle);
        if (!is_array($openedStat) || $openedStat['dev'] !== $stat['dev'] || $openedStat['ino'] !== $stat['ino']
            || !is_string($content) || strlen($content) > self::MAX_BYTES) {
            return null;
        }
        try {
            return self::normalize(json_decode($content, true, 8, JSON_THROW_ON_ERROR));
        } catch (\Throwable) {
            return null;
        }
    }

    /** @param mixed $policy */
    public function save(mixed $policy): bool
    {
        if (!$this->authorized()) {
            return false;
        }
        $normalized = self::normalize($policy);
        if ($normalized === null) {
            return false;
        }
        $directory = dirname($this->path);
        $directoryStat = @lstat($directory);
        $owner = $this->ownerUid();
        if (!is_array($directoryStat) || (($directoryStat['mode'] & 0170000) !== 0040000)
            || $directoryStat['uid'] !== $owner || ($directoryStat['mode'] & 0022) !== 0
            || @realpath($directory) !== $directory) {
            return false;
        }
        $existing = @lstat($this->path);
        if ($existing !== false && (!is_array($existing) || (($existing['mode'] & 0170000) !== 0100000)
            || $existing['uid'] !== $owner || $existing['nlink'] !== 1 || ($existing['mode'] & 0777) !== 0600)) {
            return false;
        }
        try {
            $temporary = $directory . '/.orm-security-report-policy-' . bin2hex(random_bytes(12));
            $handle = @fopen($temporary, 'xb');
            if (!is_resource($handle)) {
                return false;
            }
            $content = json_encode($normalized, JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR) . "\n";
            $written = fwrite($handle, $content);
            $flushed = fflush($handle);
            $synced = function_exists('fsync') ? fsync($handle) : true;
            $openedStat = fstat($handle);
            fclose($handle);
            if ($written !== strlen($content) || !$flushed || !$synced || !is_array($openedStat)
                || $openedStat['uid'] !== $owner || !@chmod($temporary, 0600)) {
                @unlink($temporary);
                return false;
            }
            if (!@rename($temporary, $this->path)) {
                @unlink($temporary);
                return false;
            }
            return true;
        } catch (\Throwable) {
            return false;
        }
    }

    /** @return array{version:int,thresholds:array{evictions_per_window:int,operations_per_second:int,auth_failures_per_window:int}} */
    public static function defaults(): array
    {
        return [
            'version' => 1,
            'thresholds' => [
                'evictions_per_window' => 0,
                'operations_per_second' => 0,
                'auth_failures_per_window' => 0,
            ],
        ];
    }

    /** @param mixed $policy @return array{version:int,thresholds:array{evictions_per_window:int,operations_per_second:int,auth_failures_per_window:int}}|null */
    public static function normalize(mixed $policy): ?array
    {
        if (!is_array($policy) || array_is_list($policy)
            || ($policy['version'] ?? null) !== 1 || !is_array($policy['thresholds'] ?? null)
            || array_is_list($policy['thresholds'])) {
            return null;
        }
        $policyKeys = array_keys($policy);
        sort($policyKeys);
        if ($policyKeys !== ['thresholds', 'version']) {
            return null;
        }
        $thresholds = $policy['thresholds'];
        $keys = array_keys($thresholds);
        sort($keys);
        if ($keys !== ['auth_failures_per_window', 'evictions_per_window', 'operations_per_second']) {
            return null;
        }
        foreach ($thresholds as $threshold) {
            if (!is_int($threshold) || $threshold < 0 || $threshold > self::MAX_THRESHOLD) {
                return null;
            }
        }
        return [
            'version' => 1,
            'thresholds' => [
                'evictions_per_window' => $thresholds['evictions_per_window'],
                'operations_per_second' => $thresholds['operations_per_second'],
                'auth_failures_per_window' => $thresholds['auth_failures_per_window'],
            ],
        ];
    }

    private function authorized(): bool
    {
        return function_exists('posix_geteuid') && posix_geteuid() === $this->ownerUid();
    }

    private function ownerUid(): int
    {
        return $this->expectedOwnerUid ?? 0;
    }
}
