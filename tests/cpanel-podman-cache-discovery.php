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
foreach ([$redisName, $valkeyName, 'ea-redis62.someone.01'] as $name) {
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
$assert(count($results) === 2, 'discover only the current account Redis and Valkey container sockets');
$assert($results[0]['backend'] === 'redis' && $results[0]['status'] === 'reachable'
    && $results[0]['version'] === '6.2.24', 'verify Redis pod metadata and bounded health data');
$assert($results[1]['backend'] === 'valkey' && str_ends_with($results[1]['socket_path'], '/valkey.sock'),
    'use the distinct cPanel Valkey socket name');
$assert(count($probed) === 2 && !str_contains(implode("\n", $probed), 'someone'),
    'never probe a container belonging to another account');

foreach ($servers as $server) {
    fclose($server);
}
foreach ([$root . '/' . $redisName . '/redis.sock', $root . '/' . $valkeyName . '/valkey.sock'] as $socket) {
    @unlink($socket);
}
foreach ([$redisName, $valkeyName, 'ea-redis62.someone.01'] as $name) {
    @rmdir($root . '/' . $name);
}
@rmdir($root);
@rmdir($home);
fwrite(STDOUT, "cPanel Podman discovery checks passed: {$checks}\n");
