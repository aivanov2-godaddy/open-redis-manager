#!/usr/local/cpanel/3rdparty/bin/php
<?php
declare(strict_types=1);

/**
 * Read-only live exercise of ORM's WHM security-report data path.
 *
 * Run as root on a disposable cPanel & WHM host with ORM installed. This asks
 * the local broker for its bounded fleet summary, reads normalized ORM journal
 * events, and builds the report in memory. It does not write an audit event,
 * consume the WHM report rate limit, change policy, or inspect Redis keys.
 */

if (PHP_SAPI !== 'cli' || !function_exists('posix_geteuid') || posix_geteuid() !== 0) {
    fwrite(STDERR, "Run this read-only check with cPanel's PHP CLI as root.\n");
    exit(2);
}

$base = '/usr/local/cpanel/3rdparty/orm/src/Orm/';
foreach ([
    'Cpanel/BrokerClient.php',
    'Security/WhmAuditLog.php',
    'Security/WhmSecurityReportPolicyStore.php',
    'Security/WhmSecurityReport.php',
] as $file) {
    $path = $base . $file;
    if (!is_file($path) || !is_readable($path)) {
        fwrite(STDERR, "A required installed ORM report component is unavailable.\n");
        exit(1);
    }
    require_once $path;
}

$fleet = (new \Orm\Cpanel\BrokerClient())->requestFleetSummary();
$now = time();
$audit = (new \Orm\Security\WhmAuditLog())->read(max(0, $now - 86400), $now);
$policy = (new \Orm\Security\WhmSecurityReportPolicyStore())->load();
$report = \Orm\Security\WhmSecurityReport::build($fleet, $audit, $now, $policy, $policy !== null);

$fleetVerified = is_array($fleet) && ($fleet['success'] ?? null) === true;
$reportGenerated = is_string($report['generated_at_utc'] ?? null)
    && preg_match('/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/', $report['generated_at_utc']) === 1;
$reportOnly = ($report['mode'] ?? null) === 'report-only';
$auditReadSucceeded = ($audit['success'] ?? null) === true;
if (!$fleetVerified || !$reportGenerated || !$reportOnly || !$auditReadSucceeded) {
    fwrite(STDERR, "Live report engine check failed; details were withheld.\n");
    exit(1);
}

$requireValkeyEvidence = getenv('ORM_LIVE_REQUIRE_VALKEY_EVIDENCE') === '1';
if ($requireValkeyEvidence) {
    $metrics = is_array($fleet['metrics'] ?? null) ? $fleet['metrics'] : [];
    $backendCounts = is_array($fleet['backend_counts'] ?? null) ? $fleet['backend_counts'] : [];
    $findings = is_array($report['findings'] ?? null) ? array_column($report['findings'], null, 'category') : [];
    $valkeyEvidenceVerified = ($fleet['managed_count'] ?? null) === 1
        && ($backendCounts['valkey'] ?? null) === 1
        && ($metrics['rate_accounts'] ?? null) === 1
        && ($metrics['rate_missing_accounts'] ?? null) === 0
        && ($findings['operation_rate']['count'] ?? null) === 1
        && in_array($findings['operation_rate']['severity'] ?? null, ['info', 'warning'], true)
        && array_key_exists('eviction_rate', $findings)
        && array_key_exists('client_authentication_failures', $findings);
    if (!$valkeyEvidenceVerified) {
        fwrite(STDERR, "Valkey live evidence check failed; details were withheld.\n");
        exit(1);
    }
    printf(
        "Valkey live report evidence passed: one managed Valkey instance contributed a bounded rate sample; "
        . "operation, eviction, and optional authentication findings were generated in report-only mode; "
        . "partial=%s; audit source read succeeded.\n",
        ($report['partial'] ?? true) ? 'yes' : 'no'
    );
    exit(0);
}

printf(
    "Live WHM report engine passed: fleet summary verified; report generated in report-only mode; "
    . "partial=%s; audit source read succeeded.\n",
    ($report['partial'] ?? true) ? 'yes' : 'no'
);
