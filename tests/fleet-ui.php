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
$assert(str_contains($whm, 'Managed ORM accounts') && str_contains($whm, "\$fleetSummary['backend_counts']")
    && str_contains($whm, 'Load root fleet summary') && str_contains($whm, 'Root-only aggregate'),
    'show backend-specific managed account counts only from a loaded root fleet summary');
$assert(str_contains($whm, "'security.policy.update'")
    && str_contains($whm, 'WhmSecurityReportPolicyStore')
    && str_contains($whm, 'Configure report-only thresholds')
    && str_contains($whm, 'security.thresholds.update'),
    'expose separately stored, root-authorized, auditable report-only thresholds');
$assert(str_contains($whm, 'Thresholds are disabled by default and are advisory only')
    && str_contains($whm, 'do not enforce') && str_contains($whm, 'remediate'),
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
$assert(str_contains($whm, '$fleetAuthRotationRequest = $rootAuthorized && \\Orm\\Security\\SessionRequestGuard::allowsMutation($_SERVER)')
    && str_contains($whm, "&& (\$_POST['orm_action'] ?? null) === 'fleet.auth.rotate'")
    && str_contains($whm, 'rotateFleetAuth($username)'),
    'guard per-account AUTH rotation behind root authorization and the WHM session token');
$assert(str_contains($whm, 'Enable / rotate AUTH password')
    && str_contains($whm, 'Cache-Control: private, no-store, max-age=0')
    && str_contains($whm, 'One-time AUTH password') && str_contains($whm, 'ORM will not show it again'),
    'show generated credentials once in a non-cacheable WHM response with explicit handling guidance');
$assert(str_contains($whm, 'Generate report-only review') && str_contains($whm, 'Signals not evaluated')
    && str_contains($whm, 'does not inspect passwords'),
    'show report-only findings, unsupported evidence gaps, and privacy limits');
$assert(str_contains($whm, 'class="orm-security-report"')
    && str_contains($whm, 'class="orm-report-threshold-grid"')
    && str_contains($whm, 'class="orm-report-findings"')
    && str_contains($whm, '.orm-report-completeness')
    && str_contains($whm, '@media(max-width:760px)'),
    'render the WHM security report as a responsive, evidence-status UI');
$fleetPageGuard = strpos($whm, '<?php if ($fleetPage === null): ?>');
$summaryForm = strpos($whm, 'name="orm_action" value="fleet.summary"');
$securitySection = strpos($whm, '<section class="orm-security-report" aria-labelledby="orm-security-report-title">');
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
$assert(str_contains($whm, "'instance.provision','instance.configure','instance.start','instance.stop'")
    && str_contains($whm, 'ORM-managed cPanel provisioning, configuration, start, and stop requests are included')
    && str_contains($whm, 'cPanel EA Podman commands'),
    'filter normalized cPanel operation events and explain the audit coverage boundary');
$assert(str_contains($whm, "'config_drift' =>") && str_contains($whm, "'config_missing' =>")
    && str_contains($whm, "'config_malformed' =>") && str_contains($whm, "'config_reset'")
    && str_contains($whm, 'Rebuild config') && str_contains($whm, 'ORM will not start the service')
    && str_contains($whm, 'Reset config and replace AUTH') && str_contains($whm, 'recovery.config_reset')
    && str_contains($whm, 'One-time replacement AUTH password') && str_contains($whm, 'private, no-store'),
    'show scan-gated config rebuild/reset with explicit confirmation, one-time password and audit action');
$assert(str_contains($whm, "\$finding['window_start_utc']")
    && str_contains($whm, "\$finding['window_end_utc']") && str_contains($whm, 'Evidence window:'),
    'render escaped UTC evidence bounds on each WHM security report finding');
$assert(str_contains($cpanel, 'PodmanCacheDiscovery::currentAccountInventory')
    && str_contains($cpanel, 'PodmanLifecycleManager::manage')
    && str_contains($cpanel, 'read-only PING') && str_contains($cpanel, 'cPanel Podman caches')
    && str_contains($cpanel, 'orm_podman_action'),
    'show verified current-account Podman containers, bounded probe status, and fixed lifecycle actions');
$assert(str_contains($cpanel, 'valkey-via-containers') && str_contains($cpanel, 'redis-via-containers'),
    'link the cPanel Redis and Valkey container instructions');
$assert(str_contains($cpanel, 'First-time setup') && str_contains($cpanel, 'orm_setup=native')
    && str_contains($cpanel, 'orm_setup=podman') && str_contains($cpanel, 'BackendDiscovery')
    && str_contains($cpanel, 'PodmanLifecycleManager::inspectSetup'),
    'offer native and Podman onboarding choices backed by bounded read-only discovery');
$assert(str_contains($cpanel, 'Live usage') && str_contains($cpanel, 'memory_used_bytes')
    && str_contains($cpanel, 'metrics_sampled_at') && str_contains($cpanel, 'not retained')
    && str_contains($cpanel, 'PodmanCacheDiscovery::currentAccountInventory'),
    'show ephemeral allowlisted live metrics separately for verified current-account Podman sockets');
$assert(str_contains($cpanel, "extension_loaded('redis')")
    && str_contains($cpanel, "class_exists('Redis', false)")
    && str_contains($cpanel, 'PhpRedis in this cPanel page runtime')
    && str_contains($cpanel, 'does not report the PHP version or extensions selected for your domains'),
    'show truthful PhpRedis availability for only the cPanel page runtime and preserve domain-runtime uncertainty');
$assert(str_contains($cpanel, 'ea-podman install <?= htmlspecialchars($packageInfo[\'package\']')
    && str_contains($cpanel, 'will not run a host package manager')
    && str_contains($cpanel, 'could not safely verify this account’s cPanel container inventory'),
    'show only fixed EA package setup instructions and preserve unknown inventory states');
$assert(str_contains($cpanel, 'PodmanCacheDiscovery::firstRunSetupPolicy')
    && str_contains($cpanel, '!$podmanInventoryVerifiedAbsent')
    && str_contains($cpanel, 'it will not recommend installing another one'),
    'keep first-run native setup available when Podman discovery is unknown while withholding duplicate Podman install steps');

fwrite(STDOUT, "Fleet UI checks passed: {$checks}\n");
