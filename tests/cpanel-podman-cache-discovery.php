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
    return ['reachable' => true, 'version' => str_contains($socket, 'valkey') ? '7.2.6' : '6.2.24'];
});
$assert(count($results) === 3, 'discover current-account Redis and Valkey containers, including stopped ones');
$assert($results[0]['backend'] === 'redis' && $results[0]['status'] === 'reachable'
    && $results[0]['version'] === '6.2.24', 'verify Redis pod metadata and bounded health data');
$assert($results[1]['backend'] === 'valkey' && str_ends_with($results[1]['socket_path'], '/valkey.sock'),
    'use the distinct cPanel Valkey socket name');
$assert($results[2]['container'] === $stoppedName && $results[2]['status'] === 'socket-missing',
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
        $request = '';
        while (strlen($request) < 14) {
            $chunk = @fread($client, 14 - strlen($request));
            if (!is_string($chunk) || $chunk === '') {
                break;
            }
            $request .= $chunk;
        }
        $valid = $request === "*1\r\n\$4\r\nPING\r\n";
        if ($valid) {
            fwrite($client, "+PONG\r\n");
        }
        fclose($client);
        fclose($probeServer);
        exit($valid ? 0 : 3);
    }
    $method = new ReflectionMethod(PodmanCacheDiscovery::class, 'probePing');
    $probeResult = $method->invoke(null, $probeSocket);
    pcntl_waitpid($child, $childStatus);
    $fixturePassed = ($probeResult['reachable'] ?? false) === true
        && array_key_exists('version', $probeResult) && $probeResult['version'] === null
        && pcntl_wifexited($childStatus) && pcntl_wexitstatus($childStatus) === 0;
    if (!$fixturePassed) {
        fwrite(STDERR, 'PING fixture diagnostics: ' . json_encode([
            'reachable' => $probeResult['reachable'] ?? null,
            'version_is_null' => array_key_exists('version', $probeResult) && $probeResult['version'] === null,
            'child_exited' => pcntl_wifexited($childStatus),
            'child_exit_code' => pcntl_wifexited($childStatus) ? pcntl_wexitstatus($childStatus) : null,
        ]) . "\n");
    }
    $assert(($probeResult['reachable'] ?? false) === true
        && array_key_exists('version', $probeResult) && $probeResult['version'] === null
        && pcntl_wifexited($childStatus) && pcntl_wexitstatus($childStatus) === 0,
        'perform a bounded read-only RESP PING when the cPanel PHP runtime lacks PhpRedis');
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
