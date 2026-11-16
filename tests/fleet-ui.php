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
$assert(str_contains($whm, "'security.report'") && str_contains($whm, 'WhmSecurityReport::consumeRateLimit'),
    'guard report generation behind the root WHM POST path and persistent throttle');
$assert(str_contains($whm, 'Generate report-only review') && str_contains($whm, 'Signals not evaluated')
    && str_contains($whm, 'does not inspect passwords'),
    'show report-only findings, unsupported evidence gaps, and privacy limits');
$assert(str_contains($whm, 'Counter-rate samples') && str_contains($whm, 'resets, and missing baselines')
    && str_contains($whm, 'actual sample times') && str_contains($whm, 'without an abuse threshold'),
    'explain bounded rate evidence, unknown resets, and neutral operation-rate interpretation');
$assert(str_contains($cpanel, 'PodmanCacheDiscovery::forCurrentAccount')
    && str_contains($cpanel, 'read-only PING') && str_contains($cpanel, 'cPanel Podman caches'),
    'show only verified current-account Podman cache sockets and their read-only probe status');
$assert(str_contains($cpanel, 'valkey-via-containers') && str_contains($cpanel, 'redis-via-containers'),
    'link the cPanel Redis and Valkey container instructions');

fwrite(STDOUT, "Fleet UI checks passed: {$checks}\n");
