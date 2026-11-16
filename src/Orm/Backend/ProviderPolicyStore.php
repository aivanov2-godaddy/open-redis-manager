<?php
declare(strict_types=1);

namespace Orm\Backend;

/** Root-owned provider policy for package-scoped ORM resource limits. */
final class ProviderPolicyStore
{
    private const PATH = '/etc/orm-provider-policy.json';
    private const MAX_BYTES = 32768;

    public function __construct(
        private readonly string $path = self::PATH,
        private readonly ?int $expectedOwnerUid = null,
    ) {
    }

    /** @return array{version:int,mode:string,default:array{enabled:bool,max_memory_mib:int,backup_retention:int},packages:array<string,array{enabled:bool,max_memory_mib:int,backup_retention:int}>}|null */
    public function load(): ?array
    {
        if (!$this->authorized()) {
            return null;
        }
        $directory = dirname($this->path);
        $directoryStat = @lstat($directory);
        $owner = $this->ownerUid();
        if (!is_array($directoryStat) || (($directoryStat['mode'] & 0170000) !== 0040000)
            || $directoryStat['uid'] !== $owner || ($directoryStat['mode'] & 0022) !== 0) {
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
            $decoded = json_decode($content, true, 8, JSON_THROW_ON_ERROR);
        } catch (\Throwable) {
            return null;
        }
        return self::normalize($decoded);
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
            || $directoryStat['uid'] !== $owner || ($directoryStat['mode'] & 0022) !== 0) {
            return false;
        }
        $existing = @lstat($this->path);
        if ($existing !== false && (!is_array($existing) || (($existing['mode'] & 0170000) !== 0100000)
            || $existing['uid'] !== $owner || $existing['nlink'] !== 1 || ($existing['mode'] & 0777) !== 0600)) {
            return false;
        }
        try {
            $temporary = $directory . '/.orm-provider-policy-' . bin2hex(random_bytes(12));
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

    /** @return array{version:int,mode:string,default:array{enabled:bool,max_memory_mib:int,backup_retention:int},packages:array{}} */
    public static function defaults(): array
    {
        return [
            'version' => 1,
            'mode' => 'report-only',
            'default' => ['enabled' => true, 'max_memory_mib' => 64, 'backup_retention' => 3],
            'packages' => [],
        ];
    }

    /** @param mixed $policy */
    public static function normalize(mixed $policy): ?array
    {
        if (!is_array($policy) || array_is_list($policy)) {
            return null;
        }
        $keys = array_keys($policy);
        sort($keys);
        if ($keys !== ['default', 'mode', 'packages', 'version'] || $policy['version'] !== 1
            || !in_array($policy['mode'], ['report-only', 'enforce'], true)
            || !is_array($policy['packages']) || array_is_list($policy['packages']) && $policy['packages'] !== []
            || count($policy['packages']) > 1000) {
            return null;
        }
        $default = self::normalizeLimits($policy['default']);
        if ($default === null) {
            return null;
        }
        $packages = [];
        foreach ($policy['packages'] as $name => $limits) {
            if (!is_string($name) || $name === 'default'
                || preg_match('/\A[a-zA-Z0-9_.-]{1,64}\z/', $name) !== 1) {
                return null;
            }
            $normalizedLimits = self::normalizeLimits($limits);
            if ($normalizedLimits === null) {
                return null;
            }
            $packages[$name] = $normalizedLimits;
        }
        ksort($packages, SORT_STRING);
        return ['version' => 1, 'mode' => $policy['mode'], 'default' => $default, 'packages' => $packages];
    }

    /** @param mixed $limits */
    private static function normalizeLimits(mixed $limits): ?array
    {
        if (!is_array($limits) || array_is_list($limits)) {
            return null;
        }
        $keys = array_keys($limits);
        sort($keys);
        if ($keys !== ['backup_retention', 'enabled', 'max_memory_mib'] || !is_bool($limits['enabled'])
            || !is_int($limits['max_memory_mib']) || $limits['max_memory_mib'] < 8 || $limits['max_memory_mib'] > 64
            || !is_int($limits['backup_retention']) || $limits['backup_retention'] < 2 || $limits['backup_retention'] > 3) {
            return null;
        }
        return [
            'enabled' => $limits['enabled'],
            'max_memory_mib' => $limits['max_memory_mib'],
            'backup_retention' => $limits['backup_retention'],
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
