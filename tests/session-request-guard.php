<?php
declare(strict_types=1);

require dirname(__DIR__) . '/src/Orm/Security/SessionRequestGuard.php';

use Orm\Security\SessionRequestGuard;

$checks = 0;
$assert = static function (bool $condition, string $message) use (&$checks): void {
    $checks++;
    if (!$condition) {
        throw new RuntimeException($message);
    }
};

$assert(SessionRequestGuard::allowsMutation([
    'REQUEST_METHOD' => 'POST',
    'REQUEST_URI' => '/cpsess1234567890/frontend/jupiter/orm/index.live.php',
]), 'Allow a POST through a tokenized cPanel session route.');
$assert(SessionRequestGuard::allowsMutation([
    'REQUEST_METHOD' => 'POST',
    'REQUEST_URI' => '/cpsess1234567890/cgi/addon_open_redis_manager.php?view=backends',
]), 'Allow a POST through a tokenized WHM session route.');
$assert(!SessionRequestGuard::rejectsMutation([
    'REQUEST_METHOD' => 'POST',
    'REQUEST_URI' => '/cpsess1234567890/frontend/jupiter/orm/index.live.php',
]), 'Do not reject a POST through a tokenized cPanel session route.');
$assert(!SessionRequestGuard::allowsMutation([
    'REQUEST_METHOD' => 'GET',
    'REQUEST_URI' => '/cpsess1234567890/cgi/addon_open_redis_manager.php',
]), 'Reject mutations on GET.');
$assert(!SessionRequestGuard::allowsMutation([
    'REQUEST_METHOD' => 'POST',
    'REQUEST_URI' => '/cgi/addon_open_redis_manager.php',
]), 'Reject POSTs without a cPanel session token in the route.');
$assert(SessionRequestGuard::rejectsMutation([
    'REQUEST_METHOD' => 'POST',
    'REQUEST_URI' => '/frontend/jupiter/orm/index.live.php',
]), 'Reject un-tokenized POSTs before either plugin page processes the request.');
$assert(!SessionRequestGuard::allowsMutation([
    'REQUEST_METHOD' => 'POST',
    'REQUEST_URI' => '/cpsess-invalid/cgi/addon_open_redis_manager.php',
]), 'Reject malformed session-token routes.');
$assert(!SessionRequestGuard::allowsMutation([
    'REQUEST_METHOD' => 'POST',
    'REQUEST_URI' => '/cpsess123456/cgi/addon_open_redis_manager.php',
]), 'Reject a token shorter than the cPanel cpsess format.');
$assert(!SessionRequestGuard::allowsMutation([
    'REQUEST_METHOD' => 'POST',
    'REQUEST_URI' => 'https://attacker.example/cpsess123/cgi/addon_open_redis_manager.php',
]), 'Reject absolute external URIs.');
$assert(!SessionRequestGuard::allowsMutation([
    'REQUEST_METHOD' => 'POST',
    'REQUEST_URI' => '/cpsess12345678901/cgi/addon_open_redis_manager.php',
]), 'Reject a cpsess token with an unexpected length.');
$assert(!SessionRequestGuard::allowsMutation([
    'REQUEST_METHOD' => 'POST',
    'REQUEST_URI' => null,
]), 'Reject a non-string request URI.');

