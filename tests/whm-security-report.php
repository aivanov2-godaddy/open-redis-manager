<?php
declare(strict_types=1);

require dirname(__DIR__) . '/src/Orm/Security/WhmSecurityReport.php';

use Orm\Security\WhmSecurityReport;

$checks = 0;
$assert = static function (bool $condition, string $message) use (&$checks): void {
    ++$checks;
    if (!$condition) {
        fwrite(STDERR, "FAIL: {$message}\n");
        exit(1);
    }
};
$now = 1794850000;
$fleet = [
    'success' => true,
    'partial' => false,
    'managed_count' => 5,
    'metrics' => [
        'fresh_accounts' => 5,
        'high_memory_accounts' => 1,
        'high_client_accounts' => 2,
        'low_hit_ratio_accounts' => 1,
        'latest_sampled_at' => $now - 60,
        'rate_accounts' => 5,
        'rate_missing_accounts' => 0,
        'eviction_activity_accounts' => 2,
        'max_evictions_per_window' => 7,
        'max_operations_per_second' => 120,
        'rate_window_min_seconds' => 3600,
        'rate_window_max_seconds' => 7200,
        'rate_window_earliest_start_at' => $now - 7200,
        'rate_window_latest_end_at' => $now - 60,
    ],
];
$audit = [
    'success' => true,
    'partial' => false,
    'sources' => [['status' => 'complete'], ['status' => 'complete']],
    'records' => [
        ['timestamp_utc' => gmdate('Y-m-d\TH:i:s\Z', $now - 300), 'action' => 'auth.rotate', 'result' => 'success', 'account' => 'testacct'],
        ['timestamp_utc' => gmdate('Y-m-d\TH:i:s\Z', $now - 120), 'action' => 'auth.disable', 'result' => 'auth_disable_failed', 'account' => 'testacct'],
        ['timestamp_utc' => gmdate('Y-m-d\TH:i:s\Z', $now - 90000), 'action' => 'auth.rotate', 'result' => 'failed', 'account' => 'oldacct'],
        ['timestamp_utc' => gmdate('Y-m-d\TH:i:s\Z', $now - 60), 'action' => 'auth.rotate', 'result' => 'success', 'account' => 'unrelated', 'password' => 'report-secret-canary'],
    ],
];
$report = WhmSecurityReport::build($fleet, $audit, $now);
$byCategory = array_column($report['findings'], null, 'category');
$assert($report['mode'] === 'report-only' && !$report['partial'], 'produce a complete advisory-only report when inputs are complete');
$assert(($byCategory['memory_pressure']['count'] ?? null) === 1
    && ($byCategory['client_pressure']['count'] ?? null) === 2
    && ($byCategory['low_hit_ratio']['count'] ?? null) === 1,
    'report bounded memory, client, and low-hit-ratio evidence');
$assert(($byCategory['eviction_rate']['count'] ?? null) === 2
    && str_contains($byCategory['eviction_rate']['evidence'], '3600–7200 seconds')
    && str_contains($byCategory['eviction_rate']['evidence'], gmdate('Y-m-d\TH:i:s\Z', $now - 7200))
    && ($byCategory['operation_rate']['count'] ?? null) === 5
    && str_contains($byCategory['operation_rate']['evidence'], '120 operations per second')
    && str_contains($byCategory['operation_rate']['evidence'], 'not an abuse verdict'),
    'report measured counter rates with their actual window bounds and neutral interpretation');
$assert(($byCategory['auth_management_events']['count'] ?? null) === 3
    && str_contains($byCategory['auth_management_events']['evidence'], '1 unsuccessful')
    && str_contains($byCategory['auth_management_events']['evidence'], 'not Redis client login attempts'),
    'count only normalized AUTH management events in the bounded 24-hour window');
$encoded = json_encode($report, JSON_THROW_ON_ERROR);
$assert(!str_contains($encoded, 'testacct') && !str_contains($encoded, 'report-secret-canary'),
    'omit account names and secret-like input from the report');
$assert(isset($report['unmeasured']['credential_strength'])
    && isset($report['unmeasured']['client_authentication_failures'])
    && !isset($report['unmeasured']['eviction_rate']) && !isset($report['unmeasured']['operation_rate']),
    'explicitly disclose signal categories that are not measured');

