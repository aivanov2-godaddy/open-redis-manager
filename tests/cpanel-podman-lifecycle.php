<?php
declare(strict_types=1);

require_once __DIR__ . '/../src/Orm/Cpanel/PodmanCacheDiscovery.php';
require_once __DIR__ . '/../src/Orm/Cpanel/PodmanLifecycleManager.php';

use Orm\Cpanel\PodmanLifecycleManager;

$checks = 0;
$assert = static function (bool $condition, string $message) use (&$checks): void {
    ++$checks;
    if (!$condition) {
        fwrite(STDERR, "FAIL: {$message}\n");
        exit(1);
    }
};

if (PHP_OS_FAMILY !== 'Linux' || !function_exists('posix_geteuid')) {
    fwrite(STDOUT, "cPanel Podman lifecycle checks skipped: Linux ownership semantics are required.\n");
    exit(0);
}

$uid = posix_geteuid();
$home = sys_get_temp_dir() . '/orm-podman-lifecycle-' . bin2hex(random_bytes(5));
mkdir($home, 0700);
$podmanRoot = $home . '/ea-podman.d';
mkdir($podmanRoot, 0700);
$container = 'ea-redis62.ormtest.01';
mkdir($podmanRoot . '/' . $container, 0700);
$identity = static fn (string $name): array => [
    'uid' => $uid,
    'home' => $home,
    'shell' => '/bin/bash',
];
$seen = null;
$runner = static function (array $argv, array $env, int $timeout) use (&$seen): array {
    $seen = [$argv, $env, $timeout];
    return ['exit_code' => 0, 'timeout' => false];
};
$result = PodmanLifecycleManager::manage('ormtest', $container, 'start', $runner, $identity);
$assert($result === ['success' => true, 'reason' => 'ok'], 'accept a successful fixed cPanel start action');
$assert(is_array($seen) && $seen[0] === ['/usr/local/cpanel/scripts/ea-podman', 'start', $container],
    'invoke only the fixed cPanel script with an existing account-owned container');
$assert(is_array($seen) && $seen[2] === 30 && ($seen[1]['USER'] ?? null) === 'ormtest'
    && ($seen[1]['HOME'] ?? null) === $home, 'use a bounded timeout and current-account environment');
$assert(PodmanLifecycleManager::manage('ormtest', $container, 'uninstall', $runner, $identity)['reason'] === 'invalid',
    'reject uninstall and every unsupported action');
$assert(PodmanLifecycleManager::manage('ormtest', 'ea-redis62.other.01', 'stop', $runner, $identity)['reason'] === 'container',
    'reject a container associated with another account');
$assert(PodmanLifecycleManager::manage('ormtest', $container, 'stop', $runner,
    static fn (string $name): array => ['uid' => $uid, 'home' => $home, 'shell' => '/usr/local/cpanel/bin/jailshell'])['reason'] === 'unsupported-shell',
    'reject jailed shells before invoking EA Podman');
$failed = PodmanLifecycleManager::manage('ormtest', $container, 'restart',
    static fn (): array => ['exit_code' => 17, 'timeout' => false], $identity);
$assert($failed === ['success' => false, 'reason' => 'failed'], 'return a sanitized failure for nonzero command exit');
$timedOut = PodmanLifecycleManager::manage('ormtest', $container, 'restart',
    static fn (): array => ['exit_code' => null, 'timeout' => true], $identity);
$assert($timedOut === ['success' => false, 'reason' => 'timeout'], 'report a bounded command timeout');
$scriptResolver = new ReflectionMethod(PodmanLifecycleManager::class, 'trustedEaPodmanScript');
$assert($scriptResolver->invoke(null) === null, 'fail closed when the cPanel EA Podman script is absent on the test host');

@rmdir($podmanRoot . '/' . $container);
@rmdir($podmanRoot);
@rmdir($home);
fwrite(STDOUT, "cPanel Podman lifecycle checks passed: {$checks}\n");