$cpanelPage = file_get_contents(dirname(__DIR__) . '/packaging/cpanel/files/orm/index.live.php');
$whmPage = file_get_contents(dirname(__DIR__) . '/packaging/whm/cgi/addon_open_redis_manager.php');
$assert(is_string($cpanelPage) && is_string($whmPage), 'Read both installed plugin entry points.');
foreach (['cPanel' => $cpanelPage, 'WHM' => $whmPage] as $surface => $page) {
    $forms = preg_match_all('/<form\b[^>]*>/i', $page, $matches);
    $postForms = array_values(array_filter(
        $matches[0] ?? [],
        static fn (string $form): bool => preg_match('/\bmethod\s*=\s*["\']?post\b/i', $form) === 1
    ));
    $assert(is_int($forms) && count($postForms) > 0, "{$surface} has POST forms to validate.");
    $assert(!array_filter(
        $postForms,
        static fn (string $form): bool => preg_match('/\baction\s*=/i', $form) === 1
    ), "{$surface} POST forms inherit the current cpsess route instead of overriding it.");
    $assert(str_contains($page, 'SessionRequestGuard::allowsMutation($_SERVER)'),
        "{$surface} mutation routes use the shared session-request guard.");
    $earlyDeny = strpos($page, 'SessionRequestGuard::rejectsMutation($_SERVER)');
    $firstPostRead = strpos($page, '$_POST');
    $firstPlatformWork = $surface === 'cPanel' ? strpos($page, "'/usr/local/cpanel/php/cpanel.php'")
        : strpos($page, "'/usr/local/cpanel/php/WHM.php'");
    $assert(is_int($earlyDeny) && is_int($firstPostRead) && $earlyDeny < $firstPostRead,
        "{$surface} rejects un-tokenized POSTs before reading submitted actions.");
    $assert(is_int($earlyDeny) && is_int($firstPlatformWork) && $earlyDeny < $firstPlatformWork,
        "{$surface} rejects un-tokenized POSTs before initializing the platform API.");
}

$actionsForInput = static function (string $page, string $inputName): array {
    preg_match_all('/\bname="' . preg_quote($inputName, '/') . '"\s+value="([^"]+)"/i', $page, $matches);
    $values = array_values(array_unique($matches[1] ?? []));
    sort($values);
    return $values;
};
$stringLiterals = static function (string $source): array {
    preg_match_all("/'([a-z][a-z0-9_.-]*)'/", $source, $matches);
    $values = array_values(array_unique($matches[1] ?? []));
    sort($values);
    return $values;
};
$cpanelActions = $actionsForInput($cpanelPage, 'orm_action');
$assert($cpanelActions === ['auth.disable', 'auth.rotate', 'backup.create', 'backup.restore', 'configure', 'provision', 'start', 'stop'],
    'keep cPanel mutation forms on the reviewed fixed action set');
$cpanelAllowlistMatch = [];
$cpanelAllowlistFound = preg_match('/\$allowedActions\s*=\s*\[([^\]]*)\]/s', $cpanelPage, $cpanelAllowlistMatch);
$cpanelAllowedActions = $cpanelAllowlistFound === 1 ? $stringLiterals($cpanelAllowlistMatch[1]) : [];
$assert($cpanelAllowedActions === $cpanelActions,
    'dispatch every cPanel mutation form only through the exact UI action allowlist');
$podmanActions = $actionsForInput($cpanelPage, 'orm_podman_action');
$podmanAllowlistMatch = [];
$podmanAllowlistFound = preg_match('/in_array\(\$podmanAction,\s*\[([^\]]*)\],\s*true\)/s', $cpanelPage, $podmanAllowlistMatch);
$podmanAllowedActions = $podmanAllowlistFound === 1 ? $stringLiterals($podmanAllowlistMatch[1]) : [];
$assert($podmanActions === ['restart', 'start', 'stop'] && $podmanAllowedActions === $podmanActions,
    'keep cPanel EA Podman controls to fixed current-account lifecycle actions');
$assert(str_contains($cpanelPage, "if (\$brokerVerified && \\Orm\\Security\\SessionRequestGuard::allowsMutation(\$_SERVER)\n    && is_string(\$podmanAction) && in_array(\$podmanAction, ['start', 'stop', 'restart'], true))"),
    'require verified account identity and the cPanel session guard for every EA Podman action');
$assert(str_contains($cpanelPage, "if (\$brokerVerified && \\Orm\\Security\\SessionRequestGuard::allowsMutation(\$_SERVER)) {\n    \$allowedActions ="),
    'place the cPanel action allowlist behind verified-account and cPanel-session authorization');

