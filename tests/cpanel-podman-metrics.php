<?php
declare(strict_types=1);

require_once __DIR__ . '/../src/Orm/Cpanel/PodmanCacheDiscovery.php';

use Orm\Cpanel\PodmanCacheDiscovery;

$checks = 0;
$assert = static function (bool $condition, string $message) use (&$checks): void {
    ++$checks;
    if (!$condition) {
        fwrite(STDERR, "FAIL: {$message}\n");
        exit(1);
    }
};
$parse = new ReflectionMethod(PodmanCacheDiscovery::class, 'parseInfoText');
$normalize = new ReflectionMethod(PodmanCacheDiscovery::class, 'normalizeMetrics');
$info = $parse->invoke(null, "# Server\r\nredis_version:7.2.4\r\n# Memory\r\nused_memory:12345\r\nused_memory_peak:23456\r\n# Clients\r\nconnected_clients:2\r\n# Stats\r\ninstantaneous_ops_per_sec:7\r\nkeyspace_hits:8\r\nkeyspace_misses:2\r\ndb0:keys=99,expires=3\r\nraw_secret:do-not-keep\r\n");
$assert($info === [
    'redis_version' => '7.2.4', 'used_memory' => '12345', 'used_memory_peak' => '23456',
    'connected_clients' => '2', 'instantaneous_ops_per_sec' => '7', 'keyspace_hits' => '8',
    'keyspace_misses' => '2',
], 'keep only fixed version and metric fields from INFO output');
$metrics = $normalize->invoke(null, $info);
$assert($metrics === [
    'memory_used_bytes' => 12345, 'memory_peak_bytes' => 23456, 'connected_clients' => 2,
    'commands_per_second' => 7, 'keyspace_hits' => 8, 'keyspace_misses' => 2,
], 'normalize INFO counters to a stable bounded schema');
$invalid = $normalize->invoke(null, [
    'used_memory' => '-1', 'connected_clients' => '1e9', 'keyspace_hits' => '99999999999999999',
    'memory_peak_bytes' => 400,
]);
$assert($invalid === ['memory_peak_bytes' => 400], 'reject negative, exponent, and out-of-range values while allowing normalized fields');
$assert($normalize->invoke(null, []) === null, 'leave the metrics sample unknown if no allowlisted metric is valid');
$oversized = $parse->invoke(null, str_repeat('x', 65537));
$assert($oversized === [], 'discard INFO output that exceeds the fixed response bound');

fwrite(STDOUT, "cPanel Podman metrics checks passed: {$checks}\n");
