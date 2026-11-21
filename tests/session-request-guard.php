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
