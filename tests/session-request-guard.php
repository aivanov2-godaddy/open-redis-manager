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
$assert(!SessionRequestGuard::allowsMutation([
    'REQUEST_METHOD' => 'GET',
    'REQUEST_URI' => '/cpsess1234567890/cgi/addon_open_redis_manager.php',
]), 'Reject mutations on GET.');
$assert(!SessionRequestGuard::allowsMutation([
    'REQUEST_METHOD' => 'POST',
    'REQUEST_URI' => '/cgi/addon_open_redis_manager.php',
]), 'Reject POSTs without a cPanel session token in the route.');
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

fwrite(STDOUT, "cPanel session request guard checks passed: {$checks}\n");
