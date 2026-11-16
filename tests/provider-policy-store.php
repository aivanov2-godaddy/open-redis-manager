<?php
declare(strict_types=1);

require dirname(__DIR__) . '/src/Orm/Backend/ProviderPolicyStore.php';

use Orm\Backend\ProviderPolicyStore;

$checks = 0;
$assert = static function (bool $condition, string $message) use (&$checks): void {
    ++$checks;
    if (!$condition) {
        fwrite(STDERR, "FAIL: {$message}\n");
        exit(1);
    }
};

$root = sys_get_temp_dir() . '/orm-provider-policy-' . bin2hex(random_bytes(8));
if (!mkdir($root, 0700)) {
    throw new RuntimeException('Create provider policy test directory.');
}
$path = $root . '/provider-policy.json';
$owner = function_exists('posix_geteuid') ? posix_geteuid() : null;
$assert(ProviderPolicyStore::normalize(ProviderPolicyStore::defaults()) === ProviderPolicyStore::defaults(),
    'Accept the report-only default policy shape.');
if (!is_int($owner)) {
    rmdir($root);
    fwrite(STDOUT, "Provider policy schema checks passed: {$checks}; POSIX file checks skipped on this platform.\n");
    exit(0);
}
$store = new ProviderPolicyStore($path, $owner);
$assert($store->load() === ProviderPolicyStore::defaults(), 'Use report-only defaults when no provider policy exists.');

$policy = ProviderPolicyStore::defaults();
$policy['mode'] = 'enforce';
$policy['packages']['starter'] = ['enabled' => true, 'max_memory_mib' => 24, 'backup_retention' => 2];
$assert($store->save($policy), 'Atomically save validated package policy.');
$assert($store->load() === $policy, 'Read back the exact provider policy after saving.');
$stat = lstat($path);
$assert(is_array($stat) && $stat['uid'] === $owner && ($stat['mode'] & 0777) === 0600 && $stat['nlink'] === 1,
    'Keep provider policy root-owned, private, and single-linked.');

$badMode = $policy;
$badMode['mode'] = 'enforce-now';
$assert(ProviderPolicyStore::normalize($badMode) === null, 'Reject unrecognized policy modes.');
$badMemory = $policy;
$badMemory['packages']['starter']['max_memory_mib'] = 65;
$assert(ProviderPolicyStore::normalize($badMemory) === null, 'Reject package memory ceilings above the host limit.');
$badPackage = $policy;
$badPackage['packages']['../outside'] = ['enabled' => true, 'max_memory_mib' => 8, 'backup_retention' => 1];
$assert(ProviderPolicyStore::normalize($badPackage) === null, 'Reject unsafe package identifiers.');
$assert(!$store->save($badMemory), 'Refuse to persist invalid provider policy.');

$symlinkPath = $root . '/linked-policy.json';
symlink($path, $symlinkPath);
$symlinkStore = new ProviderPolicyStore($symlinkPath, $owner);
$assert($symlinkStore->load() === null && !$symlinkStore->save($policy), 'Reject provider policy symlinks.');

$deniedStore = new ProviderPolicyStore($path, $owner + 1);
$assert($deniedStore->load() === null && !$deniedStore->save($policy), 'Require the effective UID to match the configured owner.');

unlink($symlinkPath);
unlink($path);
rmdir($root);
fwrite(STDOUT, "Provider policy store checks passed: {$checks}\n");
