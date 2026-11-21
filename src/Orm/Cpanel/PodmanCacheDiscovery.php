<?php
declare(strict_types=1);

namespace Orm\Cpanel;

/** Discovers only the current cPanel account's cPanel-managed Redis/Valkey pod sockets. */
final class PodmanCacheDiscovery
{
    private const MAX_CONTAINERS = 32;
    private const MAX_INFO_BYTES = 65536;
    private const MAX_METRIC_VALUE = 9_000_000_000_000_000;

    /**
     * @param null|callable(string): array{reachable:bool,version:?string} $probe
     * @return list<array{container:string,backend:string,version:?string,socket_path:string,status:string,metrics:?array,metrics_sampled_at:?int}>
     */
    public static function forCurrentAccount(string $username, ?callable $probe = null): array
    {
        $identity = self::currentAccountIdentity($username);
        return $identity === null ? [] : self::discover($username, $identity['home'], $identity['uid'], $probe);
    }

    /**
     * Distinguish an account with no EA Podman directory from one whose inventory
     * cannot be trusted or read. The existing list API remains backward compatible.
     *
     * @param null|callable(string): array{reachable:bool,version:?string} $probe
     * @return array{status:string,caches:list<array{container:string,backend:string,version:?string,socket_path:string,status:string,metrics:?array,metrics_sampled_at:?int}>}
     */
    public static function currentAccountInventory(
        string $username,
        ?callable $probe = null,
        ?callable $identityResolver = null
    ): array
    {
        $empty = ['status' => 'unavailable', 'caches' => []];
        if ($identityResolver === null) {
            $identity = self::currentAccountIdentity($username);
        } else {
            try {
                $identity = $identityResolver($username);
            } catch (\Throwable) {
                $identity = null;
            }
        }
        if ($identity === null) {
            return $empty;
        }
        if (!is_array($identity) || !is_string($identity['home'] ?? null) || !is_int($identity['uid'] ?? null)
            || $identity['uid'] < 1 || !str_starts_with($identity['home'], '/') || str_contains($identity['home'], "\0")) {
            return $empty;
        }
        $homeStat = @lstat($identity['home']);
        if (!is_array($homeStat) || (($homeStat['mode'] & 0170000) !== 0040000)
            || $homeStat['uid'] !== $identity['uid'] || @realpath($identity['home']) !== $identity['home']) {
            return $empty;
        }
        $root = $identity['home'] . '/ea-podman.d';
        $rootStat = @lstat($root);
        if (!is_array($rootStat)) {
            return !file_exists($root) && !is_link($root)
                ? ['status' => 'not-installed', 'caches' => []] : $empty;
        }
        if (($rootStat['mode'] & 0170000) !== 0040000 || $rootStat['uid'] !== $identity['uid']
            || ($rootStat['mode'] & 0022) !== 0 || @realpath($root) !== $root) {
            return $empty;
        }
        $names = @scandir($root);
        if (!is_array($names) || count($names) > self::MAX_CONTAINERS + 2) {
            return $empty;
        }
        $caches = self::discover($username, $identity['home'], $identity['uid'], $probe);
        if ($caches !== []) {
            return ['status' => 'installed', 'caches' => $caches];
        }
        foreach ($names as $name) {
            if (is_string($name) && preg_match('/\Aea-(?:redis|valkey)[0-9]{2,4}\.' . preg_quote($username, '/') . '\.[0-9]{2,3}\z/', $name) === 1) {
                return $empty;
            }
        }
        return ['status' => 'not-installed', 'caches' => []];
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
            $metrics = is_array($probeResult) && is_array($probeResult['metrics'] ?? null)
                ? self::normalizeMetrics($probeResult['metrics']) : null;
            $results[] = [
                'container' => $name,
                'backend' => $containerInfo['backend'],
                'version' => $version,
                'socket_path' => $socket,
                'status' => $status,
                'metrics' => $metrics,
                'metrics_sampled_at' => $metrics !== null ? time() : null,
            ];
        }
        usort($results, static fn (array $left, array $right): int => strcmp($left['container'], $right['container']));
        return $results;
    }

    /** @return array{reachable:bool,version:?string,metrics:?array} */
    private static function probePing(string $socket): array
    {
        $connection = @stream_socket_client('unix://' . $socket, $errorCode, $errorMessage, 0.5, STREAM_CLIENT_CONNECT);
        if (!is_resource($connection)) {
            return ['reachable' => false, 'version' => null, 'metrics' => null];
        }
        stream_set_timeout($connection, 0, 500000);
        $sent = self::sendRespCommands($connection, [['PING'], ['INFO']]);
        $pong = $sent && self::readResp($connection, 64) === '+PONG';
        $pingTimedOut = (stream_get_meta_data($connection)['timed_out'] ?? false) === true;
        $infoText = $pong ? self::readResp($connection, self::MAX_INFO_BYTES) : null;
        fclose($connection);
        $info = is_string($infoText) ? self::parseInfoText($infoText) : [];
        $version = $info['redis_version'] ?? $info['valkey_version'] ?? null;
        return [
            'reachable' => !$pingTimedOut && $pong,
            'version' => is_string($version) ? $version : null,
            'metrics' => self::normalizeMetrics($info),
        ];
    }

    /** @param resource $connection @param list<list<string>> $commands */
    private static function sendRespCommands($connection, array $commands): bool
    {
        $request = '';
        foreach ($commands as $arguments) {
            $request .= '*' . count($arguments) . "\r\n";
            foreach ($arguments as $argument) {
                $request .= '$' . strlen($argument) . "\r\n" . $argument . "\r\n";
            }
        }
        $written = 0;
        while ($written < strlen($request)) {
            $count = @fwrite($connection, substr($request, $written));
            if (!is_int($count) || $count < 1) {
                return false;
            }
            $written += $count;
        }
        return true;
    }

    /** @param resource $connection */
    private static function readResp($connection, int $maximumBytes): ?string
    {
        $header = @fgets($connection, 64);
        if (!is_string($header)) {
            return null;
        }
        if (preg_match('/\A\$([0-9]{1,6})\r?\n\z/', $header, $matches) !== 1) {
            return str_ends_with($header, "\r\n") ? trim($header) : null;
        }
        $length = (int)$matches[1];
        if ($length > $maximumBytes) {
            return null;
        }
        $body = '';
        while (strlen($body) < $length + 2) {
            $chunk = @fread($connection, $length + 2 - strlen($body));
            if (!is_string($chunk) || $chunk === '') {
                return null;
            }
            $body .= $chunk;
        }
        return str_ends_with($body, "\r\n") ? substr($body, 0, $length) : null;
    }

    /** @return array<string,string> */
    private static function parseInfoText(string $text): array
    {
        if (strlen($text) > self::MAX_INFO_BYTES) {
            return [];
        }
        $allowed = [
            'redis_version', 'valkey_version', 'used_memory', 'used_memory_peak', 'connected_clients',
            'uptime_in_seconds', 'instantaneous_ops_per_sec', 'keyspace_hits', 'keyspace_misses',
        ];
        $values = [];
        foreach (preg_split('/\r?\n/', $text) ?: [] as $line) {
            if ($line === '' || $line[0] === '#' || !str_contains($line, ':')) {
                continue;
            }
            [$key, $value] = explode(':', $line, 2);
            if (in_array($key, $allowed, true) && strlen($value) <= 32) {
                $values[$key] = $value;
            }
        }
        return $values;
    }

    /** @return ?array<string,int> */
    private static function normalizeMetrics(array $info): ?array
    {
        $fields = [
            'used_memory' => 'memory_used_bytes',
            'used_memory_peak' => 'memory_peak_bytes',
            'connected_clients' => 'connected_clients',
            'uptime_in_seconds' => 'uptime_seconds',
            'instantaneous_ops_per_sec' => 'commands_per_second',
            'keyspace_hits' => 'keyspace_hits',
            'keyspace_misses' => 'keyspace_misses',
        ];
        $metrics = [];
        foreach ($fields as $source => $target) {
            $value = $info[$source] ?? $info[$target] ?? null;
            if (is_int($value)) {
                $number = $value;
            } elseif (is_string($value) && preg_match('/\A[0-9]{1,16}\z/', $value) === 1) {
                $number = (int)$value;
            } else {
                continue;
            }
            if ($number >= 0 && $number <= self::MAX_METRIC_VALUE) {
                $metrics[$target] = $number;
            }
        }
        return $metrics === [] ? null : $metrics;
    }
}
