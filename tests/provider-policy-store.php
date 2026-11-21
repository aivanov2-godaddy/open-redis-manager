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
    'Accept the version-six report-only policy and validated global instance defaults.');
$legacyPolicy = [
    'version' => 1,
    'mode' => 'report-only',
    'default' => ['enabled' => true, 'max_memory_mib' => 64, 'backup_retention' => 3],
    'packages' => [],
];
$legacyExpected = ProviderPolicyStore::defaults();
$legacyExpected['mode'] = 'warn';
$assert(ProviderPolicyStore::normalize($legacyPolicy) === $legacyExpected,
    'Migrate a version-one report-only policy to compatibility warnings and current non-restrictive resource ceilings.');
$legacyV3 = ProviderPolicyStore::defaults();
$legacyV3['version'] = 3;
unset($legacyV3['instance_defaults']);
$legacyV3['default'] = ['enabled' => true, 'max_memory_mib' => 64, 'backup_retention' => 3];
$assert(ProviderPolicyStore::normalize($legacyV3) === ProviderPolicyStore::defaults(),
    'Migrate a version-three policy while preserving its existing controls and adding safe future-instance defaults.');
$legacyV4 = ProviderPolicyStore::defaults();
$legacyV4['version'] = 4;
$legacyV4['instance_defaults']['databases'] = 7;
$legacyV4['default'] = ['enabled' => true, 'max_memory_mib' => 32, 'backup_retention' => 2];
$legacyV4['packages']['starter'] = ['enabled' => true, 'max_memory_mib' => 24, 'backup_retention' => 2];
$legacyExpected = $legacyV4;
$legacyExpected['version'] = 6;
$legacyExpected['default'] += ['max_clients' => 100, 'max_databases' => 16];
$legacyExpected['packages']['starter'] += ['max_clients' => 100, 'max_databases' => 16, 'auto_provision' => false];
$assert(ProviderPolicyStore::normalize($legacyV4) === $legacyExpected,
    'Migrate a version-four policy to v6 with opt-in provisioning disabled and preserve its database default.');
$legacyV5 = ProviderPolicyStore::defaults();
$legacyV5['version'] = 5;
unset($legacyV5['packages']['starter']);
$legacyV5['packages']['starter'] = [
    'enabled' => true,
    'max_memory_mib' => 24,
    'backup_retention' => 2,
    'max_clients' => 40,
    'max_databases' => 6,
];
$legacyV5Expected = ProviderPolicyStore::defaults();
$legacyV5Expected['packages']['starter'] = $legacyV5['packages']['starter'] + ['auto_provision' => false];
$assert(ProviderPolicyStore::normalize($legacyV5) === $legacyV5Expected,
    'Migrate a version-five package rule to v6 with automatic provisioning disabled.');
$invalidV6 = ProviderPolicyStore::defaults();
$invalidV6['packages']['starter'] = [
    'enabled' => true,
    'max_memory_mib' => 24,
    'backup_retention' => 2,
    'max_clients' => 40,
    'max_databases' => 6,
];
$assert(ProviderPolicyStore::normalize($invalidV6) === null,
    'Require the auto-provision flag in current version-six package rules.');
$invalidLegacyV4 = $legacyV4;
$invalidLegacyV4['default']['max_clients'] = 80;
$assert(ProviderPolicyStore::normalize($invalidLegacyV4) === null,
    'Reject resource fields in a legacy schema instead of accepting a mixed-version policy.');
$logoBytes = file_get_contents(dirname(__DIR__) . '/packaging/whm/icons/orm-whm.png');
$assert(is_string($logoBytes) && strlen($logoBytes) <= 32768, 'Use a bounded PNG logo fixture.');
$validBranding = ProviderPolicyStore::defaultBranding();
$validBranding['product_name'] = 'Northstar Cache';
$validBranding['support_url'] = 'https://support.example.com/redis';
$validBranding['logo_png_base64'] = base64_encode($logoBytes);
$assert(ProviderPolicyStore::normalizeBranding($validBranding) === $validBranding,
    'Accept a bounded PNG, HTTPS support URL, product name, preset, and four accessible colors.');
$truncatedBranding = $validBranding;
$truncatedBranding['logo_png_base64'] = base64_encode("\x89PNG\r\n\x1a\n" . pack('N', 13) . 'IHDR' . pack('N2', 16, 16));
$assert(ProviderPolicyStore::normalizeBranding($truncatedBranding) === null,
    'Reject a truncated PNG that contains only a signature and partial header.');
$lowContrast = $validBranding;
$lowContrast['primary_color'] = '#FFFFFF';
$assert(ProviderPolicyStore::normalizeBranding($lowContrast) === null,
    'Reject colors that fail the 4.5:1 contrast minimum against white.');
$lowContrast = $validBranding;
$lowContrast['surface_color'] = '#111111';
$assert(ProviderPolicyStore::normalizeBranding($lowContrast) === null,
    'Reject a surface color that makes the configured text unreadable.');
$badPreset = $validBranding;
$badPreset['preset'] = 'unlisted';
$assert(ProviderPolicyStore::normalizeBranding($badPreset) === null,
    'Reject unknown brand preset names.');
