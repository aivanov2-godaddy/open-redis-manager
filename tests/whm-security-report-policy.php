<?php
declare(strict_types=1);

require dirname(__DIR__) . '/src/Orm/Security/WhmSecurityReportPolicyStore.php';

use Orm\Security\WhmSecurityReportPolicyStore;

$checks = 0;
$assert = static function (bool $condition, string $message) use (&$checks): void {
    ++$checks;
    if (!$condition) {
        fwrite(STDERR, "FAIL: {$message}\n");
        exit(1);
    }
};

$defaults = WhmSecurityReportPolicyStore::defaults();
$assert(WhmSecurityReportPolicyStore::normalize($defaults) === $defaults,
    'Default to disabled thresholds in the report-only policy.');
$reordered = ['thresholds' => $defaults['thresholds'], 'version' => 1];
$assert(WhmSecurityReportPolicyStore::normalize($reordered) === $defaults,
    'Normalize policy object key order without changing threshold values.');

$invalid = $defaults;
$invalid['thresholds']['operations_per_second'] = -1;
$assert(WhmSecurityReportPolicyStore::normalize($invalid) === null, 'Reject negative thresholds.');
$invalid['thresholds']['auth_failures_per_window'] = '5';
$assert(WhmSecurityReportPolicyStore::normalize($invalid) === null, 'Reject numeric strings in the stored policy.');
$invalid = $defaults;
$invalid['mode'] = 'enforce';
$assert(WhmSecurityReportPolicyStore::normalize($invalid) === null,
    'Reject an enforcement mode in the advisory threshold store.');
$invalid = $defaults;
$invalid['thresholds']['extra'] = 1;
$assert(WhmSecurityReportPolicyStore::normalize($invalid) === null, 'Reject unknown threshold fields.');

if (!function_exists('posix_geteuid')) {
    fwrite(STDOUT, "WHM security report policy checks passed: {$checks}; POSIX file checks skipped on this platform.\n");
    exit(0);
}

$directory = sys_get_temp_dir() . '/orm-security-policy-' . bin2hex(random_bytes(6));
if (!mkdir($directory, 0700)) {
    throw new RuntimeException('Create the private report-policy test directory.');
}
$path = $directory . '/policy.json';
$owner = posix_geteuid();
$store = new WhmSecurityReportPolicyStore($path, $owner);
$assert($store->load() === $defaults, 'Use disabled report-only thresholds when no file exists.');
$saved = $defaults;
$saved['thresholds'] = [
    'evictions_per_window' => 50,
    'operations_per_second' => 5000,
    'auth_failures_per_window' => 10,
];
$assert($store->save($saved) && $store->load() === $saved, 'Atomically save and read back validated threshold settings.');
$wrongOwnerStore = new WhmSecurityReportPolicyStore($path, $owner + 1);
$assert($wrongOwnerStore->load() === null && !$wrongOwnerStore->save($saved),
    'Refuse reads and writes when the configured root owner does not match the process identity.');
$stat = lstat($path);
$assert(is_array($stat) && $stat['uid'] === $owner && ($stat['mode'] & 0777) === 0600 && $stat['nlink'] === 1,
    'Keep report-policy settings owner-controlled, private, and single-linked.');
$assert(!$store->save($invalid), 'Refuse to persist a malformed threshold policy.');

$symlinkPath = $directory . '/symlink.json';
symlink($path, $symlinkPath);
$symlinkStore = new WhmSecurityReportPolicyStore($symlinkPath, $owner);
$assert($symlinkStore->load() === null && !$symlinkStore->save($saved), 'Reject report-policy symlinks.');

@unlink($symlinkPath);
@unlink($path);
@rmdir($directory);
fwrite(STDOUT, "WHM security report policy checks passed: {$checks}\n");