$legacyFleet = $fleet;
foreach (['rate_accounts', 'rate_missing_accounts', 'eviction_activity_accounts', 'max_evictions_per_window',
    'max_operations_per_second', 'rate_window_min_seconds', 'rate_window_max_seconds',
    'rate_window_earliest_start_at', 'rate_window_latest_end_at'] as $field) {
    unset($legacyFleet['metrics'][$field]);
}
$legacyReport = WhmSecurityReport::build($legacyFleet, $audit, $now);
$legacyCategories = array_column($legacyReport['findings'], null, 'category');
$assert($legacyReport['partial'] && $legacyCategories['eviction_rate']['count'] === null
    && $legacyCategories['operation_rate']['count'] === null,
    'keep older brokers readable and show new counter signals as unknown until the extended schema is available');
$staleFleet = $fleet;
$staleFleet['metrics']['fresh_accounts'] = 0;
$staleFleet['metrics']['latest_sampled_at'] = 0;
$staleFleet['metrics']['high_memory_accounts'] = 0;
$staleFleet['metrics']['high_client_accounts'] = 0;
$staleFleet['metrics']['low_hit_ratio_accounts'] = 0;
$staleReport = WhmSecurityReport::build($staleFleet, $audit, $now);
$staleCategories = array_column($staleReport['findings'], null, 'category');
$assert($staleReport['partial'] && $staleCategories['metrics_unavailable']['count'] === null
    && $staleCategories['operation_rate']['count'] === 5,
    'preserve valid historical counter-rate evidence when the separate fresh metrics source is unavailable');

$partialAudit = $audit;
$partialAudit['partial'] = true;
$partial = WhmSecurityReport::build($fleet, $partialAudit, $now);
$partialCategories = array_column($partial['findings'], null, 'category');
$assert($partial['partial'] && array_key_exists('auth_audit_unavailable', $partialCategories)
    && $partialCategories['auth_audit_unavailable']['count'] === null,
    'show unknown authentication event coverage instead of zero when the audit source is partial');
$unavailable = WhmSecurityReport::build(null, null, $now);
$unavailableCategories = array_column($unavailable['findings'], null, 'category');
$assert($unavailable['partial'] && array_key_exists('metrics_unavailable', $unavailableCategories)
    && $unavailableCategories['metrics_unavailable']['count'] === null
    && array_key_exists('auth_audit_unavailable', $unavailableCategories)
    && $unavailableCategories['auth_audit_unavailable']['count'] === null,
    'represent unavailable inputs as unknown findings');

if (function_exists('posix_geteuid')) {
    $directory = sys_get_temp_dir() . '/orm-security-report-' . bin2hex(random_bytes(5));
    if (!mkdir($directory, 0700)) {
        fwrite(STDERR, "Unable to create the rate-limit test directory.\n");
        exit(1);
    }
    $ratePath = $directory . '/report-rate';
    $first = WhmSecurityReport::consumeRateLimit($now, $ratePath);
    $second = WhmSecurityReport::consumeRateLimit($now + 10, $ratePath);
    $third = WhmSecurityReport::consumeRateLimit($now + 60, $ratePath);
    $assert($first === ['allowed' => true, 'retry_after' => 0], 'allow the first report in the interval');
    $assert($second === ['allowed' => false, 'retry_after' => 50], 'throttle repeated report requests and return a bounded retry delay');
    $assert($third === ['allowed' => true, 'retry_after' => 0], 'allow the next report at the end of the interval');

    $unsafeDirectory = $directory . '/unsafe';
    mkdir($unsafeDirectory, 0777);
    chmod($unsafeDirectory, 0777);
    $unsafe = WhmSecurityReport::consumeRateLimit($now, $unsafeDirectory . '/report-rate');
    $assert(!$unsafe['allowed'], 'fail closed when the report rate-limit directory is group/world writable');

    @unlink($ratePath);
    @rmdir($unsafeDirectory);
    @rmdir($directory);
} else {
    fwrite(STDOUT, "POSIX rate-limit ownership checks skipped on this platform.\n");
}
fwrite(STDOUT, "WHM security report checks passed: {$checks}\n");
