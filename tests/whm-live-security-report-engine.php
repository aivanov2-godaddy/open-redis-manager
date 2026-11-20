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

printf(
    "Live WHM report engine passed: fleet summary verified; report generated in report-only mode; "
    . "partial=%s; audit source read succeeded.\n",
    ($report['partial'] ?? true) ? 'yes' : 'no'
);
