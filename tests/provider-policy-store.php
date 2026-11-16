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
    'Accept the version-three report-only default policy shape.');
$legacyPolicy = [
    'version' => 1,
    'mode' => 'report-only',
    'default' => ['enabled' => true, 'max_memory_mib' => 64, 'backup_retention' => 3],
    'packages' => [],
];
$legacyExpected = ProviderPolicyStore::defaults();
$legacyExpected['mode'] = 'warn';
$assert(ProviderPolicyStore::normalize($legacyPolicy) === $legacyExpected,
    'Migrate a version-one report-only policy to compatibility warnings with default branding and simple exposure.');
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
$policy['packages']['starter'] = ['enabled' => true, 'max_memory_mib' => 24, 'backup_retention' => 2];
$policy['resellers']['reseller1'] = ['max_instances' => 4, 'max_memory_mib' => 128];
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
$badPackage['packages']['../outside'] = ['enabled' => true, 'max_memory_mib' => 8, 'backup_retention' => 1];
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
