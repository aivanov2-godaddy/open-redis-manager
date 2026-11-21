<?php
declare(strict_types=1);

require_once __DIR__ . '/../src/Orm/Cpanel/PodmanCacheDiscovery.php';

use Orm\Cpanel\PodmanCacheDiscovery;

if (PHP_OS_FAMILY !== 'Linux' || !function_exists('posix_geteuid')) {
    fwrite(STDOUT, "cPanel Podman discovery checks skipped: Linux Unix-socket ownership semantics are required.\n");
    exit(0);
}

$checks = 0;
$assert = static function (bool $condition, string $message) use (&$checks): void {
    ++$checks;
    if (!$condition) {
        fwrite(STDERR, "FAIL: {$message}\n");
        exit(1);
    }
};
$uid = posix_geteuid();
$home = sys_get_temp_dir() . '/orm-podman-' . bin2hex(random_bytes(5));
mkdir($home, 0700);
$root = $home . '/ea-podman.d';
mkdir($root, 0700);
$redisName = 'ea-redis62.ormtest.01';
$valkeyName = 'ea-valkey72.ormtest.02';
$stoppedName = 'ea-redis62.ormtest.03';
foreach ([$redisName, $valkeyName, $stoppedName, 'ea-redis62.someone.01'] as $name) {
    mkdir($root . '/' . $name, 0700);
}
$servers = [];
foreach ([[$redisName, 'redis.sock'], [$valkeyName, 'valkey.sock']] as [$container, $socketName]) {
    $socketPath = $root . '/' . $container . '/' . $socketName;
    $server = @stream_socket_server('unix://' . $socketPath, $errno, $error);
    if (!is_resource($server)) {
        fwrite(STDERR, "Unable to create the local Unix socket test fixture.\n");
        exit(1);
    }
    chmod($socketPath, 0600);
    $servers[] = $server;
}
$probed = [];
$results = PodmanCacheDiscovery::discover('ormtest', $home, $uid, static function (string $socket) use (&$probed): array {
    $probed[] = $socket;
    return [
        'reachable' => true,
        'version' => str_contains($socket, 'valkey') ? '7.2.6' : '6.2.24',
        'metrics' => [
            'used_memory' => '2048', 'used_memory_peak' => '4096', 'connected_clients' => '3',
            'uptime_in_seconds' => '600', 'instantaneous_ops_per_sec' => '12',
            'keyspace_hits' => '90', 'keyspace_misses' => '10', 'private_field' => 'must-not-escape',
        ],
    ];
});
$assert(count($results) === 3, 'discover current-account Redis and Valkey containers, including stopped ones');
$assert($results[0]['backend'] === 'redis' && $results[0]['status'] === 'reachable'
    && $results[0]['version'] === '6.2.24', 'verify Redis pod metadata and bounded health data');
$assert(($results[0]['metrics'] ?? null) === [
    'memory_used_bytes' => 2048, 'memory_peak_bytes' => 4096, 'connected_clients' => 3,
    'uptime_seconds' => 600, 'commands_per_second' => 12, 'keyspace_hits' => 90, 'keyspace_misses' => 10,
] && is_int($results[0]['metrics_sampled_at'] ?? null),
    'return only normalized allowlisted metrics with a current sample time');
$valkeyResult = array_values(array_filter($results, static fn (array $entry): bool => $entry['container'] === $valkeyName))[0] ?? null;
$stoppedResult = array_values(array_filter($results, static fn (array $entry): bool => $entry['container'] === $stoppedName))[0] ?? null;
$assert(is_array($valkeyResult) && $valkeyResult['backend'] === 'valkey'
    && str_ends_with($valkeyResult['socket_path'], '/valkey.sock'),
    'use the distinct cPanel Valkey socket name');
$assert(is_array($stoppedResult) && $stoppedResult['status'] === 'socket-missing',
    'identify an installed account container whose service socket is absent');
$assert(count($probed) === 2 && !str_contains(implode("\n", $probed), 'someone'),
    'never probe a container belonging to another account');

