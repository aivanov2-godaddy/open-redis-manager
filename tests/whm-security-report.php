<?php
declare(strict_types=1);

require dirname(__DIR__) . '/src/Orm/Security/WhmSecurityReport.php';
require dirname(__DIR__) . '/src/Orm/Security/WhmSecurityReportPolicyStore.php';

use Orm\Security\WhmSecurityReport;
use Orm\Security\WhmSecurityReportPolicyStore;

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
        'auth_rate_accounts' => 5,
        'auth_rate_missing_accounts' => 0,
        'auth_failure_accounts' => 2,
        'max_auth_failures_per_window' => 4,
        'auth_rate_window_min_seconds' => 3600,
        'auth_rate_window_max_seconds' => 7200,
        'auth_rate_window_earliest_start_at' => $now - 7200,
        'auth_rate_window_latest_end_at' => $now - 60,
    ],
];
$audit = [
    'success' => true,
    'partial' => false,
    'sources' => [['status' => 'complete'], ['status' => 'complete']],
    'records' => [
        ['timestamp_utc' => gmdate('Y-m-d\TH:i:s\Z', $now - 300), 'action' => 'auth.rotate', 'result' => 'success', 'account' => 'testacct'],
        ['timestamp_utc' => gmdate('Y-m-d\TH:i:s\Z', $now - 240), 'action' => 'auth.enable', 'result' => 'success', 'account' => 'testacct'],
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
$assert(($byCategory['client_authentication_failures']['count'] ?? null) === 2
    && str_contains($byCategory['client_authentication_failures']['evidence'], 'largest per-account counter delta was 4')
    && str_contains($byCategory['client_authentication_failures']['evidence'], 'do not identify clients')
    && str_contains($byCategory['client_authentication_failures']['evidence'], '3600–7200 seconds')
    && str_contains($byCategory['client_authentication_failures']['recommendation'], 'no authentication-failure threshold'),
    'report anonymous supported authentication-failure counter evidence without identifying clients or alleging attacks');
$assert(($byCategory['auth_management_events']['count'] ?? null) === 4
    && str_contains($byCategory['auth_management_events']['evidence'], '1 unsuccessful')
    && str_contains($byCategory['auth_management_events']['evidence'], 'not Redis client login attempts'),
    'count only normalized AUTH management events in the bounded 24-hour window');
$encoded = json_encode($report, JSON_THROW_ON_ERROR);
$assert(!str_contains($encoded, 'testacct') && !str_contains($encoded, 'report-secret-canary'),
    'omit account names and secret-like input from the report');
$assert(isset($report['unmeasured']['credential_strength'])
    && !isset($report['unmeasured']['client_authentication_failures'])
    && !isset($report['unmeasured']['eviction_rate']) && !isset($report['unmeasured']['operation_rate']),
    'explicitly disclose signal categories that are not measured');

$thresholdPolicy = WhmSecurityReportPolicyStore::defaults();
$thresholdPolicy['thresholds'] = [
    'evictions_per_window' => 7,
    'operations_per_second' => 120,
    'auth_failures_per_window' => 4,
];
$thresholdReport = WhmSecurityReport::build($fleet, $audit, $now, $thresholdPolicy);
$thresholdFindings = array_column($thresholdReport['findings'], null, 'category');
$assert($thresholdReport['mode'] === 'report-only'
    && $thresholdFindings['eviction_rate']['severity'] === 'warning'
    && str_contains($thresholdFindings['eviction_rate']['evidence'], 'Report-only threshold: 7')
    && $thresholdFindings['operation_rate']['severity'] === 'warning'
    && str_contains($thresholdFindings['operation_rate']['evidence'], 'Report-only threshold: 120')
    && $thresholdFindings['client_authentication_failures']['severity'] === 'warning'
    && str_contains($thresholdFindings['client_authentication_failures']['evidence'], 'Report-only threshold: 4')
    && str_contains($thresholdFindings['client_authentication_failures']['recommendation'], 'does not identify a client'),
    'raise advisory severity at configured aggregate thresholds without taking enforcement action');

$belowThresholdPolicy = WhmSecurityReportPolicyStore::defaults();
$belowThresholdPolicy['thresholds'] = [
    'evictions_per_window' => 8,
    'operations_per_second' => 121,
    'auth_failures_per_window' => 5,
];
$belowThreshold = WhmSecurityReport::build($fleet, $audit, $now, $belowThresholdPolicy);
$belowThresholdFindings = array_column($belowThreshold['findings'], null, 'category');
$assert($belowThresholdFindings['eviction_rate']['severity'] === 'info'
    && $belowThresholdFindings['operation_rate']['severity'] === 'info'
    && $belowThresholdFindings['client_authentication_failures']['severity'] === 'info',
    'leave counter evidence informational below the configured inclusive threshold');

$disabledReport = WhmSecurityReport::build($fleet, $audit, $now, WhmSecurityReportPolicyStore::defaults());
$disabledFindings = array_column($disabledReport['findings'], null, 'category');
$assert($disabledFindings['eviction_rate']['severity'] === 'info'
    && $disabledFindings['operation_rate']['severity'] === 'info'
    && $disabledFindings['client_authentication_failures']['severity'] === 'info',
    'keep optional abuse thresholds disabled by default');

$invalidPolicyReport = WhmSecurityReport::build($fleet, $audit, $now, ['version' => 1, 'mode' => 'enforce']);
$invalidPolicyFindings = array_column($invalidPolicyReport['findings'], null, 'category');
$assert($invalidPolicyReport['partial'] && $invalidPolicyFindings['report_policy_unavailable']['count'] === null
    && $invalidPolicyFindings['operation_rate']['severity'] === 'info',
    'mark malformed report policy unknown and do not apply any threshold from it');

$unavailablePolicyReport = WhmSecurityReport::build($fleet, $audit, $now, null, false);
$unavailablePolicyFindings = array_column($unavailablePolicyReport['findings'], null, 'category');
$assert($unavailablePolicyReport['partial']
    && $unavailablePolicyFindings['report_policy_unavailable']['count'] === null,
    'mark unreadable root policy as partial instead of implying configured thresholds were checked');

$legacyFleet = $fleet;
foreach (['rate_accounts', 'rate_missing_accounts', 'eviction_activity_accounts', 'max_evictions_per_window',
    'max_operations_per_second', 'rate_window_min_seconds', 'rate_window_max_seconds',
    'rate_window_earliest_start_at', 'rate_window_latest_end_at'] as $field) {
    unset($legacyFleet['metrics'][$field]);
}
$legacyReport = WhmSecurityReport::build($legacyFleet, $audit, $now);
$legacyCategories = array_column($legacyReport['findings'], null, 'category');
$assert($legacyReport['partial'] && $legacyCategories['eviction_rate']['count'] === null
    && $legacyCategories['operation_rate']['count'] === null
    && $legacyCategories['client_authentication_failures']['count'] === null,
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
    && $staleCategories['operation_rate']['count'] === 5
    && $staleCategories['client_authentication_failures']['count'] === 2,
    'preserve valid historical counter-rate and auth evidence when the separate fresh metrics source is unavailable');

$unsupportedAuthFleet = $fleet;
$unsupportedAuthFleet['metrics']['auth_rate_accounts'] = 0;
$unsupportedAuthFleet['metrics']['auth_rate_missing_accounts'] = 5;
foreach (['auth_failure_accounts', 'max_auth_failures_per_window', 'auth_rate_window_min_seconds',
    'auth_rate_window_max_seconds', 'auth_rate_window_earliest_start_at', 'auth_rate_window_latest_end_at'] as $field) {
    $unsupportedAuthFleet['metrics'][$field] = 0;
}
$unsupportedAuthFleet['partial'] = true;
$unsupportedAuthReport = WhmSecurityReport::build($unsupportedAuthFleet, $audit, $now);
$unsupportedAuthCategories = array_column($unsupportedAuthReport['findings'], null, 'category');
$assert($unsupportedAuthReport['partial'] && $unsupportedAuthCategories['client_authentication_failures']['count'] === null
    && str_contains($unsupportedAuthCategories['client_authentication_failures']['evidence'], 'unavailable'),
    'show missing or version-unsupported authentication counters as unknown instead of zero');

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