$unsafeSupport = $validBranding;
$unsafeSupport['support_url'] = 'javascript:alert(1)';
$assert(ProviderPolicyStore::normalizeBranding($unsafeSupport) === null,
    'Reject non-HTTPS support URLs.');
$unsafeSupport['support_url'] = 'https://user:pass@example.com/';
$assert(ProviderPolicyStore::normalizeBranding($unsafeSupport) === null,
    'Reject support URLs containing user information.');
$unsafeSupport['support_url'] = 'https://bad..example.com/';
$assert(ProviderPolicyStore::normalizeBranding($unsafeSupport) === null,
    'Reject support URLs with malformed host labels.');
$unsafeName = $validBranding;
$unsafeName['product_name'] = '<script>alert(1)</script>';
$assert(ProviderPolicyStore::normalizeBranding($unsafeName) === null,
    'Reject markup in provider product names.');
$unsafeLogo = $validBranding;
$unsafeLogo['logo_png_base64'] = base64_encode('<svg xmlns="http://www.w3.org/2000/svg"/>');
$assert(ProviderPolicyStore::normalizeBranding($unsafeLogo) === null,
    'Reject active SVG content in place of a PNG logo.');
if (!is_int($owner)) {
    rmdir($root);
    fwrite(STDOUT, "Provider policy schema checks passed: {$checks}; POSIX file checks skipped on this platform.\n");
    exit(0);
}
$store = new ProviderPolicyStore($path, $owner);
$assert($store->load() === ProviderPolicyStore::defaults(), 'Use report-only defaults when no provider policy exists.');

$policy = ProviderPolicyStore::defaults();
$policy['mode'] = 'warn';
$policy['exposure'] = 'advanced';
$policy['packages']['starter'] = [
    'enabled' => true, 'max_memory_mib' => 24, 'backup_retention' => 2, 'max_clients' => 40, 'max_databases' => 6,
    'auto_provision' => false,
];
$policy['default']['max_clients'] = 80;
$policy['default']['max_databases'] = 12;
$policy['resellers']['reseller1'] = ['max_instances' => 4, 'max_memory_mib' => 128];
$policy['instance_defaults'] = [
    'memory_mib' => 24,
    'maxmemory_policy' => 'allkeys-lfu',
    'databases' => 8,
    'metrics_history_retention_days' => 45,
];
$assert($store->save($policy), 'Atomically save validated package policy.');
$assert($store->load() === $policy, 'Read back package, reseller, mode, and exposure policy after saving.');
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
$badPackage['packages']['../outside'] = [
    'enabled' => true, 'max_memory_mib' => 8, 'backup_retention' => 1, 'max_clients' => 10, 'max_databases' => 1,
];
$assert(ProviderPolicyStore::normalize($badPackage) === null, 'Reject unsafe package identifiers.');
$badReseller = $policy;
$badReseller['resellers']['../outside'] = ['max_instances' => 2, 'max_memory_mib' => 64];
$assert(ProviderPolicyStore::normalize($badReseller) === null, 'Reject unsafe reseller owner identifiers.');
$badQuota = $policy;
$badQuota['resellers']['reseller1']['max_memory_mib'] = -1;
$assert(ProviderPolicyStore::normalize($badQuota) === null, 'Reject negative reseller quota values.');
$badExposure = $policy;
$badExposure['exposure'] = 'hidden';
$assert(ProviderPolicyStore::normalize($badExposure) === null, 'Reject unrecognized exposure levels.');
$badBranding = $policy;
$badBranding['branding']['secondary_color'] = '#FFFFFF';
$assert(ProviderPolicyStore::normalize($badBranding) === null, 'Reject invalid branding in the complete provider policy.');
$badDefaults = $policy;
$badDefaults['instance_defaults']['maxmemory_policy'] = 'volatile-anything';
$assert(ProviderPolicyStore::normalize($badDefaults) === null, 'Reject an unlisted global eviction policy.');
$badDefaults = $policy;
$badDefaults['instance_defaults']['databases'] = 17;
$assert(ProviderPolicyStore::normalize($badDefaults) === null, 'Reject database counts beyond the supported bounded range.');
$badDefaults = $policy;
$badDefaults['instance_defaults']['metrics_history_retention_days'] = 6;
$assert(ProviderPolicyStore::normalize($badDefaults) === null, 'Reject metrics retention below the supported minimum.');
$badDefaults = $policy;
$badDefaults['instance_defaults']['memory_mib'] = 65;
$assert(ProviderPolicyStore::normalize($badDefaults) === null, 'Reject global memory defaults above the host limit.');
$assert(!$store->save($badMemory), 'Refuse to persist invalid provider policy.');
$badClients = $policy;
$badClients['packages']['starter']['max_clients'] = 101;
$assert(ProviderPolicyStore::normalize($badClients) === null, 'Reject package client ceilings above the runtime maximum.');
$badDatabases = $policy;
$badDatabases['packages']['starter']['max_databases'] = 17;
$assert(ProviderPolicyStore::normalize($badDatabases) === null, 'Reject package database ceilings above the supported maximum.');
$missingCeiling = $policy;
unset($missingCeiling['packages']['starter']['max_clients']);
$assert(ProviderPolicyStore::normalize($missingCeiling) === null, 'Require both resource ceilings in strict version-six policy objects.');

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
