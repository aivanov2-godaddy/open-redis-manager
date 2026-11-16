<?php
declare(strict_types=1);

require dirname(__DIR__) . '/src/Orm/Cpanel/DiagnosticReport.php';

use Orm\Cpanel\DiagnosticReport;

$checks = 0;
$assert = static function (bool $condition, string $message) use (&$checks): void {
    ++$checks;
    if (!$condition) {
        fwrite(STDERR, "FAIL: {$message}\n");
        exit(1);
    }
};

$timestamp = 1_735_689_600;
$configuration = [
    'memory_mib' => 48,
    'maxmemory_policy' => 'allkeys-lru',
    'maxclients' => 80,
    'timeout' => 30,
];
$status = [
    'success' => true,
    'state' => 'running',
    'preset' => 'wordpress',
    'config' => $configuration,
    'username' => 'secret-account-name',
    'host' => 'private-host.example',
    'socket_path' => '/private/account/redis.sock',
    'password' => 'secret-password',
];
$metrics = [
    'success' => true,
    'sampled_at' => $timestamp,
    'stale' => false,
    'retained' => true,
    'memory_used_bytes' => 18_000_000,
    'memory_peak_bytes' => 22_000_000,
    'connected_clients' => 4,
    'uptime_seconds' => 259_200,
    'commands_per_second' => 126,
    'keyspace_hits' => 9_760,
    'keyspace_misses' => 240,
    'key' => 'private-redis-key',
    'value' => 'application-payload',
    'token' => 'secret-token',
];

$report = DiagnosticReport::build($status, $metrics, $timestamp);
$assert(array_keys($report) === ['generated_at_utc', 'schema_version', 'instance', 'connection', 'metrics', 'excluded_data'],
    'emit only the fixed top-level report fields');
$assert($report['generated_at_utc'] === '2025-01-01T00:00:00+00:00', 'format the report timestamp in UTC');
$assert($report['schema_version'] === 1, 'include a stable report schema version');
$assert($report['instance'] === [
    'state' => 'running',
    'preset' => 'wordpress',
    'configuration' => $configuration,
], 'include only allowlisted instance state and bounded configuration');
$assert($report['connection'] === [
    'transport' => 'account_private_unix_socket',
    'tcp_enabled' => false,
    'redis_auth_configured' => false,
], 'describe the fixed connection model without exporting a host or path');
$assert($report['metrics'] === [
    'captured_at_utc' => '2025-01-01T00:00:00+00:00',
    'stale' => false,
    'sample_saved' => true,
    'memory_used_bytes' => 18_000_000,
    'memory_peak_bytes' => 22_000_000,
    'connected_clients' => 4,
    'uptime_seconds' => 259_200,
    'commands_per_second' => 126,
    'keyspace_hits' => 9_760,
    'keyspace_misses' => 240,
], 'include only bounded numeric metrics and the sample flags');
$staleReport = DiagnosticReport::build(null, array_replace($metrics, ['stale' => true]), $timestamp);
$assert(is_array($staleReport['metrics']) && $staleReport['metrics']['stale'] === true
    && $staleReport['metrics']['sample_saved'] === true, 'preserve a valid stale retained sample marker');
$encoded = json_encode($report, JSON_THROW_ON_ERROR);
foreach (['secret-account-name', 'private-host.example', '/private/account', 'secret-password', 'private-redis-key', 'application-payload', 'secret-token'] as $privateValue) {
    $assert(!str_contains($encoded, $privateValue), 'exclude private input value: ' . $privateValue);
}

$failedStatus = DiagnosticReport::build(['success' => false, 'state' => 'running', 'preset' => 'generic'], null, $timestamp);
$assert($failedStatus['instance'] === ['state' => 'unavailable', 'preset' => null, 'configuration' => null],
    'normalize a failed status response without exposing its details');
$assert($failedStatus['metrics'] === null, 'represent unavailable metrics as null');

$invalidState = DiagnosticReport::build(['success' => true, 'state' => 'private-state', 'preset' => '../secret'], null, $timestamp);
$assert($invalidState['instance'] === ['state' => 'unavailable', 'preset' => null, 'configuration' => null],
    'reject unrecognized state and preset values');
$invalidConfiguration = DiagnosticReport::build([
    'success' => true,
    'state' => 'running',
    'preset' => 'generic',
    'config' => $configuration + ['host' => 'private-host.example'],
], null, $timestamp);
$assert($invalidConfiguration['instance']['configuration'] === null, 'reject configuration with unexpected fields');
$invalidMemory = DiagnosticReport::build([
    'success' => true,
    'state' => 'running',
    'preset' => 'generic',
    'config' => array_replace($configuration, ['memory_mib' => 4096]),
], null, $timestamp);
$assert($invalidMemory['instance']['configuration'] === null, 'reject configuration with out-of-range memory');
$staleWithoutSavedSample = DiagnosticReport::build(null, array_replace($metrics, ['stale' => true, 'retained' => false]), $timestamp);
$assert($staleWithoutSavedSample['metrics'] === null, 'reject stale metrics that were not retained');
$negativeMetric = DiagnosticReport::build(null, array_replace($metrics, ['memory_used_bytes' => -1]), $timestamp);
$assert($negativeMetric['metrics'] === null, 'reject negative metric values');

$page = file_get_contents(dirname(__DIR__) . '/packaging/cpanel/files/orm/index.live.php');
$assert(is_string($page), 'read the installed cPanel page');
$assert(str_contains($page, 'DiagnosticReport.php'), 'load the packaged diagnostics report class');
$assert(str_contains($page, "\$brokerVerified && (\$_SERVER['REQUEST_METHOD'] ?? null) === 'GET'"),
    'require the verified cPanel account and a GET request for downloads');
$assert(str_contains($page, "\$_GET['orm_diagnostics'] ?? null) === 'download'"), 'accept only the explicit diagnostics download route');
$assert(str_contains($page, 'Cache-Control: no-store, private'), 'prevent caching diagnostics exports');
$assert(str_contains($page, 'Content-Disposition: attachment; filename="orm-diagnostics-'),
    'use a server-generated fixed download filename');
$assert(str_contains($page, "header('Content-Length: ' . strlen(\$diagnosticJson)"), 'send the JSON report byte length');
$assert(str_contains($page, 'JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR'),
    'encode the report deterministically and fail closed on serialization errors');
$assert(str_contains($page, 'Preview diagnostics JSON'), 'provide an accessible report preview');
$assert(str_contains($page, 'Download diagnostics JSON'), 'provide an explicit report download action');
$assert(str_contains($page, 'command output'), 'explain report exclusions in the interface');

$packageLib = file_get_contents(dirname(__DIR__) . '/packaging/lib.sh');
$installer = file_get_contents(dirname(__DIR__) . '/packaging/install.sh');
$uninstaller = file_get_contents(dirname(__DIR__) . '/packaging/uninstall.sh');
$assert(is_string($packageLib) && is_string($installer) && is_string($uninstaller), 'read the packaging lifecycle scripts');
$assert(str_contains($packageLib, 'src/Orm/Cpanel/DiagnosticReport.php'),
    'guard and track the diagnostics class as an exact installed file');
$assert(str_contains($installer, 'install -m 0644 "$ORM_REPO_ROOT/src/Orm/Cpanel/DiagnosticReport.php"'),
    'install the report helper for the cPanel page');
$assert(str_contains($uninstaller, 'src/Orm/Cpanel/DiagnosticReport.php'),
    'remove the report helper through the exact-file uninstall lifecycle');

fwrite(STDOUT, "cPanel diagnostic report checks passed: {$checks}\n");
