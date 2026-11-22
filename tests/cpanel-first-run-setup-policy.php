<?php
declare(strict_types=1);

require dirname(__DIR__) . '/src/Orm/Cpanel/PodmanCacheDiscovery.php';

use Orm\Cpanel\PodmanCacheDiscovery;

$checks = 0;
$assert = static function (bool $condition, string $message) use (&$checks): void {
    ++$checks;
    if (!$condition) {
        fwrite(STDERR, "FAIL: {$message}\n");
        exit(1);
    }
};

$verifiedAbsent = PodmanCacheDiscovery::firstRunSetupPolicy(true, 'not-installed');
$assert($verifiedAbsent === ['show_wizard' => true, 'allow_podman_install' => true],
    'offer both setup choices and fixed Podman installation steps for a verified empty inventory');

$unknown = PodmanCacheDiscovery::firstRunSetupPolicy(true, 'unavailable');
$assert($unknown === ['show_wizard' => true, 'allow_podman_install' => false],
    'keep the first-run wizard visible while withholding Podman installation for unavailable inventory');

$futureUnknown = PodmanCacheDiscovery::firstRunSetupPolicy(true, 'future-unknown-state');
$assert($futureUnknown === ['show_wizard' => true, 'allow_podman_install' => false],
    'fail closed for unrecognized inventory states without hiding native backend discovery');

$verifiedInstalled = PodmanCacheDiscovery::firstRunSetupPolicy(true, 'installed');
$assert($verifiedInstalled === ['show_wizard' => false, 'allow_podman_install' => false],
    'avoid duplicate first-run setup when a verified account-owned Podman cache exists');

$configured = PodmanCacheDiscovery::firstRunSetupPolicy(false, 'not-installed');
$assert($configured === ['show_wizard' => false, 'allow_podman_install' => false],
    'hide first-run setup after an ORM-managed instance is configured');

fwrite(STDOUT, "cPanel first-run setup policy checks passed: {$checks}\n");