if (function_exists('pcntl_fork')) {
    $probeName = 'ea-redis62.ormtest.03';
    mkdir($root . '/' . $probeName, 0700);
    $probeSocket = $root . '/' . $probeName . '/redis.sock';
    $probeServer = @stream_socket_server('unix://' . $probeSocket, $errno, $error);
    if (!is_resource($probeServer)) {
        fwrite(STDERR, "Unable to create the native PING socket fixture.\n");
        exit(1);
    }
    chmod($probeSocket, 0600);
    $child = pcntl_fork();
    if ($child === -1) {
        fwrite(STDERR, "Unable to fork the native PING fixture.\n");
        exit(1);
    }
    if ($child === 0) {
        $client = @stream_socket_accept($probeServer, 3);
        if (!is_resource($client)) {
            exit(2);
        }
        stream_set_timeout($client, 1);
        $readCommand = static function ($client): string {
            $request = '';
            while (strlen($request) < 14) {
                $chunk = @fread($client, 14 - strlen($request));
                if (!is_string($chunk) || $chunk === '') {
                    break;
                }
                $request .= $chunk;
            }
            return $request;
        };
        $valid = $readCommand($client) === "*1\r\n\$4\r\nPING\r\n";
        if ($valid) {
            fwrite($client, "+PONG\r\n");
            $valid = $readCommand($client) === "*1\r\n\$4\r\nINFO\r\n";
        }
        $info = "# Server\r\nredis_version:7.2.4\r\n# Clients\r\nconnected_clients:2\r\n# Memory\r\nused_memory:12345\r\nused_memory_peak:23456\r\n# Stats\r\ninstantaneous_ops_per_sec:7\r\nkeyspace_hits:8\r\nkeyspace_misses:2\r\n";
        if ($valid) {
            fwrite($client, '$' . strlen($info) . "\r\n" . $info . "\r\n");
        }
        fclose($client);
        fclose($probeServer);
        exit($valid ? 0 : 3);
    }
    $method = new ReflectionMethod(PodmanCacheDiscovery::class, 'probePing');
    $probeResult = $method->invoke(null, $probeSocket);
    pcntl_waitpid($child, $childStatus);
    $fixturePassed = ($probeResult['reachable'] ?? false) === true
        && ($probeResult['version'] ?? null) === '7.2.4'
        && ($probeResult['metrics']['memory_used_bytes'] ?? null) === 12345
        && ($probeResult['metrics']['keyspace_hits'] ?? null) === 8
        && pcntl_wifexited($childStatus) && pcntl_wexitstatus($childStatus) === 0;
    if (!$fixturePassed) {
        fwrite(STDERR, 'PING fixture diagnostics: ' . json_encode([
            'reachable' => $probeResult['reachable'] ?? null,
            'version' => $probeResult['version'] ?? null,
            'metrics' => $probeResult['metrics'] ?? null,
            'child_exited' => pcntl_wifexited($childStatus),
            'child_exit_code' => pcntl_wifexited($childStatus) ? pcntl_wexitstatus($childStatus) : null,
        ]) . "\n");
    }
    $assert(($probeResult['reachable'] ?? false) === true
        && ($probeResult['version'] ?? null) === '7.2.4'
        && ($probeResult['metrics']['memory_used_bytes'] ?? null) === 12345
        && ($probeResult['metrics']['keyspace_hits'] ?? null) === 8
        && pcntl_wifexited($childStatus) && pcntl_wexitstatus($childStatus) === 0,
        'perform bounded read-only RESP PING and INFO metrics collection without PhpRedis');
    fclose($probeServer);
    @unlink($probeSocket);
    @rmdir($root . '/' . $probeName);
}

foreach ($servers as $server) {
    fclose($server);
}
foreach ([$root . '/' . $redisName . '/redis.sock', $root . '/' . $valkeyName . '/valkey.sock'] as $socket) {
    @unlink($socket);
}
foreach ([$redisName, $valkeyName, $stoppedName, 'ea-redis62.someone.01'] as $name) {
    @rmdir($root . '/' . $name);
}
@rmdir($root);
@rmdir($home);
fwrite(STDOUT, "cPanel Podman discovery checks passed: {$checks}\n");
