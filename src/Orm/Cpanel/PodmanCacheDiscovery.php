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
        $identity = self::currentAccountIdentity($username);
        return $identity === null ? [] : self::discover($username, $identity['home'], $identity['uid'], $probe);
    }

    /** @return null|array{container:string,backend:string,home:string,uid:int,directory:string,socket_path:string} */
    public static function containerForCurrentAccount(string $username, string $container): ?array
    {
        $identity = self::currentAccountIdentity($username);
        return $identity === null ? null
            : self::containerForIdentity($username, $identity['home'], $identity['uid'], $container);
    }

    /** @return null|array{container:string,backend:string,home:string,uid:int,directory:string,socket_path:string} */
    public static function containerForIdentity(string $username, string $home, int $uid, string $container): ?array
    {
        if (preg_match('/\A[a-zA-Z0-9_-]{1,16}\z/', $username) !== 1 || $uid < 1
            || !str_starts_with($home, '/') || str_contains($home, "\0")
            || preg_match('/\Aea-(redis|valkey)[0-9]{2,4}\.' . preg_quote($username, '/') . '\.[0-9]{2,3}\z/', $container, $matches) !== 1) {
            return null;
        }
        $homeStat = @lstat($home);
        if (!is_array($homeStat) || (($homeStat['mode'] & 0170000) !== 0040000)
            || $homeStat['uid'] !== $uid || @realpath($home) !== $home) {
            return null;
        }
        $root = $home . '/ea-podman.d';
        $rootStat = @lstat($root);
        if (!is_array($rootStat) || (($rootStat['mode'] & 0170000) !== 0040000)
            || $rootStat['uid'] !== $uid || ($rootStat['mode'] & 0022) !== 0 || @realpath($root) !== $root) {
            return null;
        }
        $directory = $root . '/' . $container;
        $directoryStat = @lstat($directory);
        if (!is_array($directoryStat) || (($directoryStat['mode'] & 0170000) !== 0040000)
            || $directoryStat['uid'] !== $uid || ($directoryStat['mode'] & 0022) !== 0
            || @realpath($directory) !== $directory) {
            return null;
        }
        return [
            'container' => $container,
            'backend' => $matches[1],
            'home' => $home,
            'uid' => $uid,
            'directory' => $directory,
            'socket_path' => $directory . '/' . ($matches[1] === 'redis' ? 'redis.sock' : 'valkey.sock'),
        ];
    }

    /** @return null|array{home:string,uid:int} */
    private static function currentAccountIdentity(string $username): ?array
    {
        if (preg_match('/\A[a-zA-Z0-9_-]{1,16}\z/', $username) !== 1
            || !function_exists('posix_geteuid') || !function_exists('posix_getpwuid')) {
            return null;
        }
        $uid = posix_geteuid();
        $identity = posix_getpwuid($uid);
        if (!is_array($identity) || ($identity['name'] ?? null) !== $username
            || !is_string($identity['dir'] ?? null) || $identity['dir'] === '') {
            return null;
        }
        $home = @realpath($identity['dir']);
        return is_string($home) ? ['home' => $home, 'uid' => $uid] : null;
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
        foreach ($names as $name) {
            if (!is_string($name)) {
                continue;
            }
            $containerInfo = self::containerForIdentity($username, $home, $uid, $name);
            if ($containerInfo === null) {
                continue;
            }
            $socket = $containerInfo['socket_path'];
            $socketStat = @lstat($socket);
            $socketExists = is_array($socketStat) && (($socketStat['mode'] & 0170000) === 0140000)
                && $socketStat['uid'] === $uid && ($socketStat['mode'] & 0007) === 0;
            if (!$socketExists && (file_exists($socket) || is_link($socket))) {
                continue;
            }
            $probeResult = null;
            if (!$socketExists) {
                $status = 'socket-missing';
            } elseif ($probe !== null) {
                try {
                    $probeResult = $probe($socket);
                } catch (\Throwable) {
                    $probeResult = null;
                }
            } elseif (class_exists('Redis')) {
                $probeResult = self::probeRedis($socket);
            } else {
                $probeResult = self::probePing($socket);
            }
            $version = is_array($probeResult) && is_string($probeResult['version'] ?? null)
                && preg_match('/\A[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}(?:[-+][A-Za-z0-9.-]{1,24})?\z/', $probeResult['version']) === 1
                ? $probeResult['version'] : null;
            if ($socketExists) {
                $status = !is_array($probeResult) ? 'not-checked'
                    : (($probeResult['reachable'] ?? false) === true ? 'reachable' : 'unavailable');
            }
            $results[] = [
                'container' => $name,
                'backend' => $containerInfo['backend'],
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

    /** @return array{reachable:bool,version:?string} */
    private static function probePing(string $socket): array
    {
        $connection = @stream_socket_client('unix://' . $socket, $errorCode, $errorMessage, 0.5, STREAM_CLIENT_CONNECT);
        if (!is_resource($connection)) {
            return ['reachable' => false, 'version' => null];
        }
        stream_set_timeout($connection, 0, 500000);
        $request = "*1\r\n\$4\r\nPING\r\n";
        $written = 0;
        while ($written < strlen($request)) {
            $count = @fwrite($connection, substr($request, $written));
            if (!is_int($count) || $count < 1) {
                fclose($connection);
                return ['reachable' => false, 'version' => null];
            }
            $written += $count;
        }
        $reply = @fgets($connection, 64);
        $timedOut = (stream_get_meta_data($connection)['timed_out'] ?? false) === true;
        fclose($connection);
        return [
            'reachable' => !$timedOut && is_string($reply) && trim($reply) === '+PONG',
            'version' => null,
        ];
    }
}
