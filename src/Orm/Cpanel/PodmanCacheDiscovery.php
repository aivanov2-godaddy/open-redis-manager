<?php
declare(strict_types=1);

namespace Orm\Cpanel;

/** Discovers only the current cPanel account's cPanel-managed Redis/Valkey pod sockets. */
final class PodmanCacheDiscovery
{
    private const MAX_CONTAINERS = 32;

    /**
     * @param null|callable(string): array{reachable:bool,version:?string} $probe
     * @return list<array{container:string,backend:string,version:?string,socket_path:string,status:string}>
     */
    public static function forCurrentAccount(string $username, ?callable $probe = null): array
    {
        if (preg_match('/\A[a-zA-Z0-9_-]{1,16}\z/', $username) !== 1
            || !function_exists('posix_geteuid') || !function_exists('posix_getpwuid')) {
            return [];
        }
        $uid = posix_geteuid();
        $identity = posix_getpwuid($uid);
        if (!is_array($identity) || ($identity['name'] ?? null) !== $username
            || !is_string($identity['dir'] ?? null) || $identity['dir'] === '') {
            return [];
        }
        $home = @realpath($identity['dir']);
        return is_string($home) ? self::discover($username, $home, $uid, $probe) : [];
    }

    /** @param null|callable(string): array{reachable:bool,version:?string} $probe */
    public static function discover(string $username, string $home, int $uid, ?callable $probe = null): array
    {
        if (preg_match('/\A[a-zA-Z0-9_-]{1,16}\z/', $username) !== 1 || $uid < 1
            || !str_starts_with($home, '/') || str_contains($home, "\0")) {
            return [];
        }
        $homeStat = @lstat($home);
        $homeReal = @realpath($home);
        if (!is_array($homeStat) || (($homeStat['mode'] & 0170000) !== 0040000)
            || $homeStat['uid'] !== $uid || !is_string($homeReal) || $homeReal !== $home) {
            return [];
        }
        $root = $home . '/ea-podman.d';
        $rootStat = @lstat($root);
        $rootReal = @realpath($root);
        if (!is_array($rootStat) || (($rootStat['mode'] & 0170000) !== 0040000)
            || $rootStat['uid'] !== $uid || ($rootStat['mode'] & 0022) !== 0
            || !is_string($rootReal) || $rootReal !== $root) {
            return [];
        }
        $names = @scandir($root);
        if (!is_array($names) || count($names) > self::MAX_CONTAINERS + 2) {
            return [];
        }
        $results = [];
        $pattern = '/\Aea-(redis|valkey)[0-9]{2,4}\.' . preg_quote($username, '/') . '\.[0-9]{2,3}\z/';
        foreach ($names as $name) {
            if (!is_string($name) || preg_match($pattern, $name, $matches) !== 1) {
                continue;
            }
            $directory = $root . '/' . $name;
            $directoryStat = @lstat($directory);
            if (!is_array($directoryStat) || (($directoryStat['mode'] & 0170000) !== 0040000)
                || $directoryStat['uid'] !== $uid || ($directoryStat['mode'] & 0022) !== 0
                || @realpath($directory) !== $directory) {
                continue;
            }
            $socket = $directory . '/' . ($matches[1] === 'redis' ? 'redis.sock' : 'valkey.sock');
            $socketStat = @lstat($socket);
            if (!is_array($socketStat) || (($socketStat['mode'] & 0170000) !== 0140000)
                || $socketStat['uid'] !== $uid || ($socketStat['mode'] & 0007) !== 0) {
                continue;
            }
            $probeResult = null;
            if ($probe !== null) {
                try {
                    $probeResult = $probe($socket);
                } catch (\Throwable) {
                    $probeResult = null;
                }
            } elseif (class_exists('Redis')) {
                $probeResult = self::probeRedis($socket);
            }
            $version = is_array($probeResult) && is_string($probeResult['version'] ?? null)
                && preg_match('/\A[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}(?:[-+][A-Za-z0-9.-]{1,24})?\z/', $probeResult['version']) === 1
                ? $probeResult['version'] : null;
            $status = !is_array($probeResult) ? 'not-checked'
                : (($probeResult['reachable'] ?? false) === true ? 'reachable' : 'unavailable');
            $results[] = [
                'container' => $name,
                'backend' => $matches[1],
                'version' => $version,
                'socket_path' => $socket,
                'status' => $status,
            ];
        }
        usort($results, static fn (array $left, array $right): int => strcmp($left['container'], $right['container']));
        return $results;
    }

    /** @return array{reachable:bool,version:?string} */
    private static function probeRedis(string $socket): array
    {
        try {
            $redis = new \Redis();
            if (!$redis->connect($socket, 0, 0.5)) {
                return ['reachable' => false, 'version' => null];
            }
            $pong = $redis->ping();
            $info = $redis->info('server');
            $redis->close();
            $version = is_array($info) ? ($info['redis_version'] ?? $info['valkey_version'] ?? null) : null;
            return [
                'reachable' => $pong === true || $pong === 'PONG' || $pong === '+PONG',
                'version' => is_string($version) ? $version : null,
            ];
        } catch (\Throwable) {
            return ['reachable' => false, 'version' => null];
        }
    }
}