$whmActions = $actionsForInput($whmPage, 'orm_action');
$assert($whmActions === [
    'backend.select', 'fleet.backup', 'fleet.backup.batch', 'fleet.control', 'fleet.diagnostics',
    'fleet.migrate', 'fleet.recovery.repair', 'fleet.recovery.scan', 'fleet.summary',
    'provider.events.configure', 'provider.policy.update', 'security.policy.update', 'security.report',
    'update.apply', 'update.preview', 'update.status',
], 'keep WHM mutation forms on the reviewed fixed action set');
$guardedActions = [
    'fleet.summary' => 'if',
    'security.policy.update' => 'if',
    'security.report' => 'if',
    'fleet.control' => '$controlRequest',
    'fleet.backup' => '$fleetBackupRequest',
    'fleet.backup.batch' => '$fleetBatchRequest',
    'fleet.migrate' => '$fleetMigrationRequest',
    'backend.select' => 'if',
    'provider.events.configure' => 'if',
    'provider.policy.update' => 'if',
];
foreach ($guardedActions as $guardedAction => $guardedRequest) {
    $guardedPrefix = $guardedRequest === 'if'
        ? 'if ($rootAuthorized && \\Orm\\Security\\SessionRequestGuard::allowsMutation($_SERVER)'
        : "{$guardedRequest} = \$rootAuthorized && \\Orm\\Security\\SessionRequestGuard::allowsMutation(\$_SERVER)";
    $guardedCondition = $guardedPrefix . "\n    && (\$_POST['orm_action'] ?? null) === '{$guardedAction}'";
    $assert(str_contains($whmPage, $guardedCondition),
        "require root authorization and the WHM session guard for {$guardedAction}");
}
$assert(str_contains($whmPage, '$fleetDiagnosticsRequest = $rootAuthorized && \\Orm\\Security\\SessionRequestGuard::allowsMutation($_SERVER)')
    && str_contains($whmPage, "&& (\$_POST['orm_action'] ?? null) === 'fleet.diagnostics'"),
    'require root authorization and the WHM session guard for fleet.diagnostics');
$assert(str_contains($whmPage, "if (\$rootAuthorized && \\Orm\\Security\\SessionRequestGuard::allowsMutation(\$_SERVER)) {\n    \$updateAction = \$_POST['orm_action'] ?? null;")
    && str_contains($whmPage, "in_array(\$updateAction, ['update.preview', 'update.apply', 'update.status'], true)"),
    'guard every signed-update action behind root authorization and the WHM session guard');
$assert(str_contains($whmPage, "\$fleetRecoveryAction = \$_POST['orm_action'] ?? null;\nif (\$rootAuthorized && \\Orm\\Security\\SessionRequestGuard::allowsMutation(\$_SERVER)")
    && str_contains($whmPage, "in_array(\$fleetRecoveryAction, ['fleet.recovery.scan', 'fleet.recovery.repair'], true)"),
    'guard both fleet recovery actions behind root authorization and the WHM session guard');
$auditActions = $actionsForInput($whmPage, 'orm_audit_action');
$assert($auditActions === ['export', 'search']
    && str_contains($whmPage, "\$auditRequest = \$rootAuthorized && \\Orm\\Security\\SessionRequestGuard::allowsMutation(\$_SERVER)\n    && in_array(\$_POST['orm_audit_action'] ?? null, ['search', 'export'], true)"),
    'guard the fixed WHM audit search/export actions behind root authorization and the WHM session guard');

$liveHarness = file_get_contents(__DIR__ . '/cpanel-live-session-token-smoke.py');
$assert(is_string($liveHarness)
    && str_contains($liveHarness, 'INVALID_ACTION = "orm-csrf-probe-unsupported"')
    && str_contains($liveHarness, 'no_token_post_denied')
    && str_contains($liveHarness, 'verify_source('),
    'The source-matched live harness sends only an unsupported no-op action without cpsess.');
$assert(is_string($liveHarness)
    && str_contains($liveHarness, 'response bodies are kept in memory and never printed or written to disk.'),
    'The live harness keeps session data and response bodies out of logs and files.');

fwrite(STDOUT, "cPanel session request guard checks passed: {$checks}\n");
