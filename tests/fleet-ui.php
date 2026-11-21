<?php
declare(strict_types=1);

$checks = 0;
$assert = static function (bool $condition, string $message) use (&$checks): void {
    ++$checks;
    if (!$condition) {
        fwrite(STDERR, "FAIL: {$message}\n");
        exit(1);
    }
};
$whm = file_get_contents(dirname(__DIR__) . '/packaging/whm/cgi/addon_open_redis_manager.php');
$cpanel = file_get_contents(dirname(__DIR__) . '/packaging/cpanel/files/orm/index.live.php');
$assert(is_string($whm) && is_string($cpanel), 'read the installed WHM and cPanel interfaces');
$assert(str_contains($whm, "requestFleetSummary()") && str_contains($whm, "'fleet.summary'"),
    'request fleet aggregates only through the root WHM POST action');
$assert(str_contains($whm, "'security.policy.update'")
    && str_contains($whm, 'WhmSecurityReportPolicyStore')
    && str_contains($whm, 'Configure report-only thresholds')
    && str_contains($whm, 'security.thresholds.update'),
    'expose separately stored, root-authorized, auditable report-only thresholds');
$assert(str_contains($whm, 'Thresholds are disabled by default and are advisory only')
    && str_contains($whm, 'do not enforce, remediate'),
    'explain default-off thresholds and prevent any implication of automatic enforcement');
$assert(str_contains($whm, 'count($selected) <= 2') && str_contains($whm, 'array_is_list($selected)'),
    'cap and validate the browser-selected batch account list');
$assert(str_contains($whm, "hash_equals(\$backup['id'], \$backupId)"),
    'bind a batch restore snapshot to the selected account row');
$assert(str_contains($whm, 'id="orm-fleet-batch-create"') && str_contains($whm, 'id="orm-fleet-batch-restore"'),
    'render separate accessible forms for snapshot creation and restoration');
$assert(str_contains($whm, 'Newer writes may be lost') && str_contains($whm, 'safety snapshot'),
    'warn about data loss and per-account restore recovery before a batch restore');
$assert(str_contains($whm, 'Missing and stale values are excluded from totals'),
    'explain partial metric totals in the fleet summary');
$assert(str_contains($whm, "'info_memory' => ['label' => 'INFO memory'")
    && str_contains($whm, 'name="command_class"') && str_contains($whm, 'Run read-only probe')
    && str_contains($whm, 'diagnoseFleetAccount($username, $commandClass)'),
    'offer an accessible fixed diagnostic-class selector and execute only the selected class');
$assert(str_contains($whm, "'security.report'") && str_contains($whm, 'WhmSecurityReport::consumeRateLimit'),
    'guard report generation behind the root WHM POST path and persistent throttle');
$assert(str_contains($whm, 'Generate report-only review') && str_contains($whm, 'Signals not evaluated')
    && str_contains($whm, 'does not inspect passwords'),
    'show report-only findings, unsupported evidence gaps, and privacy limits');
$fleetPageGuard = strpos($whm, '<?php if ($fleetPage === null): ?>');
$summaryForm = strpos($whm, 'name="orm_action" value="fleet.summary"');
$securitySection = strpos($whm, '<section aria-labelledby="orm-security-report-title">');
$securitySectionEnd = $securitySection === false ? false : strpos($whm, '</section>', $securitySection);
$assert(is_int($fleetPageGuard) && is_int($summaryForm) && is_int($securitySection)
    && is_int($securitySectionEnd) && $summaryForm < $fleetPageGuard
    && $securitySection < $fleetPageGuard && $securitySectionEnd < $fleetPageGuard,
    'render the fleet summary and security report independently from transient fleet-list availability');
$assert(str_contains($whm, 'Counter-rate samples') && str_contains($whm, 'resets, and missing baselines')
    && str_contains($whm, 'actual sample times') && str_contains($whm, 'advisory only'),
    'explain bounded rate evidence, unknown resets, and report-only threshold behavior');
$assert(str_contains($whm, 'Authentication-failure counters')
    && str_contains($whm, 'do not identify clients')
    && str_contains($whm, 'Older backends may not expose this optional INFO field'),
    'explain anonymous backend authentication counters and unknown older-backend coverage');
$assert(str_contains($whm, 'Usage from snapshot') && str_contains($whm, "\$entry['usage']['state']")
    && str_contains($whm, 'memory_used_bytes') && str_contains($whm, 'connected_clients')
    && str_contains($whm, 'No valid metrics snapshot is available.'),
    'show per-account memory and client usage with explicit snapshot freshness and unknown values');
$assert(str_contains($whm, "\$finding['window_start_utc']")
    && str_contains($whm, "\$finding['window_end_utc']") && str_contains($whm, 'Evidence window:'),
    'render escaped UTC evidence bounds on each WHM security report finding');
$assert(str_contains($cpanel, 'PodmanCacheDiscovery::forCurrentAccount')
    && str_contains($cpanel, 'PodmanLifecycleManager::manage')
    && str_contains($cpanel, 'read-only PING') && str_contains($cpanel, 'cPanel Podman caches')
    && str_contains($cpanel, 'orm_podman_action'),
    'show verified current-account Podman containers, bounded probe status, and fixed lifecycle actions');
$assert(str_contains($cpanel, 'valkey-via-containers') && str_contains($cpanel, 'redis-via-containers'),
    'link the cPanel Redis and Valkey container instructions');

fwrite(STDOUT, "Fleet UI checks passed: {$checks}\n");
